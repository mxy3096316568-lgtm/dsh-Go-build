import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../proxy/proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 云盘 (WebDAV) account: the address and the user name live in the app's
/// preferences, the password in the platform keystore (Android Keystore via
/// flutter_secure_storage) so it is never in a plain file.
class WebdavConfig {
  static const _addressKey = 'dav.address';
  static const _userKey = 'dav.user';
  static const _passwordKey = 'dav.password';
  static const _secure = FlutterSecureStorage();

  static String address = '';
  static String user = '';
  static String _password = '';
  static bool _loaded = false;

  static bool get configured => address.trim().isNotEmpty && _password.isNotEmpty;

  /// Reads the stored account once; call with [force] after the page saved.
  static Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      address = prefs.getString(_addressKey) ?? '';
      user = prefs.getString(_userKey) ?? '';
      _password = await _secure.read(key: _passwordKey) ?? '';
    } catch (_) {}
    _loaded = true;
  }

  static Future<String> password() async {
    await load();
    return _password;
  }

  static Future<void> save({required String address, required String user, required String password}) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = address.trim();
    await prefs.setString(_addressKey, clean);
    await prefs.setString(_userKey, user.trim());
    await _secure.write(key: _passwordKey, value: password);
    WebdavConfig.address = clean;
    WebdavConfig.user = user.trim();
    _password = password;
    _loaded = true;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_addressKey);
    await prefs.remove(_userKey);
    await _secure.delete(key: _passwordKey);
    address = '';
    user = '';
    _password = '';
    _loaded = true;
  }
}

