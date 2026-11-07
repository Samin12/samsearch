"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const esbuild = require("esbuild");

const root = path.join(__dirname, "..");
const host = path.join(root, "dist", "host.js");
const fixtureSrc = path.join(__dirname, "fixtures", "demo");
const fixture = path.join(__dirname, "fixtures", "demo-installed");

function bundleFixture() {
  fs.rmSync(fixture, { recursive: true, force: true });
  fs.mkdirSync(path.join(fixture, "commands"), { recursive: true });
  fs.copyFileSync(path.join(fixtureSrc, "package.json"), path.join(fixture, "package.json"));
  fs.mkdirSync(path.join(fixture, "assets"), { recursive: true });
  fs.writeFileSync(path.join(fixture, "assets", "icon.png"), "png");
  for (const name of ["view", "hud"]) {
    const entry = fs.existsSync(path.join(fixtureSrc, "src", name + ".tsx"))
      ? path.join(fixtureSrc, "src", name + ".tsx")
      : path.join(fixtureSrc, "src", name + ".ts");
    esbuild.buildSync({
      absWorkingDir: fixtureSrc,
      entryPoints: [entry],
      bundle: true,
      platform: "node",
      format: "cjs",
      outfile: path.join(fixture, "commands", name + ".js"),
      external: ["@raycast/api", "react", "react/jsx-runtime", "react/jsx-dev-runtime"],
      jsx: "automatic",
    });
  }
}

function startHost(args) {
  const child = spawn(process.execPath, [host, ...args], { stdio: ["pipe", "pipe", "pipe"] });
  const lines = [];
  let buf = "";
  let cursor = 0;
  child.stdout.on("data", (chunk) => {
    buf += chunk.toString();
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (line) lines.push(JSON.parse(line));
    }
  });
  const stderr = [];
  child.stderr.on("data", (c) => stderr.push(c.toString()));
  return {
    child,
    lines,
    stderr,
    send(msg) {
      child.stdin.write(JSON.stringify(msg) + "\n");
    },
    async waitFor(pred, timeout = 4000) {
      const start = Date.now();
      while (Date.now() - start < timeout) {
        for (let i = cursor; i < lines.length; i += 1) {
          if (pred(lines[i])) {
            cursor = i + 1;
            return lines[i];
          }
        }
        await new Promise((r) => setTimeout(r, 20));
      }
      throw new Error("timeout waiting for message. got " + JSON.stringify(lines) + " stderr " + stderr.join(""));
    },
  };
}

test("list and no-view fixtures speak the protocol", async () => {
  assert.ok(fs.existsSync(host), "dist/host.js missing; run npm test from raycast/");
  bundleFixture();
  const listed = startHost(["list", path.join(__dirname, "fixtures")]);
  const listMsg = await new Promise((resolve, reject) => {
    listed.child.on("close", (code) => {
      if (code !== 0) reject(new Error(listed.stderr.join("")));
      else resolve(listed.lines[0]);
    });
  });
  assert.ok(Array.isArray(listMsg));
  const demo = listMsg.find((e) => e.name === "demo");
  assert.ok(demo);
  assert.equal(demo.commands.length, 2);

  const hud = startHost(["run", fixture, "hud"]);
  const hudMsg = await hud.waitFor((m) => m.type === "hud");
  assert.equal(hudMsg.title, "Hello from HUD");
  const exitMsg = await hud.waitFor((m) => m.type === "exit");
  assert.equal(exitMsg.type, "exit");
  hud.child.kill();
  if (hud.child.exitCode == null && !hud.child.signalCode) await new Promise((resolve) => hud.child.on("close", resolve));
});

test("view command renders, filters, pushes, copies and opens", async () => {
  bundleFixture();
  const session = startHost(["run", fixture, "view"]);
  try {
  const first = await session.waitFor((m) => m.type === "render" && m.view && !m.view.loading);
  assert.equal(first.view.kind, "list");
  assert.equal(first.view.title, "Hello");
  const items = first.view.sections.flatMap((s) => s.items);
  assert.equal(items.length, 3);
  assert.equal(items[0].title, "Alpha Story");
  assert.equal(items[0].icon.text, "🔥");
  assert.ok(items[0].actions.length >= 2);

  session.send({ type: "search", text: "beta" });
  const filtered = await session.waitFor(
    (m) => m.type === "render" && m.view.sections.flatMap((s) => s.items).length === 1
  );
  assert.equal(filtered.view.sections[0].items[0].title, "Beta Notes");

  session.send({ type: "search", text: "" });
  const restored = await session.waitFor(
    (m) => m.type === "render" && m.view.sections.flatMap((s) => s.items).length === 3
  );
  const alpha = restored.view.sections.flatMap((s) => s.items).find((i) => i.id === "alpha");
  const push = alpha.actions.find((a) => a.title === "Open Detail");
  session.send({ type: "action", id: push.id });
  const detail = await session.waitFor((m) => m.type === "render" && m.view.kind === "detail");
  assert.match(detail.view.markdown, /Alpha Story/);

  session.send({ type: "pop" });
  const back = await session.waitFor((m) => m.type === "render" && m.view.kind === "list");
  assert.equal(back.view.kind, "list");

  const copy = alpha.actions.find((a) => a.title === "Copy Title");
  session.send({ type: "action", id: copy.id });
  const copied = await session.waitFor((m) => m.type === "copy");
  assert.equal(copied.text, "Alpha Story");

  const open = alpha.actions.find((a) => a.title === "Open Site");
  session.send({ type: "action", id: open.id });
  const opened = await session.waitFor((m) => m.type === "open");
  assert.equal(opened.target, "https://example.com/alpha");

  session.send({ type: "pop" });
  const root = await session.waitFor((m) => m.type === "pop_to_root");
  assert.equal(root.type, "pop_to_root");
  } finally {
    session.child.kill();
    await new Promise((resolve) => {
      if (session.child.exitCode != null || session.child.signalCode) resolve();
      else session.child.on("close", resolve);
    });
  }
});
