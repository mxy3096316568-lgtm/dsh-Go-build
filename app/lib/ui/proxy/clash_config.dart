// 内置代理的配置清洗：把订阅/粘贴来的 Clash YAML 交给内核之前，把这台 App 自己
// 管的几个顶层键换成我们的值。
//
// 为什么要有这一层：服务商的订阅里本来就有 `mode`、`log-level`、`mixed-port`。
// 我们再加一份，内核就报 `fatal: duplicate key`；而只删不加、或者只在一条路径上
// 做，同样有问题（粘贴的配置常带 CRLF，单行正则根本匹配不到）。所以这里按行解析
// 顶层键：出现过的直接丢掉，连同它缩进的值一起，最后统一在最前面写我们的一份。
//
// 纯 Dart，不 import Flutter：可以在 App 之外直接跑测试。

/// 这台 App 自己决定取值的顶层键。
const Set<String> ownedClashKeys = <String>{
  'mixed-port',
  'port',
  'socks-port',
  'redir-port',
  'tproxy-port',
  'allow-lan',
  'bind-address',
  'external-controller',
  'secret',
  'external-ui',
  'mode',
  'log-level',
  // 订阅里的 tun 段是给「有 VPN 权限的客户端」用的：这个 App 不开 VPN，mihomo 照着
  // 配置去开 /dev/net/tun 只会拿到权限错误。它必须在交给内核前被删掉。
  'tun',
};

/// [yaml] 去掉所有 [ownedClashKeys] 后的内容，前面补上本 App 的值。
///
/// 保证每个受管键最多出现一次；别的键（`proxies`、`rules`、`proxy-groups`…）原样保留。
String sanitizeClashConfig(String yaml, {required int port}) {
  final lines = yaml.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final kept = <String>[];
  var dropping = false;
  for (final line in lines) {
    final top = RegExp(r'^([A-Za-z0-9_][A-Za-z0-9_-]*)[ \t]*:').firstMatch(line);
    if (top != null) {
      dropping = ownedClashKeys.contains(top.group(1));
      if (dropping) continue;
      kept.add(line);
      continue;
    }
    if (dropping) {
      // 缩进行属于刚丢掉的那个键的值；空行或新的顶层键结束它（新键走上面的分支）。
      if (line.trim().isEmpty) {
        dropping = false;
        kept.add(line);
      } else if (line.startsWith(' ') || line.startsWith('\t')) {
        continue;
      } else {
        dropping = false;
        kept.add(line);
      }
      continue;
    }
    kept.add(line);
  }
  while (kept.isNotEmpty && kept.first.trim().isEmpty) {
    kept.removeAt(0);
  }
  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  final header = <String>[
    'mixed-port: $port',
    'allow-lan: false',
    'bind-address: 127.0.0.1',
    'external-controller: 127.0.0.1:9091',
    'mode: rule',
    'log-level: warning',
  ];
  return '${header.join('\n')}\n${kept.join('\n')}\n';
}
