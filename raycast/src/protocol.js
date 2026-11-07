"use strict";

const readline = require("readline");

let seq = 0;

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function log(...args) {
  console.error(...args);
}

function nextId() {
  seq += 1;
  return seq;
}

const pending = new Map();
let stopped = false;
let reader = null;
let onMessage = () => {};

function stop(reason = "Raycast host stopped") {
  stopped = true;
  for (const { reject, timer } of pending.values()) {
    clearTimeout(timer);
    reject(new Error(reason));
  }
  pending.clear();
}

function request(method, params, timeoutMs = 15000) {
  if (stopped) return Promise.reject(new Error("Raycast host stopped"));
  listen();
  const id = nextId();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error("Raycast request timed out: " + method));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    send({ type: "request", id, method, params: params || {} });
  });
}

function handleReply(msg) {
  const entry = pending.get(msg.id);
  if (!entry) return;
  pending.delete(msg.id);
  clearTimeout(entry.timer);
  if (msg.error) entry.reject(new Error(String(msg.error)));
  else entry.resolve(msg.result);
}

function listen(handler) {
  if (handler) onMessage = handler;
  if (reader) return reader;
  const rl = readline.createInterface({ input: process.stdin });
  reader = rl;
  rl.on("close", () => stop("Raycast input closed"));
  process.once("exit", () => stop());
  rl.on("line", (line) => {
    const text = String(line || "").trim();
    if (!text) return;
    let msg;
    try {
      msg = JSON.parse(text);
    } catch (err) {
      log("bad stdin json:", err.message);
      return;
    }
    if (msg && msg.type === "reply") {
      handleReply(msg);
      return;
    }
    try {
      const result = onMessage(msg);
      if (result && typeof result.then === "function") {
        result.catch((err) => {
          log("handler error:", err && err.stack ? err.stack : err);
          send({ type: "error", message: err && err.message ? err.message : String(err) });
        });
      }
    } catch (err) {
      log("handler error:", err && err.stack ? err.stack : err);
      send({ type: "error", message: err && err.message ? err.message : String(err) });
    }
  });
  return rl;
}

module.exports = { send, log, request, listen, stop };
