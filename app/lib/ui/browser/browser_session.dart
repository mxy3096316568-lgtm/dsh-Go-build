import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../state/capability_guard.dart';
import '../../state/consent_store.dart';
import '../kb/kb_crawl.dart';
import '../kb/kb_index.dart';
import '../notify/notify_bridge.dart';
import '../proxy/proxy_service.dart';
import 'site_store.dart';
import 'webdav_client.dart';

/// One tab of the in-app browser.
class BrowserTab {
  BrowserTab({required this.id, this.url = '', this.title = ''});

  final int id;
  String url;
  String title;

  String get label {
    if (title.trim().isNotEmpty) return title.trim();
    if (url.trim().isEmpty) return '新标签';
    final uri = Uri.tryParse(url);
    return uri?.host.isNotEmpty == true ? uri!.host : url;
  }

  Map<String, Object?> toJson(int active) => {
    'id': id,
    'url': url,
    'title': label,
    'active': id == active,
  };
}

/// The one browser in the app: kept alive for the whole process, so a page
/// opened in the background (or left while a chat message is sent) is still
/// there when the tools come back to it.
///
/// One WebView carries every tab: switching keeps the address (and reloads it),
/// which costs a page load but keeps eight tabs from meaning eight Chromium
/// processes. Cookies, logins and storage are shared, as they would be in a
/// browser.
class BrowserSession {
  BrowserSession._();

  static final BrowserSession instance = BrowserSession._();

  /// Refuse beyond this: each tab is a page the person has to close by hand.
  static const maxTabs = 8;

  /// Schemes the WebView may navigate to; anything else is refused before loading.
  static const allowedSchemes = {'http', 'https', 'about', 'data', 'blob', 'file'};

  /// Where screenshots go: shared storage, so the engine can read them back.
  static const screenshotDir = '/sdcard/Download/DSH-Go/screenshots';

  /// Extensions the upload tool and the person's own file picker accept.
  static const allowedUploadExtensions = <String>{
    'pdf', 'txt', 'md', 'csv', 'json', 'xml', 'yaml', 'yml', 'log',
    'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'epub',
    'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic',
    'zip', '7z', 'rar', 'tar', 'gz',
    'mp3', 'm4a', 'wav', 'ogg', 'mp4', 'mov', 'webm',
  };

  /// Folders a page may be handed a file from (checked again for the tool).
  static const uploadFolders = <String>['/sdcard/Download/', '/sdcard/DCIM/'];

  WebViewController? _controller;
  final ValueNotifier<String> url = ValueNotifier<String>('');
  final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
  final ValueNotifier<String> lastBlockedScheme = ValueNotifier<String>('');

  /// Which tab the WebView shows (an index into [_tabs]).
  final ValueNotifier<int> activeTab = ValueNotifier<int>(0);

  /// Bumped whenever the tab list itself changes, so the page can redraw.
  final ValueNotifier<int> tabsRevision = ValueNotifier<int>(0);

  final List<BrowserTab> _tabs = [];
  int _nextTabId = 1;

  /// The document load in flight (completed on the next page finish).
  Completer<void>? _loading;

  /// The largest file the upload tool can hand to a page: the bytes travel
  /// into the page as base64, so this is memory, not disk.
  static const maxUploadBytes = 10 * 1024 * 1024;

  /// Set when the person asks for a file the next time a page opens a picker.
  bool confirmUploads = true;

  /// The file the next `onShowFileSelector` must answer with: the tool's upload when the
  /// page's input refuses a scripted FileList (Android WebView does), instead of a picker.
  String? pendingUploadPath;

  List<BrowserTab> get tabs => List<BrowserTab>.unmodifiable(_tabs);

  bool get opened => _controller != null && _tabs.isNotEmpty;

  bool get loading => _loading != null && !_loading!.isCompleted;

  BrowserTab? get currentTab {
    if (_tabs.isEmpty) return null;
    final index = activeTab.value.clamp(0, _tabs.length - 1).toInt();
    return _tabs[index];
  }

