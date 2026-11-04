import { getPreferenceValues, open } from "@raycast/api";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Nanolight runs us without a login shell, so every tool gets an absolute path.
const T3 = join(homedir(), ".t3/bin/t3");
const T3_APP = "/Applications/T3 Code (Nightly).app";
const OSASCRIPT = "/usr/bin/osascript";
const SCREENCAPTURE = "/usr/sbin/screencapture";
const SIPS = "/usr/bin/sips";
const SHOTS = join(homedir(), "Library/Caches/samin-quick-ask");

type Prefs = { model?: string; useScreen?: boolean; projects?: string; proxyUrl?: string; apiKey?: string };

export function prefs() {
  const p = getPreferenceValues<Prefs>();
  const projects = (p.projects || "~/SaminOS")
    .split(",")
    .map((s) => s.trim().replace(/^~(?=$|\/)/, homedir()))
    .filter(Boolean);
  return {
    model: p.model || "claude-haiku-5-5",
    useScreen: p.useScreen !== false && String(p.useScreen) !== "false",
    projects: projects.length ? projects : [join(homedir(), "SaminOS")],
    proxyUrl: (p.proxyUrl || "http://127.0.0.1:8317").replace(/\/$/, ""),
    apiKey: p.apiKey || keyFromEnvFile(),
  };
}

function keyFromEnvFile() {
  try {
    const text = readFileSync(join(homedir(), ".cli-proxy-api/keys.env"), "utf8");
    return text.match(/^CPA_API_KEY=["']?([^"'\n]+)/m)?.[1] ?? "";
  } catch {
    return "";
  }
}

function run(cmd: string, args: string[], opts: { input?: string; cwd?: string; timeout?: number } = {}) {
  return new Promise<string>((resolve, reject) => {
    const child = execFile(cmd, args, { cwd: opts.cwd, timeout: opts.timeout ?? 30000, maxBuffer: 1 << 24 }, (err, stdout, stderr) =>
      err ? reject(new Error((stderr || err.message).trim())) : resolve(stdout),
    );
    if (opts.input !== undefined) child.stdin?.end(opts.input);
  });
}

// ---------- Screen ----------

export type Screen = { path: string; app: string; title: string };

// Front window that isn't the launcher itself.
const FRONT_WINDOW_JXA = `
ObjC.import('CoreGraphics');
function run() {
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID)));
  const skip = /^(Nanolight|Window Server|Dock|Control Center|SystemUIServer|Notification Center|Spotlight)$/;
  for (const w of list) {
    const b = w.kCGWindowBounds || {};
    if (w.kCGWindowLayer !== 0 || skip.test(w.kCGWindowOwnerName || '') || (b.Width || 0) < 200 || (b.Height || 0) < 150) continue;
    return JSON.stringify({ id: w.kCGWindowNumber, app: w.kCGWindowOwnerName || '', title: w.kCGWindowName || '' });
  }
  return '';
}`;

export async function captureScreen(): Promise<Screen | null> {
  mkdirSync(SHOTS, { recursive: true });
  const path = join(SHOTS, `screen-${Date.now()}.jpg`);
  let win: { id?: number; app?: string; title?: string } = {};
  try {
    win = JSON.parse((await run(OSASCRIPT, ["-l", "JavaScript", "-e", FRONT_WINDOW_JXA], { timeout: 5000 })).trim() || "{}");
  } catch {
    // fall back to the whole screen
  }
  const target = win.id ? ["-o", `-l${win.id}`] : ["-m"];
  try {
    await run(SCREENCAPTURE, ["-x", "-t", "jpg", ...target, path], { timeout: 8000 });
    if (!existsSync(path)) return null;
    // Retina captures are huge; 1600px is plenty for the model and keeps it fast.
    await run(SIPS, ["-Z", "1600", path], { timeout: 8000 }).catch(() => undefined);
    return { path, app: win.app || "Screen", title: win.title || "" };
  } catch {
    return null;
  }
}

// ---------- Fast model ----------

export type Turn = { question: string; answer: string };

export const HANDOFF = "@@T3";

const ANSWER_RULES = `You are Samin's quick assistant inside his Mac launcher. Be fast and concise: plain language, short answers, markdown only when it helps (lists, code).
A screenshot of the window he was looking at may be attached. Use it when the question refers to the screen ("this", "here", "what does this mean"). Don't describe the screenshot unless asked.`;

const HANDOFF_RULE = `If the request is real work on his computer, not a question you can answer from what you know or see (editing or creating files, running commands, writing or fixing code, building something, research across many sources, anything that would take an agent more than a minute), do not attempt it. Reply with exactly one line: ${HANDOFF} <short title for the task>`;

export async function ask(opts: {
  question: string;
  history: Turn[];
  screen: Screen | null;
  allowHandoff: boolean;
  signal: AbortSignal;
  onText: (text: string) => void;
}): Promise<string> {
  const { model, proxyUrl, apiKey } = prefs();
  const messages: { role: string; content: unknown }[] = [];
  // The screenshot rides on the first question of the conversation.
  opts.history.forEach((t, i) => {
    messages.push({ role: "user", content: userContent(t.question, i === 0 ? opts.screen : null) });
    messages.push({ role: "assistant", content: t.answer || "(no answer)" });
  });
  messages.push({ role: "user", content: userContent(opts.question, opts.history.length ? null : opts.screen) });

  const system = opts.allowHandoff ? `${ANSWER_RULES}\n${HANDOFF_RULE}` : `${ANSWER_RULES}\nAlways answer directly here.`;
  const res = await fetch(`${proxyUrl}/v1/messages`, {
    method: "POST",
    signal: opts.signal,
    headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({ model, max_tokens: 4096, thinking: { type: "disabled" }, stream: true, system, messages }),
  });
  if (!res.ok || !res.body) throw new Error(`CLIProxyAPI ${res.status}: ${(await res.text()).slice(0, 300)}`);

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    const lines = buf.split("\n");
    buf = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.startsWith("data:")) continue;
      let ev: { type?: string; delta?: { type?: string; text?: string }; error?: { message?: string } };
      try {
        ev = JSON.parse(line.slice(5));
      } catch {
        continue;
      }
      if (ev.type === "content_block_delta" && ev.delta?.type === "text_delta") {
        text += ev.delta.text ?? "";
        opts.onText(text);
      } else if (ev.type === "error") {
        throw new Error(ev.error?.message || "Model error");
      }
    }
  }
  return text;
}

