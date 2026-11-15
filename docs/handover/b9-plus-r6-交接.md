# 新窗口交接：b9-plus r6（2026-11-15 11:15）

> 先读这一篇。不要从头调研，不要重做已改的部分。

## 0. 一句话状态

用户 10:45 的清单 F1–F6 代码已全改，推到 `dsh-Go-build` 的 `93e99cd`；
**构建 run 43670984231 进行中**（11:08 开始，arm64，约 19 分钟，约 11:28 完）。
后台 job `bash-e6c063d438574f36` 在等它结束并下载到 `下载/DSH-Go/`。
出包后：校验 → 交付 → 用户只验三件（代理「测试连通性」、上传、空白页 read）。

## 1. 仓库与包

| 项 | 值 |
|---|---|
| 仓库 | `github.com/mxy3096316568-lgtm/dsh-Go-build`（不是 fork） |
| main | `93e99cd` |
| 本轮包 | `DSH-Go-1.12-b9-plus-r6-arm64.apk` |
| 签名 | 同前（release key `dshgo`，可覆盖安装） |
| 旧仓库 | 仍未删；token 无 `delete_repo`，需所有者在网页删 |

## 2. 这轮改了什么（对着用户 10:45 清单）

| 编号 | 文件 | 做法 |
|---|---|---|
| F1 代理 | `proxy/ProxyPlugin.kt` | `ProxyController` 移到主线程并 `CountDownLatch` 等回调（原来在 worker 调，异常被 catch 成「不支持」，WebView 静默走直连——最可能的真凶）；删 `addDirect()` 静默回退；新增 `test`（从 7890 真发 Google/维基 HTTPS）；启动成功后自动自检；每次 start/stop/test 写 `/sdcard/Download/DSH-Go/proxy-status.json`（含状态+日志尾 25 行） |
| F1 配置 | `proxy/clash_config.dart` | 启动前剥掉订阅里的 `tun:` 段（无 VPN 权限必失败） |
| F1 页面 | `settings/proxy_page.dart`、`proxy/proxy_service.dart` | 「测试连通性」按钮 + 结果行；页面打开时若「配置有、内核没了」自动重拉 |
| F2 上传 | `ui/browser/browser_session.dart` | 只留一条路：真触摸。坐标乘 `visualViewport.scale`，用 `elementFromPoint` 校验落点，最多两次；失败回包带 `tap:{x,y,scale}`；Kotlin 侧加 `requestFocus`、`SOURCE_TOUCHSCREEN`、DOWN/UP 间隔 90ms |
| F3 空白 read | `runtime/bridge/dsh-go-bridge/lib/browser-tools.js` | `render` 原来只要 `text` 是字符串就只显示它，`text:""` 吞掉 `message`；现在空文本显示 message+note |
| F4 title 串页 | `ui/browser/browser_session.dart` | `pageInfo()` 一次 JS 同时取 url/title/错误标记/正文长度；`onPageFinished` 只在文档 url 与回调 url 一致时写 title；`/open` 返回前 `refreshTitle()` |
| F5 超时误判 | 同上 | 10 秒到了不判死：有正文（≥20 字）且非 chrome-error → `ok:true + warning`；只有真错误页 `load_error`，完全没字才 `load_timeout` |
| F6 手点 | 同上 | 快照元素带 `link`；`browser_click` 回 `target:{tag,text,clickable}`，不可点时 warning「这里不是链接」 |

## 3. 环境与出包（这轮踩到的坑，别重踩）

- **`mirror/` 是稀疏工作集**：只有改过的文件。`dart analyze` 在 `mirror/app` 会报几千个「URI 不存在」——必须用完整树：
  `cd /root/workspace/repo/app && FLUTTER_ROOT=/root/sdk/flutter /root/sdk-dart/dart-sdk/bin/dart analyze` → 应 `No issues found!`
  流程：改 `mirror/` → `cp` 到 `repo/` 同名路径 → analyze。
- **kotlinc 要先加 JDK 到 PATH**，否则 `java: command not found`：
  `export PATH=/usr/lib/jvm/java-17-openjdk-arm64/bin:$PATH`
  `cd repo/app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app && /root/kt/kotlinc/bin/kotlinc -nowarn -cp "/root/kt/android.jar:/root/kt/webkit.jar:/root/sdk/flutter/bin/cache/artifacts/engine/android-arm64/flutter.jar" proxy/ProxyPlugin.kt proxy/MihomoProcess.kt web/BrowserShotPlugin.kt -d /tmp/ktcheck`
- **推送**：`push_quick.py` 只从 `mirror/` 读文件，路径写仓库相对路径。
- **构建**：`ghapi.post('actions/workflows/build-apk.yml/dispatches', {'ref':'main','inputs':{'abi':'arm64'}})` → 204；网络常超时，需重试。
- **`ship_newrepo.py` 没有重试**：网络一抖就整段挂掉。要包一层 `for i in $(seq 1 40)` + 检查目标文件是否已存在。
- **校验**：sha256、`zipfile.testzip()`、`libapp.so` 里 UTF-16 字符串、dex、`apksigner` 指纹。

## 4. 用户装上 r6 只验三件

1. 代理页 →「测试连通性」：通 → 代理可用；不通 → 读 `下载/DSH-Go/proxy-status.json`（`lastTest` 说 Google/维基；`log` 说内核为什么没起）。
2. 上传一次（ilovepdf 或 example.com 注入 input）：还失败就按用户 F2 的 b 案，把工具改成「面板里手动选文件」，**不要再修第三遍**。
3. 空白页 `browser_read`：应回「这个标签页是空白的，没有文字」，不再是空回包。

## 5. 决策与边界（上一轮定下的，别再犯）

- **不再加兜底**：一处真相（状态只在一处算）、失败要响（不许静默直连/静默成功）、修不好就删功能。
- **不做 Java 全量重写**。备选方案是把 browser 的 Dart 会话层合并进原生 `BrowserService`（3–5 天），用户当前不让动。
- 代理**只覆盖 App 内 WebView / 下载 / 云盘**，不改系统路由和 DNS；对外不要说成 VPN。
- 删了 `addDirect()` 之后，内核一死网页会**直接打不开**——这是有意的（宁可报错，不要假通）。

## 6. 待办

- [ ] r6 出包 → 校验 → 交付（sha256/签名/字符串）
- [ ] 用户测三件（见上）
- [ ] 旧仓库网页删除
- [ ] 代理仍不通 → 只按 `proxy-status.json` 改一处，不再盲修