  /// 全部暂停 / 关掉浏览器: stop what the page is doing right now, not just refuse the
  /// next call. Tabs stay (the person can read them again after turning it back on).
  Future<void> abort() async {
    final pending = _loading;
    if (pending != null && !pending.isCompleted) pending.complete();
    _loading = null;
    try {
      // webview_flutter 4.x has no stopLoading: navigating away is what cancels a load.
      await _controller?.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

  Future<void> waitLoaded([Duration limit = const Duration(seconds: 10)]) async {
    final pending = _loading;
    if (pending == null || pending.isCompleted) return;
    try {
      await pending.future.timeout(limit);
    } catch (_) {}
  }

  /// The page is on screen; while false the hidden host keeps the WebView up.
  bool get pageVisible => visible.value;

  WebViewController get controller {
    final existing = _controller;
    if (existing != null) return existing;
    // Assigned after construction: the delegate below answers with this controller.
    late final WebViewController created;
    created = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (allowedSchemes.contains(uri.scheme)) return NavigationDecision.navigate;
            lastBlockedScheme.value = uri.scheme;
            return NavigationDecision.prevent;
          },
          onPageStarted: (value) {
            url.value = value;
            final tab = currentTab;
            if (tab != null) tab.url = value;
            _loading = Completer<void>();
          },
          onPageFinished: (value) async {
            url.value = value;
            final tab = currentTab;
            if (tab != null) tab.url = value;
            if (_loading != null && !_loading!.isCompleted) _loading!.complete();
            try {
              final mark = await loadErrorMark();
              final title = mark.isEmpty ? (await created.getTitle() ?? '') : '加载失败';
              if (tab != null) {
                tab.title = title;
                _bumpTabs();
              }
              if (mark.isEmpty) await SiteStore.record(url: value, title: title);
            } catch (_) {}
          },
        ),
      );
    final platform = created.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setOnShowFileSelector(_chooseFiles));
    }
    _controller = created;
    return created;
  }

  /// A marker when the page Chrome is showing is an error page (host unreachable,
  /// certificate, DNS…), empty otherwise. Android's error page is not a document
  /// the page itself served, so nothing else can tell them apart.
  static const _errorProbe = '''
(() => {
  const url = String(location.href || "");
  if (url.startsWith("chrome-error")) return "chrome-error";
  const text = document.body ? String(document.body.innerText || "").slice(0, 600) : "";
  const found = text.match(/ERR_[A-Z_]+|网页无法打开|无法访问此网站|This site can.t be reached/);
  return found ? found[0] : "";
})()
''';

  /// 标签标题: an error page has no title of its own worth showing.
  void markLoadFailed() {
    final tab = currentTab;
    if (tab == null) return;
    tab.title = '加载失败';
    _bumpTabs();
  }

  Future<String> loadErrorMark() async {
    try {
      return _stringOf(await run(_errorProbe));
    } catch (_) {
      return '';
    }
  }

  Future<Object?> run(String script) async {
    final c = _controller;
    if (c == null) return null;
    return c.runJavaScriptReturningResult(script);
  }

  void _bumpTabs() {
    tabsRevision.value++;
    final index = activeTab.value.clamp(0, max(0, _tabs.length - 1)).toInt();
    activeTab.value = index;
  }

  /// Loads [target] in the current tab (opening one when there is none) and
  /// waits until the document settles, so a read straight after open sees the
  /// new page.
  Future<String> open(String target, {bool newTab = false}) async {
    if (_tabs.isEmpty || newTab) {
      if (_tabs.length >= maxTabs && newTab) {
        throw const BrowserTabsFull();
      }
      final tab = BrowserTab(id: _nextTabId++, url: target);
      _tabs.add(tab);
      activeTab.value = _tabs.length - 1;
      _bumpTabs();
    } else {
      currentTab!.url = target;
    }
    _loading = Completer<void>();
    await controller.loadRequest(Uri.parse(target));
    await waitLoaded();
    lastLoadTimedOut = loading;
    if (loading) {
      // Nothing finished in ten seconds: stop pretending the page is loading, so the
      // route can report a failed open instead of handing back a stale URL.
      final pending = _loading;
      if (pending != null && !pending.isCompleted) pending.complete();
      _loading = null;
    }
    // Not [url]: a load that failed never fires `onPageFinished`, so the notifier can
    // still name the page from before — the old `finalUrl` was whichever WebView load
    // finished last, which on a tab switch is the tab that was left behind.
    final finalUrl = await currentUrl();
    if (finalUrl.isEmpty) return target;
    final tab = currentTab;
    if (tab != null) tab.url = finalUrl;
    return finalUrl;
  }

  /// The last [open] ran out its ten-second wait without a finished page.
  bool lastLoadTimedOut = false;

  /// Waits briefly for a click to start a navigation, so an immediate read of the
  /// state sees the new page instead of the one before the click.
  Future<void> waitForNavigation([Duration limit = const Duration(milliseconds: 1200)]) async {
    final before = url.value;
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      if (url.value != before || loading) return;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  /// Where the WebView is right now; empty when it has not committed a page.
  Future<String> currentUrl() async {
    try {
      final value = (await controller.currentUrl())?.trim() ?? '';
      if (value.isNotEmpty) return value;
    } catch (_) {}
    return url.value.trim();
  }

  /// Opens a blank tab the person (or the assistant) can type into.
  int newTab({String url = ''}) {
    if (_tabs.length >= maxTabs) throw const BrowserTabsFull();
    final tab = BrowserTab(id: _nextTabId++, url: url);
    _tabs.add(tab);
    activeTab.value = _tabs.length - 1;
    _bumpTabs();
    if (url.isEmpty) {
      // Materialise the WebView too: a blank tab is still an open browser.
      unawaited(controller.loadRequest(Uri.parse('about:blank')));
    } else {
      unawaited(open(url));
    }
    return tab.id;
  }

  /// Switches to the tab at [index]; the address is loaded again because one
  /// WebView carries every tab.
  Future<void> switchTo(int index) async {
    if (_tabs.isEmpty) return;
    final target = index.clamp(0, _tabs.length - 1).toInt();
    if (target == activeTab.value) return;
    final tab = _tabs[target];
    final previous = activeTab.value;
    final uri = tab.url.isEmpty ? null : Uri.tryParse(tab.url);
    if (tab.url.isNotEmpty && (uri == null || !allowedSchemes.contains(uri.scheme))) {
      // Refuse before touching the selection: a tab the WebView cannot load must not
      // replace the one on screen.
      throw BrowserSwitchFailed('这个标签的地址打不开：${tab.url}');
    }
    activeTab.value = target;
    _bumpTabs();
    if (uri == null) return;
    try {
      _loading = Completer<void>();
      await controller.loadRequest(uri);
      await waitLoaded();
    } catch (error) {
      // Put the selection back: an exception here used to reach the route as a bare
      // 500, which the app read as "the tabs are gone".
      activeTab.value = previous;
      _bumpTabs();
      throw BrowserSwitchFailed('切换到这个标签失败：$error');
    }
  }

  /// Closes the tab at [index]; the neighbouring one takes its place. Closing
  /// the last tab leaves the browser closed (`browser_closed`).
  Future<void> closeTab(int? index) async {
    if (_tabs.isEmpty) return;
    final target = (index ?? activeTab.value).clamp(0, _tabs.length - 1).toInt();
    _tabs.removeAt(target);
    if (_tabs.isEmpty) {
      activeTab.value = 0;
      url.value = '';
      _bumpTabs();
      try {
        await run('location.href = "about:blank"');
      } catch (_) {}
      return;
    }
    final next = target >= _tabs.length ? _tabs.length - 1 : target;
    activeTab.value = next;
    _bumpTabs();
    final tab = _tabs[next];
    if (tab.url.isEmpty) return;
    _loading = Completer<void>();
    // Start the neighbour's load but do not sit on it: a slow page made
    // `browser_tab_close` run past the tool timeout even though the tab was gone.
    // A following read waits for the load itself (see `/read`).
    await controller.loadRequest(Uri.parse(tab.url));
  }

  /// Ref generation: every snapshot starts a new one, and a ref from an older one is
  /// stale. Without it a cached number silently points at whatever moved into that
  /// slot after the page changed ("叫地主" → "出牌").
  int refGeneration = 0;

  /// `s3:18` → generation 3, index 18; null for anything else (a bare index from an
  /// older app counts as stale, not as "not found").
  static ({int generation, int index})? parseRef(Object? raw) {
    final match = raw is String ? RegExp(r'^s(\d{1,6}):(\d{1,6})$').firstMatch(raw) : null;
    if (match == null) return null;
    return (generation: int.parse(match.group(1)!), index: int.parse(match.group(2)!));
  }

  /// A snapshot of the page's actionable elements, paged: [offset] / [limit] into the
  /// filtered list, [query] filters by text. The refs it returns carry this
  /// generation and are valid until the next snapshot.
  Future<Map<String, Object?>> snapshot({int offset = 0, int limit = 40, String? query}) async {
    final generation = ++refGeneration;
    final clampedLimit = limit.clamp(1, 100).toInt();
    final clampedOffset = offset < 0 ? 0 : offset;
    final raw = await run(_snapshotScript(generation, clampedOffset, clampedLimit, query ?? ''));
    final text = _stringOf(raw);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } catch (_) {}
    return {'ok': false, 'error': 'snapshot_failed', 'message': '这个页面取不到元素，稍后重试'};
  }

  /// After a tap: what changed since the last snapshot, not the whole page again.
  /// Returns the diff and starts a new ref generation for the changed refs.
  Future<Map<String, Object?>> clickDiff() async {
    final raw = await run(_diffScript(refGeneration));
    final text = _stringOf(raw);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } catch (_) {}
    return {'changed': const [], 'added': const [], 'removed': 0, 'total': 0};
  }

  /// Elements a snapshot can act on. `visible` says whether it is on screen now;
  /// `section` is the nearest heading, so a list of twenty "编辑" is readable.
  static String _snapshotScript(int generation, int offset, int limit, String query) => '''
(() => {
  const gen = $generation, offset = $offset, limit = $limit, query = ${jsonEncode(query)};
  const sel = 'a,button,input,textarea,select,[role=button],[onclick],[contenteditable="true"],[contenteditable=""]';
  const seen = new Set();
  const items = [];
  function pathOf(el) {
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && node !== document.body) {
      let index = 1;
      let prev = node.previousElementSibling;
      while (prev) { if (prev.tagName === node.tagName) index += 1; prev = prev.previousElementSibling; }
      parts.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
      node = node.parentElement;
    }
    return parts.join('>');
  }
  function sectionOf(el) {
    const box = el.closest('section,article,form,dialog,main,nav,aside,fieldset,li');
    const heading = box ? box.querySelector('h1,h2,h3,h4,h5,h6,legend') : null;
    const text = heading ? String(heading.innerText || '').trim() : '';
    if (text) return text.slice(0, 40);
    const page = document.querySelector('h1');
    return page ? String(page.innerText || '').trim().slice(0, 40) : '';
  }
  for (const e of document.querySelectorAll(sel)) {
    const isFile = e.tagName === 'INPUT' && String(e.type || '').toLowerCase() === 'file';
    if (!isFile && e.getClientRects().length === 0) continue;
    let t = (e.innerText || e.value || e.getAttribute('aria-label') || e.placeholder || '').trim().slice(0, 60);
    if (!t && isFile) t = '文件选择框';
    if (!t) continue;
    const key = isFile ? 'file|' + items.length : t + '|' + (e.tagName.toLowerCase() === 'button' ? 'a' : e.tagName.toLowerCase());
    if (seen.has(key)) continue;
    seen.add(key);
    const r = e.getBoundingClientRect();
    const item = { tag: e.tagName.toLowerCase(), text: t, path: pathOf(e) };
    if (isFile) item.file = true;
    if (e.disabled === true || e.getAttribute('aria-disabled') === 'true') item.disabled = true;
    if (e.checked === true || e.getAttribute('aria-checked') === 'true') item.checked = true;
    if (e.selected === true || e.getAttribute('aria-selected') === 'true' || e.getAttribute('aria-pressed') === 'true') item.selected = true;
    const section = sectionOf(e);
    if (section) item.section = section;
    item.visible = r.width > 0 && r.height > 0 && r.bottom >= 0 && r.top <= innerHeight && r.right >= 0 && r.left <= innerWidth;
    items.push({ el: e, item });
    if (items.length >= 800) break;
  }
  const needle = query.toLowerCase();
  const filtered = needle ? items.filter(({ item }) => item.text.toLowerCase().includes(needle)) : items;
  const page = filtered.slice(offset, offset + limit);
  const elements = page.map(({ el, item }, i) => {
    const ref = 's' + gen + ':' + (offset + i);
    el.setAttribute('data-dsh-ref', ref);
    return { ref, ...item };
  });
  window.__dshSnap = { gen, items: items.map(({ item }) => ({ path: item.path, text: item.text, tag: item.tag, checked: !!item.checked, disabled: !!item.disabled })) };
  const next = offset + page.length < filtered.length ? offset + page.length : null;
  return JSON.stringify({ gen, total: filtered.length, offset, limit, next, elements });
})()
''';

  /// Re-reads the page after a tap and reports what changed against the last
  /// snapshot by DOM path, with fresh refs for the changed elements only.
  static String _diffScript(int generation) => '''
(() => {
  const prev = (window.__dshSnap && window.__dshSnap.items) || [];
  const gen = $generation;
  const sel = 'a,button,input,textarea,select,[role=button],[onclick],[contenteditable="true"],[contenteditable=""]';
  const seen = new Set();
  const current = [];
  const byPath = new Map();
  function pathOf(el) {
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && node !== document.body) {
      let index = 1;
      let p = node.previousElementSibling;
      while (p) { if (p.tagName === node.tagName) index += 1; p = p.previousElementSibling; }
      parts.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
      node = node.parentElement;
    }
    return parts.join('>');
  }
  for (const e of document.querySelectorAll(sel)) {
    const isFile = e.tagName === 'INPUT' && String(e.type || '').toLowerCase() === 'file';
    if (!isFile && e.getClientRects().length === 0) continue;
    const t = (e.innerText || e.value || e.getAttribute('aria-label') || e.placeholder || '').trim().slice(0, 60);
    if (!t) continue;
    const key = isFile ? 'file|' + current.length : t + '|' + (e.tagName.toLowerCase() === 'button' ? 'a' : e.tagName.toLowerCase());
    if (seen.has(key)) continue;
    seen.add(key);
    const path = pathOf(e);
    const item = { path, text: t, tag: e.tagName.toLowerCase(), checked: e.checked === true || e.getAttribute('aria-checked') === 'true', disabled: e.disabled === true || e.getAttribute('aria-disabled') === 'true', el: e };
    current.push(item);
    byPath.set(path, e);
    if (current.length >= 400) break;
  }
  const prevMap = new Map(prev.map((p) => [p.path, p]));
  const curPaths = new Set(current.map((c) => c.path));
  const changed = [];
  const added = [];
  for (const c of current) {
    const old = prevMap.get(c.path);
    if (!old) added.push(c);
    else if (old.text !== c.text || old.tag !== c.tag || !!old.checked !== !!c.checked || !!old.disabled !== !!c.disabled) changed.push(c);
  }
  const removed = prev.filter((p) => !curPaths.has(p.path)).length;
  function fresh(entry, i) {
    // Refs handed out after a tap live above 1000, so they never collide with the
    // indices of the last snapshot; that snapshot's refs stay valid for elements
    // that did not change.
    const ref = 's' + gen + ':' + (1000 + i);
    const el = byPath.get(entry.path);
    if (el) el.setAttribute('data-dsh-ref', ref);
    return { ref, tag: entry.tag, text: entry.text, path: entry.path, checked: !!entry.checked, disabled: !!entry.disabled };
  }
  window.__dshSnap = { gen, items: current.map((c) => ({ path: c.path, text: c.text, tag: c.tag, checked: !!c.checked, disabled: !!c.disabled })) };
  return JSON.stringify({
    gen,
    changed: changed.slice(0, 20).map(fresh),
    added: added.slice(0, 20).map((c, i) => fresh(c, changed.length + i)),
    removed,
    total: current.length,
  });
})()
''';

  /// Screenshot of what the page currently shows (native: Flutter cannot
  /// capture a platform view).
  Future<Map<String, Object?>> screenshot() async {
    if (!opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
    try {
      final result = await const MethodChannel('dsh/browser-shot')
          .invokeMapMethod<String, Object?>('capture', {
            'dir': screenshotDir,
            // The live URL, not [url]: right after `open` the notifier can still hold
            // the previous page, and the native side picks the WebView by URL.
            'url': await currentUrl(),
            'maxSide': 1600,
            'quality': 80,
          });
      if (result == null) return {'error': 'capture_failed'};
      if (result['error'] != null) return Map<String, Object?>.from(result);
      return {'ok': true, ...result};
    } on PlatformException catch (e) {
      return {'error': 'capture_failed', 'message': e.message ?? e.code};
    }
  }

  /// Feeds [path] to the file input [ref] (browser_upload) by filling `input.files`
  /// with a real `File` and firing `input`/`change`.
  ///
  /// The click-into-the-chooser route does not work here: Chrome only opens a file
  /// chooser for a trusted (user) gesture, and a tool's programmatic `click()` is
  /// not one, so `onShowFileSelector` never runs. Building the `File` in the page
  /// needs no gesture and no chooser, and the page sees exactly what a person's
  /// pick would have given it.
  Future<Map<String, Object?>> upload(String ref, String path) async {
    if (!opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
    final file = File(path);
    final problem = _uploadProblem(file);
    if (problem != null) return problem;
    final name = file.uri.pathSegments.last;
    if (confirmUploads) {
      final host = Uri.tryParse(url.value)?.host ?? '';
      await ConsentStore.instance.load();
      // 「总是允许」按站点记：同一个站点反复传文件时不打断，但授权记录里能看见、能撤。
      final remembered = host.isNotEmpty && ConsentStore.instance.has('upload:$host');
      if (!remembered) {
        if (!BrowserUi.hasUi) {
          return {
            'error': 'denied',
            'message': '上传会把文件内容发给网页，需要用户在 App 里点确认；请让用户打开浏览器页面后重试',
          };
        }
        final choice = await BrowserUi.confirmUpload(name, host.isEmpty ? '这个页面' : host);
        if (choice == UploadConsent.deny) return {'error': 'denied', 'message': '用户取消了这个文件的上传'};
        if (choice == UploadConsent.always && host.isNotEmpty) {
          await ConsentStore.instance.remember(
            ConsentGrant(
              kind: 'upload',
              scope: host,
              label: '上传到 $host',
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
              sensitive: true,
              requires: const <String>['browser', 'files'],
            ),
          );
        }
      }
    }
    final bytes = await file.readAsBytes();
    final mime = BrowserUi.mimeFor(name);
    final base64Data = base64Encode(bytes);
    // A multi-megabyte argument would ride in one evaluateJavaScript call; hand it
    // over in chunks instead, then build the File from what the page kept.
    await run('window.__dshUp = ""; true');
    const chunkSize = 2 * 1024 * 1024;
    for (var offset = 0; offset < base64Data.length; offset += chunkSize) {
      final end = offset + chunkSize < base64Data.length ? offset + chunkSize : base64Data.length;
      final chunk = base64Data.substring(offset, end);
      await run('window.__dshUp += ${jsonEncode(chunk)}; true');
    }
    final fillScript = '''
(() => {
  const el = document.querySelector('[data-dsh-ref="$ref"]');
  if (!el) return "missing";
  if (String(el.tagName || "").toLowerCase() !== "input" || String(el.type || "").toLowerCase() !== "file") return "not_file";
  const bin = atob(window.__dshUp || "");
  window.__dshUp = "";
  const data = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) data[i] = bin.charCodeAt(i);
  const file = new File([data], ${jsonEncode(name)}, { type: ${jsonEncode(mime)} });
  const transfer = new DataTransfer();
  transfer.items.add(file);
  el.files = transfer.files;
  const assigned = el.files ? el.files.length : 0;
  // Remember the element and the count: a page that rebuilds its input in the change
  // handler detaches this one, and the file it got is still the one we handed over.
  window.__dshUpTarget = el;
  window.__dshUpCount = assigned;
  const before = assigned;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  const after = el.files ? el.files.length : 0;
  // Pages often copy the File into their own state and clear the input in the same
  // handler. "We set one, it is gone now" means the page took it, not that it refused.
  const cleared = before >= 1 && after === 0;
  return { count: after, assigned: before, cleared, name: file.name };
})()
''';
    final fill = await BrowserApi.runJs(this, fillScript, 60000);
    if (fill is Map && fill['error'] != null) return Map<String, Object?>.from(fill);
    final filled = fill is Map ? fill['result'] : null;
    if (filled == 'missing') return {'error': 'not_found', 'message': '这个编号不存在，请重新 snapshot'};
    if (filled == 'not_file') {
      return {'error': 'unsupported', 'message': '这个编号不是文件选择框（<input type=file>）'};
    }
    final assigned = filled is Map ? (filled['assigned'] as num?)?.toInt() ?? 0 : 0;
    final acceptedAtOnce = filled is Map ? (filled['count'] as num?)?.toInt() ?? 0 : 0;
    if (acceptedAtOnce >= 1) {
      return {'ok': true, 'path': path, 'name': name, 'bytes': bytes.length, 'files': acceptedAtOnce};
    }
    if (assigned >= 1 && filled is Map && filled['cleared'] == true) {
      // The page read the File and emptied the chooser in its change handler.
      return {'ok': true, 'path': path, 'name': name, 'bytes': bytes.length, 'files': 1, 'consumed': true};
    }
    if (assigned == 0) {
      // Android WebView refuses a scripted FileList on `input.files`. Ask the page to open
      // its own chooser and answer `onShowFileSelector` with this file instead of the picker:
      // the page then receives a genuine selection.
      pendingUploadPath = path;
      try {
        final clicked = await BrowserApi.runJs(
          this,
          '(() => { const e = document.querySelector(\'[data-dsh-ref="$ref"]\'); if (!e) return "missing"; e.click(); return "ok"; })()',
          5000,
        );
        final value = clicked is Map ? clicked['result'] : null;
        if (value == 'missing') {
          return {'error': 'not_found', 'message': '这个编号不存在，请重新 snapshot'};
        }
        final deadline = DateTime.now().add(const Duration(milliseconds: 2500));
        while (pendingUploadPath != null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (pendingUploadPath == null) {
          return {'ok': true, 'path': path, 'name': name, 'bytes': bytes.length, 'files': 1, 'via': 'chooser'};
        }
      } finally {
        pendingUploadPath = null;
      }
      return {
        'error': 'unsupported',
        'message': '这个 WebView 不接受脚本塞文件，页面也没打开自己的选择框。'
            '把浏览器面板切到前台再传一次，或在页面上手动点「选择文件」。',
        'files': 0,
        'assigned': 0,
        'visible': pageVisible,
        'url': url.value,
      };
    }
    // A page may fill `input.files` from its own change handler, a frame or a re-render
    // later. Ask again for up to two seconds instead of judging one snapshot: a false
    // failure here makes the model upload the same file over and over.
    final probeScript = '''
(() => {
  const el = document.querySelector('[data-dsh-ref="$ref"]');
  const target = window.__dshUpTarget;
  if (!el) return { state: "missing", detached: !!(target && target.isConnected === false) };
  if (String(el.tagName || "").toLowerCase() !== "input" || String(el.type || "").toLowerCase() !== "file") return { state: "not_file" };
  const files = el.files;
  // A component may move the File into a fresh input it created: look for it.
  let moved = 0;
  if (!files || files.length === 0) {
    for (const other of document.querySelectorAll('input[type=file]')) {
      if (other !== el && other.files && other.files.length > 0) { moved = other.files.length; break; }
    }
  }
  return { state: "ok", count: files ? files.length : 0, moved, name: files && files[0] ? files[0].name : "" };
})()
''';
    var count = 0;
    var replaced = false;
    for (var attempt = 0; attempt < 10; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 200));
      final probe = await BrowserApi.runJs(this, probeScript, 5000);
      final value = probe is Map ? probe['result'] : null;
      if (value is! Map) continue;
      final state = value['state'];
      if (state == 'missing') {
        if (value['detached'] == true) {
          // The page replaced its input: it took the file and rebuilt the control.
          replaced = true;
          count = (value['count'] as num?)?.toInt() ?? 1;
          if (count < 1) count = 1;
          break;
        }
        return {'error': 'not_found', 'message': '这个编号不存在，请重新 snapshot'};
      }
      if (state == 'not_file') {
        return {'error': 'unsupported', 'message': '这个编号不是文件选择框（<input type=file>）'};
      }
      final picked = (value['count'] as num?)?.toInt() ?? 0;
      if (picked >= 1) {
        count = picked;
        break;
      }
      final moved = (value['moved'] as num?)?.toInt() ?? 0;
      if (moved >= 1) {
        // The page took it and put it in another input of its own.
        replaced = true;
        count = moved;
        break;
      }
    }
    if (count >= 1) {
      return {
        'ok': true,
        'path': path,
        'name': name,
        'bytes': bytes.length,
        'files': count,
        if (replaced) 'replaced': true,
      };
    }
    return {
      'error': 'unsupported',
      'message': '页面没有接受这个文件（等了 2 秒，选择框还是空的）。'
          '如果页面上已经显示了文件或开始上传，就不用重试；否则重新 snapshot 再传一次。',
      'files': 0,
      // Diagnostics for the next report: did anything reach the page at all?
      'assigned': assigned,
      'visible': pageVisible,
      'url': url.value,
    };
  }

  Map<String, Object?>? _uploadProblem(File file) {
    final normalized = file.path;
    if (!uploadFolders.any(normalized.startsWith)) {
      return {
        'error': 'denied',
        'message': '只允许上传 下载(Download) 和 DCIM 里的文件',
      };
    }
    final dot = normalized.lastIndexOf('.');
    final ext = dot > 0 ? normalized.substring(dot + 1).toLowerCase() : '';
    if (!allowedUploadExtensions.contains(ext)) {
      return {'error': 'unsupported', 'message': '不支持上传 .$ext 类型的文件'};
    }
    if (!file.existsSync()) {
      return {'error': 'not_found', 'message': '这个文件不在手机上'};
    }
    if (file.lengthSync() > maxUploadBytes) {
      return {'error': 'too_large', 'message': '这个文件超过 10MB，上传工具一次带不动；请改用更小的文件'};
    }
    return null;
  }

  /// The page opened a file input: hand it the file [upload] chose, or ask the
  /// person which one when they tapped the input themselves.
  Future<List<String>> _chooseFiles(FileSelectorParams params) async {
    final pending = pendingUploadPath;
    if (pending != null) {
      pendingUploadPath = null;
      return [Uri.file(pending).toString()];
    }
    // Only the person's own tap gets here (a trusted gesture). webview_flutter hands
    // the answer to Chrome as `Uri.parse(path)`, and a bare path has no scheme
    // there: send a file:// URI, which Chrome can open.
    final picked = await BrowserUi.pickFile(params.acceptTypes);
    return picked == null ? const [] : [Uri.file(picked).toString()];
  }

  static String _stringOf(Object? raw) {
    if (raw == null) return '';
    var text = raw.toString();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) return decoded;
      } catch (_) {}
    }
    return text;
  }
}