/// 云盘 (WebDAV): list, upload, download and search a user's own WebDAV space
/// (坚果云, Nextcloud, ownCloud, Synology, a NAS…).
class WebdavClient {
  static const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop>
<d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/>
</d:prop></d:propfind>''';

  /// Where downloads land, next to the browser's own downloads.
  static const downloadDir = '/sdcard/Download/DSH-Go/webdav';

  /// A remote folder, one level deep.
  static Future<Object> list(String path) async {
    final ready = await _ready();
    if (ready != null) return ready;
    final uri = _uri(path);
    final response = await _send('PROPFIND', uri, body: _propfindBody, depth: '1');
    if (response is Map) return response;
    final xml = response as String;
    final entries = _entries(xml, uri).where((entry) => entry['path'] != _normalized(path)).toList();
    entries.sort((a, b) {
      final dirA = a['dir'] == true ? 0 : 1;
      final dirB = b['dir'] == true ? 0 : 1;
      if (dirA != dirB) return dirA - dirB;
      return '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase());
    });
    return {'ok': true, 'path': _normalized(path), 'entries': entries};
  }

  /// Uploads one phone file to [remote] (a folder path or a full file path).
  static Future<Object> upload({required String local, required String remote}) async {
    final ready = await _ready();
    if (ready != null) return ready;
    final file = File(local);
    if (!file.existsSync()) {
      return {'error': 'not_found', 'message': '要上传的文件不在手机上：$local'};
    }
    if (file.lengthSync() > 200 * 1024 * 1024) {
      return {'error': 'too_large', 'message': '文件超过 200MB，没法一次上传'};
    }
    var target = remote.trim();
    if (target.isEmpty || target.endsWith('/')) {
      target = '${_normalized(target)}/${file.uri.pathSegments.last}';
    }
    final uri = _uri(target);
    final bytes = await file.readAsBytes();
    final response = await _send('PUT', uri, bytes: bytes);
    if (response is Map) return response;
    return {'ok': true, 'remote': _normalized(target), 'bytes': bytes.length};
  }

  /// Downloads [remote] into 下载/DSH-Go/webdav/.
  static Future<Object> download({required String remote, String? filename}) async {
    final ready = await _ready();
    if (ready != null) return ready;
    final uri = _uri(remote);
    final client = _client();
    try {
      final request = http.Request('GET', uri)..headers.addAll(await _headers());
      final response = await client.send(request).timeout(const Duration(seconds: 60));
      if (response.statusCode == 401) {
        return {'error': 'denied', 'message': '账号或密码不对，请在 设置 → 云盘 里改一下'};
      }
      if (response.statusCode == 404) {
        return {'error': 'not_found', 'message': '云端没有这个文件'};
      }
      if (response.statusCode >= 400) {
        return {'error': 'unsupported', 'message': '服务器返回 ${response.statusCode}'};
      }
      final dir = Directory(downloadDir);
      await dir.create(recursive: true);
      var name = (filename ?? '').trim();
      if (name.isEmpty) {
        name = Uri.decodeFull(uri.pathSegments.isEmpty ? 'download' : uri.pathSegments.last);
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
      await for (final chunk in response.stream) {
        bytes += chunk.length;
        if (bytes > 2 * 1024 * 1024 * 1024) {
          await sink.close();
          await file.delete();
          return {'error': 'too_large', 'message': '文件超过 2GB'};
        }
        sink.add(chunk);
      }
      await sink.close();
      return {'ok': true, 'path': file.path, 'bytes': bytes};
    } on TimeoutException {
      return {'error': 'timeout', 'message': '下载超时，检查一下网络或代理'};
    } finally {
      client.close();
    }
  }

  /// Finds [query] in the names under [path] (three levels deep, 400 hits max).
  static Future<Object> search({required String query, String path = '/'}) async {
    final ready = await _ready();
    if (ready != null) return ready;
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return {'error': 'query required'};
    final hits = <Map<String, Object?>>[];
    final queue = <(String, int)>[(_normalized(path), 0)];
    var looked = 0;
    while (queue.isNotEmpty && hits.length < 400 && looked < 40) {
      final (folder, depth) = queue.removeAt(0);
      looked++;
      final uri = _uri(folder);
      final response = await _send('PROPFIND', uri, body: _propfindBody, depth: '1');
      if (response is Map) continue;
      for (final entry in _entries(response as String, uri)) {
        final relative = entry['path'] as String;
        if (relative == folder) continue;
        // 只匹配名字：拿整条路径匹配的话，查 "a" 会把 `/ai 做游戏/` 下所有子项都算命中。
        if ('${entry['name']}'.toLowerCase().contains(needle)) {
          hits.add(entry);
        }
        if (entry['dir'] == true && depth < 2) queue.add((relative, depth + 1));
      }
    }
    return {'ok': true, 'query': query, 'hits': hits};
  }

  /// Null when the account is set, otherwise the error a tool returns.
  static Future<Object?> _ready() async {
    await WebdavConfig.load();
    if (!WebdavConfig.configured) {
      return {
        'error': 'denied',
        'message': '还没设置云盘：请用户在 设置 → 帮助与关于 → 能力控制 → 云盘 里填地址、账号和密码',
      };
    }
    return null;
  }

  /// An HTTP client that follows 内置代理 when it is on.
  static http.Client _client() {
    final io = HttpClient();
    ProxyRoute.apply(io);
    return IOClient(io);
  }

  static Future<Map<String, String>> _headers() async => {
    'authorization': 'Basic ${base64Encode(utf8.encode('${WebdavConfig.user}:${await WebdavConfig.password()}'))}',
  };

  /// Sends a PROPFIND (or PUT) and answers with the body text, or the error map.
  static Future<Object> _send(
    String method,
    Uri uri, {
    String? body,
    List<int>? bytes,
    String? depth,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request(method, uri)..headers.addAll(await _headers());
      if (depth != null) request.headers['depth'] = depth;
      if (body != null) {
        request.headers['content-type'] = 'application/xml; charset=utf-8';
        request.bodyBytes = utf8.encode(body);
      } else if (bytes != null) {
        request.bodyBytes = bytes;
        request.headers['content-type'] = 'application/octet-stream';
      }
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      final text = await response.stream.bytesToString();
      if (response.statusCode == 401) {
        return {'error': 'denied', 'message': '账号或密码不对，请在 设置 → 云盘 里改一下'};
      }
      if (response.statusCode == 404) {
        return {'error': 'not_found', 'message': '云端没有这个目录'};
      }
      if (response.statusCode >= 400) {
        return {'error': 'unsupported', 'message': '服务器返回 ${response.statusCode}'};
      }
      return text;
    } on TimeoutException {
      return {'error': 'timeout', 'message': '云盘没有响应，检查一下网络或代理'};
    } on HandshakeException {
      return {'error': 'unsupported', 'message': 'HTTPS 证书有问题，换个地址试试'};
    } catch (e) {
      return {'error': 'unsupported', 'message': '连不上云盘：$e'};
    } finally {
      client.close();
    }
  }

  /// 账号地址里的目录部分（`https://host/webdav` → `/webdav/`），作为路径的基准。
  static String _accountBasePath() {
    final base = Uri.parse(WebdavConfig.address.trim());
    final path = base.path.endsWith('/') ? base.path : '${base.path}/';
    return path.isEmpty ? '/' : path;
  }

  static Uri _uri(String path) {
    final base = Uri.parse(WebdavConfig.address.trim());
    final clean = _normalized(path);
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: '$basePath${clean.replaceFirst(RegExp(r'^/+'), '')}');
  }

  static String _normalized(String path) {
    var clean = path.trim();
    if (clean.isEmpty) return '/';
    if (!clean.startsWith('/')) clean = '/$clean';
    return clean;
  }

  static List<Map<String, Object?>> _entries(String xml, Uri base) {
    final out = <Map<String, Object?>>[];
    // 一律相对账号根（地址里的路径，比如 /webdav）算：以前相对「这次查的目录」算，
    // search 从子目录拿到的就不是绝对路径，`/webdav/ai 做游戏/规范/` 再拿去 ls
    // 或 download 都 404；而 ls("/") 又是干净路径，两边对不上。
    final accountPath = _accountBasePath();
    for (final match in RegExp(r'<[A-Za-z0-9]*:?response[\s>].*?</[A-Za-z0-9]*:?response>', dotAll: true).allMatches(xml)) {
      final block = match.group(0)!;
      final raw = _tag(block, 'href');
      if (raw == null || raw.isEmpty) continue;
      final decodedHref = Uri.decodeFull(raw);
      final hrefPath = Uri.tryParse(decodedHref)?.path ?? decodedHref;
      // `Uri.path` keeps percent escapes: decode before taking the last segment, or a
      // name like 规范 (encoded %E8%A7%84%E8%8C%83) matches a search for "a".
      String decodedPath;
      try {
        decodedPath = Uri.decodeFull(hrefPath);
      } catch (_) {
        decodedPath = hrefPath;
      }
      final decoded = decodedPath.isEmpty ? '/' : decodedPath;
      final path = decoded.startsWith(accountPath)
          ? '/${decoded.substring(accountPath.length)}'
          : (decoded.startsWith('/') ? decoded : '/$decoded');
      // A folder may come back as <d:collection/> or, on servers that answer only
      // the asked-for props, just as a trailing-slash href.
      final isDir = RegExp(r'<[^>]*collection[^>]*>', caseSensitive: false).hasMatch(block) ||
          path.endsWith('/');
      // Some servers send a percent-encoded <displayname>: matching a search on it then
      // hits the hex escapes ("视频" → %E8%A7%86%E9%A2%91 contains "a"), which is exactly
      // how a one-letter query matched Chinese folders with no "a" in their names.
      String decodeName(String value) {
        try {
          return Uri.decodeFull(value);
        } catch (_) {
          return value;
        }
      }

      final display = _tag(block, 'displayname')?.trim();
      final name = display != null && display.isNotEmpty
          ? decodeName(display)
          : (path == '/' ? '/' : path.split('/').where((s) => s.isNotEmpty).last);
      out.add({
        'name': name,
        'path': path,
        'dir': isDir,
        'size': int.tryParse(_tag(block, 'getcontentlength') ?? '') ?? (isDir ? 0 : null),
        'modified': _tag(block, 'getlastmodified') ?? '',
      });
    }
    return out;
  }

  static String? _tag(String block, String name) {
    final match = RegExp('<[A-Za-z0-9]*:?$name[^>]*>(.*?)</[A-Za-z0-9]*:?$name>', dotAll: true, caseSensitive: false).firstMatch(block);
    final value = match?.group(1);
    if (value == null) return null;
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
  }
}
