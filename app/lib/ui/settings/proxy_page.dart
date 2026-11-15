import 'package:flutter/material.dart';

import '../proxy/proxy_service.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// 内置代理: a Clash (mihomo) subscription that only this app uses.
///
/// Off by default. The kernel listens on 127.0.0.1, WebView is pointed at it through
/// ProxyController, and downloads / 云盘 go through it too — nothing outside the app is
/// routed, so the switch can be turned off at any time with no system dialog.
class ProxyPage extends StatefulWidget {
  const ProxyPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const ProxyPage());

  @override
  State<ProxyPage> createState() => _ProxyPageState();
}

class _ProxyPageState extends State<ProxyPage> {
  final _subscription = TextEditingController();
  final _port = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _failed = false;

  /// What the switch is doing right now (`starting` / `stopping`). Kept here, not in
  /// [ProxyService], so the tap shows 「启动中…」 at once and a failure stays on screen
  /// instead of falling back to 「已停止」.
  String? _phase;
  String? _failure;

  @override
  void initState() {
    super.initState();
    final state = ProxyService.state.value;
    _subscription.text = state.subscription;
    _port.text = '${state.port}';
    // A kernel can be gone after the app was restarted while the switch stayed on: check
    // once when the page opens instead of showing a switch that is "on" over nothing.
    ProxyService.refresh().then((state) {
      if (state.configured && !state.running) ProxyService.start(quiet: true);
    });
  }

  @override
  void dispose() {
    _subscription.dispose();
    _port.dispose();
    super.dispose();
  }