/// Raised when a tab cannot be shown; the tab list and the old selection stay.
class BrowserSwitchFailed implements Exception {
  const BrowserSwitchFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Raised when a ninth tab is asked for.
class BrowserTabsFull implements Exception {
  const BrowserTabsFull();

  @override
  String toString() => 'tabs_full';
}

/// 本机回环接口: the engine's tools reach the browser through this.
///
/// Fixed port so the plugin has nothing to discover; the token keeps other
/// apps on the phone out. The token is written where the engine can read it
/// (the shared storage), and stays in memory as a fallback.
class BrowserApi {
  static const port = 47811;
  static const tokenFile = '/sdcard/Download/DSH-Go/browser-api.json';

  static HttpServer? _server;
  static String _token = 'dshgo-local';

  static void publishSync() {
    try {
      _token = newToken();
      File(tokenFile).createSync(recursive: true);
      File(tokenFile).writeAsStringSync(jsonEncode({'port': port, 'token': _token}));
    } catch (e) {
      debugPrint('browser api token file not written: $e');
    }
  }

  static Future<void> start() async {
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true);
      _server = server;
      server.listen(_handle);
      debugPrint('browser api on 127.0.0.1:$port');
    } catch (e) {
      debugPrint('browser api not started: $e');
    }
  }

  static Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      final auth = request.headers.value('x-dsh-token');
      if (auth != _token) {
        response.statusCode = HttpStatus.forbidden;
        response.write(jsonEncode({'error': 'bad token'}));
        return;
      }
      final body = request.method == 'POST'
          ? jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>
          : <String, dynamic>{};
      final result = await _route(request.uri.path, body);
      response.write(jsonEncode(result));
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'error': '$e'}));
    } finally {
      await response.close();
    }
  }

  /// Which capability switch a route needs. `/state`, `/capabilities` and `/dav/config`
  /// stay open, so the model can always ask what is going on.
  static const _needs = <String, List<String>>{
    '/open': ['browser'],
    '/read': ['browser'],
    '/snapshot': ['browser'],
    '/click': ['browser'],
    '/type': ['browser'],
    '/js': ['browser'],
    '/screenshot': ['browser'],
    '/tabs': ['browser'],
    '/tab-open': ['browser'],
    '/tab-switch': ['browser'],
    '/tab-close': ['browser'],
    '/upload': ['browser', 'files'],
    '/download': ['files'],
    '/dav/ls': ['cloud'],
    '/dav/search': ['cloud'],
    '/dav/upload': ['cloud', 'files'],
    '/dav/download': ['cloud', 'files'],
    '/kb/search': ['files'],
    '/kb/stats': ['files'],
    '/kb/docs': ['files'],
    '/kb/read': ['files'],
    '/kb/import': ['files'],
    '/kb/reindex': ['files'],
    '/kb/delete': ['files'],
    '/kb/put': ['files'],
    '/kb/crawl': ['files'],
    '/notify/status': ['notify'],
    '/notify/list': ['notify'],
    '/notify/search': ['notify'],
    '/notify/digest': ['notify'],
    '/notify/rules': ['notify'],
    '/notify/rule-add': ['notify'],
    '/notify/rule-remove': ['notify'],
    '/notify/hits': ['notify'],
  };

  static Future<Object?> _route(String path, Map<String, dynamic> body) async {
    final session = BrowserSession.instance;
    for (final key in _needs[path] ?? const <String>[]) {
      if (CapabilityGuard.allows(key)) continue;
      CapabilityGuard.noteDenial(key, path);
      return {'error': 'denied', 'capability': key, 'message': CapabilityGuard.messageFor(key)};
    }
    if (path == '/capabilities') return {'ok': true, ...CapabilityGuard.describe()};
    switch (path) {
      case '/state':
        return {
          'open': session.opened,
          'url': session.url.value,
          'visible': session.pageVisible,
          'loading': session.loading,
          'refGeneration': session.refGeneration,
          'tabs': _tabsOf(session),
        };
      case '/open':
        final checked = _validUrl(body['url'] as String?);
        if (checked.error != null) return checked.error!;
        final target = checked.url!;
        try {
          final finalUrl = await session.open(target);
          if (session.lastLoadTimedOut) {
            session.markLoadFailed();
            return {
              'error': 'load_timeout',
              'message': '页面 10 秒内没加载完（网络不通、站点太慢，或被代理挡住），现在可能是空白页。检查网络后重试。',
              'url': target,
              'finalUrl': finalUrl,
              'loading': session.loading,
              'tabs': _tabsOf(session),
            };
          }
          final mark = await session.loadErrorMark();
          if (mark.isNotEmpty) {
            session.markLoadFailed();
            return {
              'error': 'load_error',
              'message': '页面没打开：$target（$mark）。网址或网络有问题，读不到这个页面。',
              'url': target,
              'finalUrl': finalUrl,
              'loading': session.loading,
              'tabs': _tabsOf(session),
            };
          }
          return {
            'ok': true,
            'url': target,
            'finalUrl': finalUrl,
            'loading': session.loading,
            'tabs': _tabsOf(session),
          };
        } on BrowserTabsFull {
          return _full();
        }
      case '/tabs':
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/tab-open':
        final wanted = (body['url'] as String?)?.trim() ?? '';
        final checked = _validUrl(wanted);
        if (wanted.isNotEmpty && checked.error != null) return checked.error!;
        final target = wanted.isEmpty ? '' : checked.url!;
        try {
          if (target.isEmpty) {
            session.newTab();
          } else {
            await session.open(target, newTab: true);
          }
        } on BrowserTabsFull {
          return _full();
        }
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/tab-switch':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        final index = _tabIndex(session, body);
        if (index == null) return {'error': 'not_found', 'message': '没有这个标签'};
        try {
          await session.switchTo(index);
        } on BrowserSwitchFailed catch (error) {
          // The tabs are still there and the old one is still selected; say what failed.
          return {
            'error': 'switch_failed',
            'message': error.message,
            'tabs': _tabsOf(session),
            'activeIndex': session.activeTab.value,
          };
        }
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/tab-close':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        final index = _tabIndex(session, body);
        if (index == null) return {'error': 'not_found', 'message': '没有这个标签'};
        try {
          await session.closeTab(index);
        } on Object catch (error) {
          return {
            'error': 'switch_failed',
            'message': '关闭标签后打开下一个失败：$error',
            'tabs': _tabsOf(session),
            'activeIndex': session.activeTab.value,
          };
        }
        if (!session.opened) return {'ok': true, 'tabs': const [], 'closed': true};
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/screenshot':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        return await session.screenshot();
      case '/upload':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        final checked = _refOf(session, body['ref']);
        if (checked.error != null) return checked.error!;
        final file = (body['path'] as String?)?.trim();
        if (file == null || file.isEmpty) return {'error': 'path required'};
        return await session.upload(checked.ref!, file);
      case '/snapshot':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        final offset = (body['offset'] as int?) ?? 0;
        final limit = (body['limit'] as int?) ?? 40;
        final query = (body['query'] as String?)?.trim();
        final snapshot = await session.snapshot(offset: offset, limit: limit, query: query);
        if (snapshot['error'] != null) return snapshot;
        final next = snapshot['next'];
        return {
          ...snapshot,
          'ok': true,
          if (next != null) 'truncated': true,
          if (next != null) 'note': '还有更多元素：用 offset=$next 继续翻，或用 query 过滤',
        };
      case '/read':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        await session.waitLoaded(const Duration(seconds: 3));
        final raw = await session.run('document.body ? document.body.innerText.slice(0, 20000) : ""');
        final text = BrowserSession._stringOf(raw);
        final mark = await session.loadErrorMark();
        if (mark.isNotEmpty || text.contains('ERR_') || text.contains('网页无法打开') || text.contains('This site can')) {
          final reason = mark.isNotEmpty ? mark : text.split('\n').first;
          return {'error': 'load_error', 'message': '页面加载失败：$reason'};
        }
        if (text.trim().isEmpty) {
          return {
            'ok': true,
            'text': '',
            'message': '这个标签页是空白的，没有文字',
            'note': '可能是新开的空白页，或者还没加载完；先 browser_open 一个网址',
          };
        }
        return {'ok': true, 'text': text};
      case '/js':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        final code = (body['code'] as String?) ?? '';
        if (code.trim().isEmpty) return {'error': 'code required'};
        final timeoutMs = (body['timeoutMs'] as int?) ?? 10000;
        return await runJs(session, code, timeoutMs.clamp(1000, 60000).toInt());
      case '/download':
        final target = (body['url'] as String?)?.trim();
        if (target == null || target.isEmpty) return {'error': 'url required'};
        return await _download(target, body['filename'] as String?);
      case '/click':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        final checked = _refOf(session, body['ref']);
        if (checked.error != null) return checked.error!;
        final ref = checked.ref!;
        final raw = await session.run(
          '(() => { const e = document.querySelector(\'[data-dsh-ref="$ref"]\'); if (!e) return "missing"; e.click(); return "ok"; })()',
        );
        if (BrowserSession._stringOf(raw) == 'missing') {
          return {'error': 'stale_ref', 'message': '这个编号不存在或已经过期，重新 browser_snapshot 再点'};
        }
        // A click that navigates takes a moment to show up; wait a little so a read
        // straight after it is not answered with the previous page.
        await session.waitForNavigation();
        final diff = await session.clickDiff();
        return {
          'ok': true,
          'url': session.url.value,
          'loading': session.loading,
          'refGeneration': session.refGeneration,
          'tabs': _tabsOf(session),
          ...diff,
        };
      case '/type':
        if (!session.opened) return {'error': 'browser_closed', 'message': '浏览器没打开，先 browser_open'};
        final checked = _refOf(session, body['ref']);
        if (checked.error != null) return checked.error!;
        final ref = checked.ref!;
        final text = (body['text'] as String?) ?? '';
        final script = '''
(() => {
  const e = document.querySelector('[data-dsh-ref="$ref"]');
  if (!e) return "missing";
  const tag = String(e.tagName || "").toLowerCase();
  const type = String(e.type || "text").toLowerCase();
  const texty = tag === "input" && !["checkbox","radio","file","submit","button","image","range","color"].includes(type);
  if (!(tag === "textarea" || texty || e.isContentEditable === true)) return "not_editable";
  e.focus();
  if (e.isContentEditable === true) { e.innerText = ${jsonEncode(text)}; }
  else { e.value = ${jsonEncode(text)}; }
  e.dispatchEvent(new Event("input", { bubbles: true }));
  e.dispatchEvent(new Event("change", { bubbles: true }));
  return "ok";
})()
''';
        final raw = await session.run(script);
        final answer = BrowserSession._stringOf(raw);
        if (answer == 'missing') {
          return {'error': 'stale_ref', 'message': '这个编号不存在或已经过期，重新 browser_snapshot 再填'};
        }
        if (answer == 'not_editable') {
          return {'error': 'not_editable', 'message': '这个元素不是输入框（input/textarea/contenteditable 才能填字），请重新 snapshot 找输入框'};
        }
        return {'ok': true, 'ref': ref};
      case '/kb/search':
        final query = (body['query'] as String?)?.trim() ?? '';
        if (query.isEmpty) return {'error': 'query required'};
        final hits = await _kb.search(query, limit: (body['limit'] as int?) ?? 8);
        return {
          'ok': true,
          'hits': [
            for (final hit in hits)
              {
                'doc': hit.docPath,
                'chunk': hit.chunkIndex,
                'score': hit.score,
                'snippet': hit.snippet,
                'text': hit.text,
              },
          ],
        };
      case '/kb/stats':
        final stats = await _kb.stats();
        return {
          'ok': true,
          'docs': stats.docs,
          'chunks': stats.chunks,
          'bytes': stats.totalBytes,
          'builtAt': stats.builtAtMs,
          'skipped': stats.skippedFiles,
          'root': KbIndex.rootDir,
        };
      case '/kb/docs':
        final docs = await _kb.docs();
        return {
          'ok': true,
          'docs': [
            for (final doc in docs) {'path': doc.path, 'bytes': doc.bytes, 'chunks': doc.chunks.length},
          ],
        };
      case '/kb/read':
        final doc = (body['doc'] as String?) ?? '';
        final chunk = (body['chunk'] as int?) ?? 0;
        final text = _kb.readChunkText(doc, chunk);
        if (text == null) {
          final docs = await _kb.docs();
          if (!docs.any((item) => item.path == doc)) {
            return {'error': 'not_found', 'message': '知识库里没有这个文档：$doc。先用 kb_search 或 kb_list 看有哪些文档'};
          }
          return {'error': 'not_found', 'message': '这个文档没有第 $chunk 块（块序号从 0 开始），先 kb_search 看命中的块'};
        }
        return {'ok': true, 'doc': doc, 'chunk': chunk, 'text': text};
      case '/kb/import':
        final path = (body['path'] as String?)?.trim() ?? '';
        if (path.isEmpty) return {'error': 'path required'};
        final outcome = await _kb.importFile(path);
        if (outcome == KbImportOutcome.unsupported) {
          final dot = path.lastIndexOf('.');
          final ext = dot > 0 ? path.substring(dot + 1).toLowerCase() : '';
          return {
            'error': 'unsupported_type',
            'message': '不支持${ext.isEmpty ? '没有扩展名的文件' : ' .$ext 文件'}'
                '（只收 ${KbIndex.supportedExtensions.join(' / ')}），没有复制进知识库',
          };
        }
        if (outcome == KbImportOutcome.missing) {
          return {'error': 'not_found', 'message': '这个文件不在手机上：$path'};
        }
        if (outcome == KbImportOutcome.failed) {
          return {'error': 'import_failed', 'message': '导入失败：复制或重建索引时出错（磁盘满或没有写权限）'};
        }
        final after = await _kb.stats();
        if (outcome == KbImportOutcome.duplicate) {
          return {
            'ok': true,
            'outcome': outcome.name,
            'note': '知识库里已经有内容完全相同的文档，没有重复复制',
            'docs': after.docs,
            'chunks': after.chunks,
          };
        }
        return {'ok': true, 'outcome': outcome.name, 'docs': after.docs, 'chunks': after.chunks};
      case '/kb/reindex':
        final rebuilt = await _kb.rebuild();
        return {'ok': true, 'docs': rebuilt.docs, 'chunks': rebuilt.chunks, 'bytes': rebuilt.totalBytes};
      case '/kb/delete':
        final doc = (body['doc'] as String?)?.trim() ?? '';
        if (doc.isEmpty) return {'error': 'doc required', 'message': '要删哪个文档？传 doc 路径'};
        final removed = await _kb.deleteDoc(doc);
        final after = await _kb.stats();
        return removed
            ? {'ok': true, 'doc': doc, 'docs': after.docs, 'chunks': after.chunks}
            : {'error': 'not_found', 'message': '知识库里没有这个文档：$doc'};
      case '/kb/put':
        final url = (body['url'] as String?)?.trim() ?? '';
        final text = (body['text'] as String?) ?? '';
        if (url.isEmpty || text.trim().isEmpty) return {'error': 'url and text required'};
        final outcome = await _kb.putWebDoc(url: url, text: text, title: body['title'] as String?);
        final stats = outcome == KbPutResult.failed ? await _kb.stats() : await _kb.refresh();
        return {'ok': outcome != KbPutResult.failed, 'outcome': outcome.name, 'docs': stats.docs, 'chunks': stats.chunks};
      case '/kb/crawl':
        final start = (body['url'] as String?)?.trim() ?? '';
        if (start.isEmpty) return {'error': 'url required'};
        final render = (body['render'] as bool?) ?? false;
        if (render && !CapabilityGuard.allows('browser')) {
          CapabilityGuard.noteDenial('browser', path);
          return {'error': 'denied', 'capability': 'browser', 'message': CapabilityGuard.messageFor('browser')};
        }
        final crawl = await CrawlService().crawl(
          start: start,
          depth: (body['depth'] as int?) ?? 1,
          limit: (body['limit'] as int?) ?? 10,
          sameDomain: (body['same_domain'] as bool?) ?? true,
          render: render,
          index: _kb,
        );
        final stats = await _kb.refresh();
        // Nothing fetched at all (wrong scheme, robots-blocked, unreachable) is a failed
        // crawl, not a success with failed: 1 buried in the counts.
        return {'ok': crawl.fetched > 0, ...crawl.toJson(), 'docs': stats.docs, 'chunks': stats.chunks};
      case '/notify/status':
        final status = await NotifyBridge.status();
        return {'ok': true, 'granted': status.granted, 'count': status.count};
      case '/notify/list':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final items = await NotifyBridge.list(
          limit: (body['limit'] as int?) ?? 30,
          app: body['app'] as String?,
        );
        return {'ok': true, 'items': [for (final item in items) item.toJson()]};
      case '/notify/search':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final items = await NotifyBridge.search(
          (body['query'] as String?) ?? '',
          limit: (body['limit'] as int?) ?? 30,
        );
        return {'ok': true, 'items': [for (final item in items) item.toJson()]};
      case '/notify/rules':
        return {'ok': true, 'rules': await _ruleList()};
      case '/notify/rule-add':
        final keyword = (body['keyword'] as String?)?.trim() ?? '';
        if (keyword.isEmpty) return {'error': 'keyword required'};
        final action = (body['action'] as String?) == 'remind' ? 'remind' : 'record';
        await NotifyBridge.addRule(keyword, action);
        return {'ok': true, 'rules': await _ruleList()};
      case '/notify/rule-remove':
        await NotifyBridge.removeRule((body['keyword'] as String?)?.trim() ?? '');
        return {'ok': true, 'rules': await _ruleList()};
      case '/notify/hits':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final hits = await NotifyBridge.hits(limit: (body['limit'] as int?) ?? 50);
        return {'ok': true, 'items': [for (final hit in hits) hit.toJson()]};
      case '/notify/digest':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final apps = await NotifyBridge.summary();
        final items = await NotifyBridge.list(limit: (body['limit'] as int?) ?? 40);
        final lines = [
          for (final app in apps.take(12))
            '[${app['app']}] ${app['count']} 条，最新：${app['latest']}',
        ];
        return {
          'ok': true,
          'apps': apps,
          'summary': lines.join('\n'),
          'items': [for (final item in items) item.toJson()],
        };
      case '/dav/config':
        return {'ok': true, 'configured': WebdavConfig.configured, 'address': WebdavConfig.address, 'user': WebdavConfig.user};
      case '/dav/ls':
        return await WebdavClient.list((body['path'] as String?) ?? '/');
      case '/dav/upload':
        return await WebdavClient.upload(
          local: (body['local'] as String?) ?? '',
          remote: (body['remote'] as String?) ?? '',
        );
      case '/dav/download':
        return await WebdavClient.download(
          remote: (body['remote'] as String?) ?? '',
          filename: body['filename'] as String?,
        );
      case '/dav/search':
        return await WebdavClient.search(
          query: (body['query'] as String?) ?? '',
          path: (body['path'] as String?) ?? '/',
        );
      default:
        return {'error': 'unknown path'};
    }
  }

  static Future<List<Map<String, Object?>>> _ruleList() async => [
    for (final rule in await NotifyBridge.rules()) {'keyword': rule.keyword, 'action': rule.action},
  ];

  /// 知识库: one instance is enough; it keeps the parsed index in memory.
  static final KbIndex _kb = KbIndex();

  static Object _notifyDenied() => {
    'error': 'denied',
    'message': '还没有通知读取权限：请用户在 设置 → 通知使用权（或 能力控制 → 通知）里打开 DSH Go',
  };

  /// The ref a tool sent, checked against the page's current snapshot generation.
  static ({String? ref, Object? error}) _refOf(BrowserSession session, Object? raw) {
    final parsed = BrowserSession.parseRef(raw);
    if (parsed == null) {
      // A bare number is what older versions returned: it cannot be trusted any more,
      // and saying "stale" tells the caller exactly what to do (snapshot again).
      if (raw is int) {
        return (
          ref: null,
          error: {
            'error': 'stale_ref',
            'message': '这个编号来自旧版本/旧快照，重新 browser_snapshot 拿新编号（形如 s3:18）',
            'refGeneration': session.refGeneration,
          },
        );
      }
      return (
        ref: null,
        error: {
          'error': 'bad_ref',
          'message': 'ref 要传 browser_snapshot 返回的编号（形如 s3:18），不要自己编',
        },
      );
    }
    if (parsed.generation != session.refGeneration) {
      return (
        ref: null,
        error: {
          'error': 'stale_ref',
          'message': '这个编号来自旧快照（页面已经变过），重新 browser_snapshot 再操作',
          'refGeneration': session.refGeneration,
        },
      );
    }
    return (ref: 's${parsed.generation}:${parsed.index}', error: null);
  }

  static ({String? url, Object? error}) _validUrl(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return (url: null, error: {'error': 'url required'});
    final uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return (
        url: null,
        error: {
          'error': 'bad_url',
          'message': '网址不对：要 http:// 或 https:// 开头并带域名（例如 https://example.com），/ 开头的相对地址用不了',
        },
      );
    }
    return (url: text, error: null);
  }

  static Object _full() => {'error': 'tabs_full', 'message': '最多 ${BrowserSession.maxTabs} 个标签，先关掉一个'};

  static List<Map<String, Object?>> _tabsOf(BrowserSession session) => [
    for (final tab in session.tabs) tab.toJson(session.currentTab?.id ?? -1),
  ];

  /// A tab from `index` or `id` in the request body.
  static int? _tabIndex(BrowserSession session, Map<String, dynamic> body) {
    final index = body['index'];
    if (index is int && index >= 0 && index < session.tabs.length) return index;
    final id = body['id'];
    if (id is int) {
      final found = session.tabs.indexWhere((tab) => tab.id == id);
      if (found >= 0) return found;
    }
    if (index == null && id == null) return session.activeTab.value;
    return null;
  }

  static Future<Object?> runJs(BrowserSession session, String code, int timeoutMs) async {
    final id = DateTime.now().microsecondsSinceEpoch;
    final wrapped = '''
window.__dshJs = { id: $id, done: false };
(async () => {
  try {
    const __v = await (async () => { $code })();
    let __s;
    const __repl = (k, v) => (v && typeof v === 'object' && typeof v.nodeType === 'number')
      ? { tag: String(v.tagName || '').toLowerCase(), text: String(v.innerText || '').slice(0, 200), html: String(v.outerHTML || '').slice(0, 200) }
      : v;
    try { __s = JSON.stringify(__v === undefined ? null : __v, __repl); } catch (e) { __s = String(__v); }
    if (__s !== undefined && __s.length > 32768) __s = __s.slice(0, 32768);
    window.__dshJs = { id: $id, done: true, value: __s };
  } catch (e) {
    const line = String(e && e.stack ? e.stack : e).split('\\n')[0];
    window.__dshJs = { id: $id, done: true, error: line };
  }
})();
true
''';
    await session.run(wrapped);
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final raw = await session.run('JSON.stringify(window.__dshJs || null)');
      final text = BrowserSession._stringOf(raw);
      if (text.isEmpty || text == 'null') continue;
      try {
        final state = jsonDecode(text);
        if (state is! Map || state['id'] != id || state['done'] != true) continue;
        if (state['error'] != null) return {'error': 'js_error', 'message': '${state['error']}'};
        final value = state['value'];
        if (value is! String) return {'ok': true, 'result': value};
        try {
          return {'ok': true, 'result': jsonDecode(value)};
        } catch (_) {
          return {'ok': true, 'result': value};
        }
      } catch (_) {
        continue;
      }
    }
    return {'error': 'timeout', 'message': '脚本运行超过 ${timeoutMs}ms 还没返回'};
  }

  static Future<Object?> _download(String url, String? filename) async {
    try {
      final client = HttpClient();
      ProxyRoute.apply(client);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode >= 400) {
        return {'error': 'not_found', 'message': '服务器返回 ${response.statusCode}'};
      }
      final dir = Directory('/sdcard/Download/DSH-Go');
      await dir.create(recursive: true);
      var name = filename?.trim();
      if (name == null || name.isEmpty) {
        final segment = Uri.parse(url).pathSegments.isEmpty ? 'download' : Uri.parse(url).pathSegments.last;
        name = segment.isEmpty ? 'download' : segment;
      }
      var file = File('${dir.path}/$name');
      var index = 1;
      while (await file.exists()) {
        final dot = name.lastIndexOf('.');
        final base = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        file = File('${dir.path}/$base ($index)$ext');
        index += 1;
      }
      final sink = file.openWrite();
      var bytes = 0;
      await for (final chunk in response) {
        bytes += chunk.length;
        if (bytes > 1024 * 1024 * 1024) {
          await sink.close();
          await file.delete();
          return {'error': 'too_large', 'message': '文件超过 1GB'};
        }
        sink.add(chunk);
      }
      await sink.close();
      return {'ok': true, 'path': file.path, 'bytes': bytes, 'mime': response.headers.contentType?.mimeType ?? ''};
    } on FileSystemException {
      return {'error': 'denied', 'message': '没有存储权限，无法写入下载目录'};
    } catch (e) {
      return {'error': 'unsupported', 'message': '下载失败：$e'};
    }
  }

  static String newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }
}

