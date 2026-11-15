// 浏览器工具: the app's in-app browser, reached over its loopback API. Registered from this
// bundle so they ship with the runtime (no separate plugin to install).
//
// The app writes { port, token } to the shared folder; without that file the defaults below
// are used, which is also what the app falls back to.
import { readFileSync } from "node:fs";

const CONFIG = "/sdcard/Download/DSH-Go/browser-api.json";
const DEFAULT = { port: 47811, token: "dshgo-local" };

const CLOSED = "App 的浏览器页面没有打开：请用户点输入框旁的地球图标打开浏览器，再重试。";

function config() {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG, "utf8"));
    if (parsed && parsed.port && parsed.token) return parsed;
  } catch {}
  return DEFAULT;
}

async function call(path, body, timeoutMs = 15000) {
  const { port, token } = config();
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: body ? "POST" : "GET",
    headers: { "x-dsh-token": token, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeoutMs),
  });
  let json = {};
  try {
    json = await res.json();
  } catch {}
  if (!res.ok) throw new Error(json.error ?? `http ${res.status}`);
  return json;
}

const OUT = {
  schema: { type: "object", additionalProperties: true },
  // A blank page answers `text: ""` plus a `message`; showing the empty string alone made
  // browser_read look like a tool error with no explanation. Only take `text` when it has
  // content, and otherwise keep the message/note in front of the JSON.
  render: (_args, value) => {
    const text = typeof value?.text === "string" ? value.text : null;
    if (text !== null && text.trim() !== "") return [{ type: "text", text }];
    const message = typeof value?.message === "string" ? value.message : "";
    const note = typeof value?.note === "string" ? value.note : "";
    if (text !== null && message) {
      return [{ type: "text", text: [message, note].filter(Boolean).join("\n") + "\n" + JSON.stringify(value, null, 2) }];
    }
    return [{ type: "text", text: JSON.stringify(value, null, 2) }];
  },
};

function tool(spec) {
  const properties = spec.properties ?? {};
  const required = Object.keys(properties).filter((key) => properties[key].required);
  const clean = {};
  for (const [key, value] of Object.entries(properties)) {
    const { required: _required, ...rest } = value;
    clean[key] = rest;
  }
  return {
    name: spec.name,
    description: spec.description,
    parameters: { type: "object", properties: clean, required, additionalProperties: false },
    output: OUT,
    execute: spec.execute,
  };
}