function userContent(text: string, screen: Screen | null) {
  if (!screen) return text;
  try {
    const data = readFileSync(screen.path).toString("base64");
    const where = `[Screenshot of ${screen.app}${screen.title ? ` — ${screen.title}` : ""}]`;
    return [
      { type: "image", source: { type: "base64", media_type: "image/jpeg", data } },
      { type: "text", text: `${where}\n\n${text}` },
    ];
  } catch {
    return text;
  }
}

// ---------- T3 Code ----------

export function taskForT3(question: string, history: Turn[], screen: Screen | null) {
  const parts = [question.trim()];
  if (history.length) {
    const convo = history.map((t) => `Me: ${t.question}\nQuick model: ${t.answer}`).join("\n\n");
    parts.push(`Context, from a quick chat I had before this:\n\n${convo}`);
  }
  if (screen) parts.push(`Screenshot of the window I was looking at (${screen.app}${screen.title ? ` — ${screen.title}` : ""}): ${screen.path}`);
  return parts.join("\n\n");
}

export async function startT3Thread(message: string, opts: { project?: string; title?: string } = {}) {
  const project = opts.project || prefs().projects[0];
  const args = ["thread", "start", project, "-", "--json"];
  const title = (opts.title || message.split("\n")[0]).trim().slice(0, 80);
  if (title) args.push("--title", title);
  const out = await run(T3, args, { input: message, cwd: project, timeout: 60000 });
  const info = parseThread(out);
  await open(info.link || T3_APP);
  return info;
}

// The desktop app opens t3code://threads/<environmentId>/<threadId>.
function parseThread(out: string): { threadId?: string; link?: string } {
  let threadId: string | undefined;
  try {
    const json = JSON.parse(out);
    const t = json.thread || json;
    threadId = t.threadId || t.id;
  } catch {
    threadId = out.match(/(?:mcp:)?[0-9a-f]{8}-[0-9a-f-]{27}/)?.[0];
  }
  let env = "";
  try {
    env = readFileSync(join(homedir(), ".t3/userdata/environment-id"), "utf8").trim();
  } catch {
    // no link; the caller just opens the app
  }
  const link = threadId && env ? `t3code://threads/${env}/${encodeURIComponent(threadId)}` : undefined;
  return { threadId, link };
}