/// Dialogs the browser raises while a tool drives it.
/// 上传确认的答案。总是允许按站点记进授权记录，可撤销。
enum UploadConsent { deny, once, always }

class BrowserUi {
  /// The app's navigator, set once the app is built (app.dart).
  static GlobalKey<NavigatorState>? navigatorKey;

  static BuildContext? get context => navigatorKey?.currentContext;

  static bool get hasUi => context != null;

  /// False when the app is not on screen: uploading sends the file out, so
  /// without a person to ask there is no consent.
  static Future<bool> confirm(String title, String message, {String yes = '允许', String no = '取消'}) async {
    final page = context;
    if (page == null) return false;
    final answer = await showDialog<bool>(
      context: page,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(no)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(yes)),
        ],
      ),
    );
    return answer ?? false;
  }

  /// 上传确认的三个答案：不传、只这次、这个站点以后都允许。
  static Future<UploadConsent> confirmUpload(String fileName, String host) async {
    final page = context;
    if (page == null) return UploadConsent.deny;
    final answer = await showDialog<UploadConsent>(
      context: page,
      builder: (context) => AlertDialog(
        title: const Text('上传文件'),
        content: Text('要把「$fileName」传到 $host 吗？上传后这个页面就能读到它的内容。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(UploadConsent.deny), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(UploadConsent.always),
            child: const Text('总是允许（这个站点）'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(UploadConsent.once),
            child: const Text('允许本次'),
          ),
        ],
      ),
    );
    return answer ?? UploadConsent.deny;
  }

  /// The person tapped a file input: a short sheet of recent allowed files.
  static Future<String?> pickFile(List<String> acceptTypes) async {
    final page = context;
    if (page == null) return null;
    final files = _recentFiles(acceptTypes);
    return showModalBottomSheet<String>(
      context: page,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择要上传的文件', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            if (files.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('下载 和 DCIM 里还没有能上传的文件'),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final file in files)
                    ListTile(
                      dense: true,
                      title: Text(file.uri.pathSegments.last, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(file.path),
                      onTap: () => Navigator.of(context).pop(file.path),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<File> _recentFiles(List<String> acceptTypes) {
    final found = <File>[];
    for (final folder in BrowserSession.uploadFolders) {
      final dir = Directory(folder);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is File) found.add(entity);
        }
      } catch (_) {}
    }
    found.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return found.where((file) => _accepts(file, acceptTypes)).take(40).toList();
  }

  static bool _accepts(File file, List<String> acceptTypes) {
    final path = file.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 ? path.substring(dot + 1) : '';
    if (!BrowserSession.allowedUploadExtensions.contains(ext)) return false;
    if (acceptTypes.isEmpty) return true;
    for (final type in acceptTypes) {
      final t = type.trim().toLowerCase();
      if (t.isEmpty || t == '*/*') return true;
      if (t.startsWith('.')) {
        if (t.substring(1) == ext) return true;
      } else if (t.endsWith('/*')) {
        final prefix = t.substring(0, t.length - 1);
        if (_mimeOf(ext).startsWith(prefix)) return true;
      } else if (t == _mimeOf(ext)) {
        return true;
      }
    }
    return false;
  }

  /// The MIME type a page should see for [name].
  static String mimeFor(String name) {
    final dot = name.lastIndexOf('.');
    return _mimeOf(dot > 0 ? name.substring(dot + 1).toLowerCase() : '');
  }

  static String _mimeOf(String ext) => switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'pdf' => 'application/pdf',
    'zip' => 'application/zip',
    'txt' || 'md' || 'log' => 'text/plain',
    'json' => 'application/json',
    'mp4' => 'video/mp4',
    'mp3' => 'audio/mpeg',
    _ => 'application/octet-stream',
  };
}

/// Keeps the WebView alive under the app: full size, covered by the chat
/// while the browser page is closed, so tools can still read, click and
/// capture it without the page popping up over the conversation.
class BrowserHost extends StatelessWidget {
  const BrowserHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Rebuilds when the page is shown and when a tab appears or goes: a page the
    // tools opened while the browser screen was closed still has to be mounted,
    // or it has no size to lay out (and no snapshot, no screenshot).
    return Stack(
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([BrowserSession.instance.visible, BrowserSession.instance.tabsRevision]),
          builder: (context, _) {
            final session = BrowserSession.instance;
            if (session.visible.value || !session.opened) return const SizedBox.shrink();
            return Positioned.fill(
              child: IgnorePointer(
                child: WebViewWidget(key: const ValueKey('browser-host'), controller: session.controller),
              ),
            );
          },
        ),
        child,
      ],
    );
  }
}