/** The browser tools, in the order the model should reach for them. */
function definitions() {
  return [
    tool({
      name: "capability_state",
      description: "查能力控制里各开关的当前状态（哪些会真的拦工具、哪些还没接入），以及最近的拒绝记录。工具返回 denied 时先用它确认是哪个能力被关了。",
      execute: () => call("/capabilities"),
    }),
    tool({
      name: "browser_state",
      description: "看 App 内置浏览器当前状态：是否打开、在哪个网址、有哪些标签（每个标签带 id 和是否当前）。要处理任何网页任务前先调它。",
      execute: () => call("/state"),
    }),
    tool({
      name: "browser_open",
      description: "在 App 内置浏览器里打开一个网址（在当前标签里打开；没有标签时自动开一个）。凡是需要网页、登录、点按的任务都默认用它，不必等用户指定。页面在后台加载，不打断用户对话；用户要看时点输入框旁的地球图标。",
      properties: { url: { type: "string", required: true, description: "完整网址，https:// 开头" } },
      execute: async (args) => {
        const result = await call("/open", { url: args.url });
        if (result.error === "browser_closed") throw new Error(CLOSED);
        return result;
      },
    }),
    tool({
      name: "browser_read",
      description: "读当前标签页面的正文文字（最多两万字）。",
      execute: () => call("/read"),
    }),
    tool({
      name: "browser_snapshot",
      description: "列出当前标签页面上可操作的元素，每项带编号 ref（形如 s3:18）和文字，以及 disabled/checked/selected/section（所属区块标题）/visible（是否在屏幕内）。点按、填表、上传都用这个编号；编号只在本次快照有效，页面变了要重新 snapshot，否则会报 stale_ref。默认 40 条，多出来的用 offset 翻页或用 query 过滤。文件选择框即使被藏在样式后面也会列出来并带 file:true。",
      properties: {
        offset: { type: "integer", description: "从第几条开始，默认 0（用上一页返回的 next）" },
        limit: { type: "integer", description: "这一页几条，默认 40，最多 100" },
        query: { type: "string", description: "只列文字包含这段内容的元素" },
      },
      execute: (args) => call("/snapshot", { offset: args.offset ?? 0, limit: args.limit ?? 40, query: args.query }),
    }),
    tool({
      name: "browser_screenshot",
      description: "把当前标签的可视区域截成一张图，存到手机的 下载/DSH-Go/screenshots 并返回路径。页面样子看不清、要确认排版或验证码图片时用它。返回 {ok,path,width,height,bytes}，最长边 1600、JPEG、不超过 500KB。",
      execute: () => call("/screenshot", {}, 30000),
    }),
    tool({
      name: "browser_js",
      description: "在当前标签里执行一段你现写的 JavaScript（可 await、可 fetch、可读写 localStorage）。用它一步取数据，别用几十次点击硬点；结果按 JSON 返回，超过 32KB 截断。副作用：脚本能改页面、能用登录态发请求。",
      properties: {
        code: { type: "string", required: true, description: "要执行的脚本，直接写语句，最后的表达式或 return 值会作为结果" },
        timeoutMs: { type: "integer", description: "超时毫秒，默认 10000，最大 30000" },
      },
      execute: (args) => call("/js", { code: args.code, timeoutMs: args.timeoutMs ?? 10000 }),
    }),
    tool({
      name: "browser_download",
      description: "下载一个文件到手机的 下载/DSH-Go 目录，下载完成才返回。下载前先问用户是否要存到手机。",
      properties: {
        url: { type: "string", required: true, description: "文件的完整网址" },
        filename: { type: "string", description: "保存的文件名，省略则用网址末段" },
      },
      execute: (args) => call("/download", { url: args.url, filename: args.filename }),
    }),
    tool({
      name: "browser_click",
      description: "点击当前标签页面上编号为 ref 的元素（编号来自 browser_snapshot，形如 s3:18）。返回这次点按后的差异（changed/added/removed），不是整页重列；顺带给出 url 与 loading。",
      properties: { ref: { type: "string", required: true, description: "browser_snapshot 给出的编号（如 s3:18）" } },
      execute: (args) => call("/click", { ref: args.ref }),
    }),
    tool({
      name: "browser_type",
      description: "往当前标签页面上编号为 ref 的输入框里填文字（编号来自 browser_snapshot）。",
      properties: {
        ref: { type: "string", required: true, description: "browser_snapshot 给出的编号（如 s3:18），必须是输入框/textarea/contenteditable" },
        text: { type: "string", required: true, description: "要填进去的文字" },
      },
      execute: (args) => call("/type", { ref: args.ref, text: args.text }),
    }),
    tool({
      name: "browser_upload",
      description: "把手机上的一个文件填进页面的文件选择框（先 snapshot 找到带 file:true 的 ref）。只允许 下载(Download) 和 DCIM 里的文件、扩展名要在白名单里、单个不超过 10MB；默认会请用户在 App 里确认，用户不在或不确认返回 denied。填好后页面会收到 input/change 事件，和用户亲手选中一样。",
      properties: {
        ref: { type: "string", required: true, description: "文件选择框的编号（browser_snapshot 给出，如 s3:18）" },
        path: { type: "string", required: true, description: "手机上的完整路径，例如 /sdcard/Download/a.pdf" },
      },
      execute: (args) => call("/upload", { ref: args.ref, path: args.path }, 180000),
    }),
    tool({
      name: "browser_tabs",
      description: "列出浏览器所有标签：id、网址、标题、哪个是当前。下面的标签工具用 id 指定。",
      execute: () => call("/tabs"),
    }),
    tool({
      name: "browser_tab_open",
      description: "开一个新标签（最多 8 个）。给 url 就在新标签里打开它，不给就是空白标签。",
      properties: { url: { type: "string", description: "新标签要打开的网址，省略为空白页" } },
      execute: (args) => call("/tab-open", { url: args.url }),
    }),
    tool({
      name: "browser_tab_switch",
      description: "切换到指定标签。切换会重新加载那个标签的网址，页面里的临时填写会丢。",
      properties: { id: { type: "integer", required: true, description: "browser_tabs 给出的标签 id" } },
      execute: (args) => call("/tab-switch", { id: args.id }),
    }),
    tool({
      name: "browser_tab_close",
      description: "关掉一个标签（默认当前标签），关掉当前标签会自动切到相邻的一个；全关掉浏览器就回到未打开状态。",
      properties: { id: { type: "integer", description: "要关的标签 id，省略为当前标签" } },
      execute: (args) => call("/tab-close", { id: args.id }),
    }),
  ];
}

/**
 * Registers the browser tools on the tools service and answers the disposer.
 * A tool that is already registered (the standalone plugin installed too) is
 * skipped rather than failing the whole bridge.
 */
export function registerBrowserTools(ctx) {
  const disposers = [];
  for (const definition of definitions()) {
    try {
      disposers.push(ctx.tools.register(definition));
    } catch (error) {
      if (!/already registered/.test(String(error?.message))) throw error;
    }
  }
  return () => {
    for (const dispose of disposers.splice(0)) {
      try {
        dispose();
      } catch {}
    }
  };
}
