import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'clash_config.dart';

/// 内置代理's live state (channel `dsh/proxy`, proxy/ProxyPlugin.kt).
class ProxyState {
  const ProxyState({
    this.running = false,
    this.port = 7890,
    this.webViewProxy = false,
    this.kernel = false,
    this.configured = false,
    this.error,
    this.subscription = '',
    this.hint = '',
  });

  final bool running;
  final int port;

  /// WebView actually uses the proxy (true once ProxyController accepted it).
  final bool webViewProxy;

  /// The kernel (`libmihomo.so`) is in the APK.
  final bool kernel;

  /// A subscription config was saved.
  final bool configured;

  final String? error;

  /// The last subscription URL or pasted config.
  final String subscription;

  /// A friendly line for the page, when something failed.
  final String hint;

  ProxyState copyWith({
    bool? running,
    int? port,
    bool? webViewProxy,
    bool? kernel,
    bool? configured,
    String? error,
    String? subscription,
    String? hint,
  }) => ProxyState(
    running: running ?? this.running,
    port: port ?? this.port,
    webViewProxy: webViewProxy ?? this.webViewProxy,
    kernel: kernel ?? this.kernel,
    configured: configured ?? this.configured,
    error: error ?? this.error,
    subscription: subscription ?? this.subscription,
    hint: hint ?? this.hint,
  );
}

/// 内置代理: a Clash (mihomo) kernel on 127.0.0.1, used by this app only — WebView through
/// `ProxyController`, downloads and the cloud client through [ProxyRoute]. No VPN, no system
/// setting: closing the switch puts everything back to direct.
class ProxyService {
  static const _channel = MethodChannel('dsh/proxy');

  static const _portKey = 'proxy.port';
  static const _subscriptionKey = 'proxy.subscription';
  static const _enabledKey = 'proxy.enabled';