  void _say(String text, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _failed = failed;
    });
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _phase = 'starting';
      _failure = null;
    });
    try {
      final port = int.tryParse(_port.text.trim());
      final problem = await ProxyService.applySubscription(_subscription.text, port: port);
      if (problem != null) {
        if (mounted) setState(() => _failure = problem);
        _say(problem, failed: true);
        return;
      }
      _say('已启动，本 App 的网页和下载走 127.0.0.1:${ProxyService.state.value.port}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = null;
        });
      }
    }
  }

  /// The kernel's last log line, for the line under a failed start.
  Future<String> _lastKernelLine() async {
    final log = await ProxyService.log();
    return log.split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  }

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    if (on && !ProxyService.state.value.configured) {
      const reason = '还没有订阅：先把订阅地址填上，点「导入并启动」';
      setState(() {
        _phase = null;
        _failure = reason;
      });
      _say(reason, failed: true);
      return;
    }
    setState(() {
      _busy = true;
      _phase = on ? 'starting' : 'stopping';
      _failure = null;
    });
    _say(on ? '启动中…' : '正在关闭…');
    try {
      if (on) {
        // The port field is the source of truth on this page: apply it before starting,
        // otherwise an edited port looked accepted but the kernel still used the old one.
        final typed = int.tryParse(_port.text.trim());
        if (typed != null && typed >= 1024 && typed <= 65535 && typed != ProxyService.state.value.port) {
          await ProxyService.setPort(typed);
        }
        final next = await ProxyService.start();
        if (!next.running) {
          final reason = next.hint.isEmpty ? '内核没起来，看下面的内核日志' : next.hint;
          final first = await _lastKernelLine();
          if (mounted) setState(() => _failure = reason);
          _say(
            [
              reason,
              if (first.isNotEmpty) '内核：${first.length > 160 ? first.substring(first.length - 160) : first}',
            ].join('\n'),
            failed: true,
          );
          return;
        }
        _say('已开启');
      } else {
        await ProxyService.stop();
        _say('已关闭，网页恢复直连');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = null;
        });
      }
    }
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    _say('测试中…（每个站最多 8 秒）');
    try {
      final line = await ProxyService.testProxy();
      final ok = ProxyService.state.value.lastTest?['ok'] == true;
      _say(line ?? '测完了', failed: !ok);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showLog() async {
    final text = await ProxyService.log();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('内核日志'),
        content: SingleChildScrollView(
          child: SelectableText(text.isEmpty ? '（还没有日志）' : text, style: const TextStyle(fontSize: 11)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<ProxyState>(
      valueListenable: ProxyService.state,
      builder: (context, state, _) {
        return AppPage.list(
          title: '内置代理',
          subtitle: const Text('只对 DSH Go 生效，不接管手机其他应用'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '填服务商的 Clash 订阅地址（返回 YAML 的那种），或者直接粘贴 Clash 配置。内核是 mihomo，'
                '监听 127.0.0.1；网页、下载、云盘都走它。不开 VPN，所以不会有系统授权弹窗，关掉就回到直连。',
                style: theme.textTheme.bodySmall,
              ),
            ),
            SettingsSection(
              title: '状态',
              children: [
                SettingsTile(
                  key: const ValueKey('proxy-status'),
                  icon: Icons.hub,
                  title: '代理',
                  subtitle: _phase == 'starting'
                      ? '启动中…'
                      : _phase == 'stopping'
                          ? '正在关闭…'
                          : state.running
                              ? '运行中 · 127.0.0.1:${state.port}${state.webViewProxy ? ' · 网页已接管' : ' · 网页未接管'}'
                              : _failure != null
                                  ? '启动失败'
                                  : (state.configured ? '已停止' : '还没导入订阅'),
                  value: Text(state.running && _phase != 'stopping' ? '开' : _phase == 'starting' ? '启动中' : '关'),
                ),
                SettingsSwitchTile(
                  key: const ValueKey('proxy-switch'),
                  icon: Icons.toggle_on,
                  title: '启用',
                  subtitle: _phase == 'starting'
                      ? '启动中…（最多等 20 秒）'
                      : _phase == 'stopping'
                          ? '正在关闭…'
                          : _failure != null
                              ? '启动失败：$_failure'
                              : state.kernel
                                  ? '内核已随安装包一起装上'
                                  : '这个安装包里没有内核（点了会说明原因）',
                  // While an attempt is running the switch is disabled so a second tap
                  // cannot start a parallel attempt; otherwise it always takes a tap, even
                  // when the kernel is missing (the reason then shows on screen).
                  value: state.running || _phase == 'starting',
                  onChanged: _busy ? null : _toggle,
                ),
              ],
            ),
            SettingsSection(
              title: '订阅',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    key: const ValueKey('proxy-subscription'),
                    controller: _subscription,
                    minLines: 2,
                    maxLines: 4,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: 'Clash 订阅地址 / 配置',
                      hintText: 'https://…/subscribe?token=…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    key: const ValueKey('proxy-port'),
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '本地端口',
                      hintText: '7890',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                SettingsTile(
                  key: const ValueKey('proxy-import'),
                  icon: Icons.download,
                  title: _busy ? '处理中…' : '导入并启动',
                  subtitle: '下载订阅、写入配置、拉起内核，一次做完',
                  onTap: _busy ? null : _import,
                ),
              ],
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  _message!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _failed ? theme.colorScheme.error : theme.colorScheme.primary,
                  ),
                ),
              ),
            if (state.hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  state.hint,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            SettingsSection(
              title: '排查',
              children: [
                SettingsTile(
                  key: const ValueKey('proxy-test'),
                  icon: Icons.network_check,
                  title: '测试连通性',
                  subtitle: state.probeLine.isEmpty
                      ? '从代理端口真发两个请求（Google、维基），确认不是「端口在、出不去」'
                      : state.probeLine,
                  onTap: _busy ? null : _test,
                ),
                SettingsTile(
                  key: const ValueKey('proxy-log'),
                  icon: Icons.article,
                  title: '内核日志',
                  subtitle: '起不来的时候看最后 40 行',
                  onTap: _showLog,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Text(
                '说明：这个开关只接管 App 内的网页、下载和云盘，不改手机的系统 DNS 和路由；'
                '引擎自己连模型服务、终端的 curl/getent 都还是系统网络，国外域名被污染时它们照样解析不了。'
                '订阅里的节点选择、规则由内核按配置执行。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }
}