  static final ValueNotifier<ProxyState> state = ValueNotifier(const ProxyState());

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final port = prefs.getInt(_portKey) ?? 7890;
      final subscription = prefs.getString(_subscriptionKey) ?? '';
      final enabled = prefs.getBool(_enabledKey) ?? false;
      final status = await _status();
      state.value = status.copyWith(port: port, subscription: subscription, configured: status.configured);
      if (enabled && !status.running) unawaited(start(quiet: true));
    } catch (_) {}
  }

  static Future<ProxyState> refresh() async {
    final status = await _status();
    state.value = status.copyWith(subscription: state.value.subscription);
    _applyRoute();
    return state.value;
  }

  /// Downloads (or takes) a Clash config, saves it, and starts the kernel.
  /// Returns null on success, otherwise the reason to show the person.
  static Future<String?> applySubscription(String input, {int? port}) async {
    final text = input.trim();
    if (text.isEmpty) return '先填订阅地址';
    String yaml;
    if (text.contains('proxies:') && text.contains('rules:')) {
      yaml = text;
    } else if (text.startsWith('http://') || text.startsWith('https://')) {
      try {
        final response = await http
            .get(Uri.parse(text), headers: {'user-agent': 'clash.meta'})
            .timeout(const Duration(seconds: 45));
        if (response.statusCode != 200) return '下载订阅失败（HTTP ${response.statusCode}）';
        final body = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (!body.contains('proxies:')) {
          return '这不是 Clash 配置。请用服务商提供的那种「Clash 订阅」地址，而不是 ss:// / vmess:// 分享链接。';
        }
        yaml = body;
      } on TimeoutException {
        return '订阅下载超时，检查网络或地址';
      } catch (error) {
        return '订阅下载失败：$error';
      }
    } else {
      return '填一个 https:// 开头的 Clash 订阅地址，或直接粘贴 Clash 配置';
    }
    final chosen = (port ?? state.value.port).clamp(1024, 65535).toInt();
    final config = sanitizeClashConfig(yaml, port: chosen);
    _configHead = config.split('\n').take(15).join('\n');
    try {
      final written = await _channel.invokeMapMethod<String, Object?>('writeConfig', {'content': config});
      if (written?['error'] != null) return '保存配置失败：${written?['message'] ?? written?['error']}';
    } on PlatformException catch (error) {
      return '保存配置失败：${error.message ?? error.code}';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subscriptionKey, text);
    await prefs.setInt(_portKey, chosen);
    await prefs.setBool(_enabledKey, true);
    state.value = state.value.copyWith(subscription: text, port: chosen, configured: true, hint: '');
    final result = await start();
    return result.running ? null : (result.hint.isEmpty ? '内核没起来，看能力控制 → 内置代理 里的日志' : result.hint);
  }

  static Future<ProxyState> start({bool quiet = false}) async {
    try {
      // A config written by an older version can still carry a second `mode` /
      // `log-level` (the kernel then dies with "duplicate key" and the switch never
      // turns on). Healing happens on every start, so an existing install is fixed
      // by tapping the switch — no re-import needed.
      await _healConfig();
      final map = await _channel.invokeMapMethod<String, Object?>('start', {'port': state.value.port});
      final next = _merge(map);
      state.value = next;
      _applyRoute();
      final prefs = await SharedPreferences.getInstance();
      if (next.running) await prefs.setBool(_enabledKey, true);
      return next;
    } on PlatformException catch (error) {
      if (!quiet) state.value = state.value.copyWith(hint: '启动失败：${error.message ?? error.code}', error: error.code);
      return state.value;
    }
  }

  /// Rewrites the config on disk through [sanitizeClashConfig] when it differs.
  ///
  /// Idempotent: a config this app generated comes back byte for byte, so a
  /// healthy file is not rewritten on every start. Failures are not fatal here —
  /// the kernel's own error (and the config head in the log) tells the story.
  static Future<void> _healConfig() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('readConfig');
      final content = map?['content'] as String?;
      if (content == null || content.isEmpty) return;
      final healed = sanitizeClashConfig(content, port: state.value.port);
      _configHead = healed.split('\n').take(15).join('\n');
      if (healed == content) return;
      await _channel.invokeMapMethod<String, Object?>('writeConfig', {'content': healed});
      debugPrint('proxy: repaired a config with duplicate keys');
    } catch (_) {
      // Missing plugin (tests) or an unreadable file: start will report it.
    }
  }

  static Future<ProxyState> stop() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('stop');
      state.value = _merge(map);
      _applyRoute();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, false);
      return state.value;
    } on PlatformException catch (error) {
      return state.value.copyWith(hint: '停止失败：${error.message ?? error.code}');
    }
  }

  static Future<String> log() async {
    String kernel;
    try {
      kernel = (await _channel.invokeListMethod<String>('log') ?? const []).join('\n');
    } catch (_) {
      kernel = '';
    }
    if (_configHead.isEmpty || state.value.error == null) return kernel;
    return '--- 本次生成的配置（前 15 行）---\n$_configHead\n--- 内核日志 ---\n$kernel';
  }

  /// The first 15 lines of the config this app wrote, kept for the log dialog when
  /// the kernel refuses to start: the mihomo log alone does not say what it was fed.
  static String _configHead = '';

  static Future<ProxyState> _status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      return _merge(map);
    } on PlatformException {
      return state.value.copyWith(kernel: false);
    } on MissingPluginException {
      return state.value.copyWith(kernel: false);
    }
  }

  static ProxyState _merge(Map<String, Object?>? map) {
    if (map == null) return state.value;
    final error = map['error'] as String?;
    final port = (map['port'] as num?)?.toInt() ?? state.value.port;
    return state.value.copyWith(
      running: map['running'] == true,
      port: port,
      webViewProxy: map['webViewProxy'] == true,
      kernel: map['kernel'] == true,
      configured: map['config'] == true,
      error: error,
      hint: _hintFor(map),
    );
  }

  static String _hintFor(Map<String, Object?> map) {
    // 旧版本写下的配置里 mode / log-level 各出现两次，内核直接 fatal，看起来像
    // 「端口没起来」。修复是按行重写配置（start 前会做），这里只把话说清楚。
    final kernelLog = map['log'];
    if (kernelLog is List && kernelLog.any((line) => '$line'.contains('duplicate key'))) {
      return '订阅配置里有重复的 mode / log-level，内核拒绝了这份配置。点「导入并启动」重新生成一次即可（新版启动前也会自动修复）。';
    }
    switch (map['error']) {
      case 'kernel_missing':
        return '这个安装包里没有代理内核（libmihomo.so），需要重新构建';
      case 'no_config':
        return '还没有导入订阅';
      case 'busy':
        return '上一次启动/停止还没结束，等几秒再看（这次没有重复启动）';
      case 'port_in_use':
        final port = (map['port'] as num?)?.toInt();
        return '端口 ${port ?? state.value.port} 已被其他应用占用，请换端口（上面「本地端口」改成别的，比如 ${((port ?? state.value.port) + 1)}）';
      case 'start_timeout':
        return '内核起来了但 20 秒内端口没就绪，而且端口没有被别的程序占用——可能是订阅配置有问题（看下面的日志）';
      case 'start_failed':
        return '内核启动失败：${map['message'] ?? ''}';
      case 'write_failed':
        return '配置写不进 App 目录：${map['message'] ?? ''}';
      default:
        return '';
    }
  }

  static void _applyRoute() {
    final current = state.value;
    ProxyRoute.httpProxy = current.running ? 'PROXY 127.0.0.1:${current.port}' : null;
  }
}

/// Where the app's own HTTP clients send requests: the local port while 内置代理 is on.
class ProxyRoute {
  static String? httpProxy;

  /// `findProxy` for a fresh [HttpClient].
  static void apply(HttpClient client) {
    final route = httpProxy;
    if (route != null) client.findProxy = (_) => route;
  }
}
