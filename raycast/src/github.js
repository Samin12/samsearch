"use strict";

// Extensions from github.com/raycast/extensions (MIT), without git, a clone
// of the (very large) repository, or a token. One API request lists an
// extension's files (the git tree of extensions/<name>, recursive); the
// files themselves come from raw.githubusercontent.com, which GitHub's API
// rate limit (60 requests an hour without a token) doesn't count. The
// store's list of every extension is one more request, kept for a day.
// GITHUB_TOKEN, when set, is sent with the API requests.

const https = require("https");
const fs = require("fs");
const path = require("path");

const REPO = "raycast/extensions";
const BRANCH = "main";
const UA = "nanolight-raycast-host";
const API = "https://api.github.com/repos/" + REPO;
const RAW = "https://raw.githubusercontent.com/" + REPO + "/";

function request(url, headers, redirects, signal) {
  const left = redirects == null ? 5 : redirects;
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers: Object.assign({ "User-Agent": UA }, headers || {}), signal }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        if (left <= 0) return reject(new Error("Too many redirects for " + url));
        return resolve(request(new URL(res.headers.location, url).toString(), headers, left - 1, signal));
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const body = Buffer.concat(chunks);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          let why = body.toString("utf8").slice(0, 300);
          if (res.statusCode === 403 && res.headers["x-ratelimit-remaining"] === "0") {
            const at = new Date(Number(res.headers["x-ratelimit-reset"] || 0) * 1000);
            why = "GitHub's hourly limit is used up until " + at.toLocaleTimeString() + " (set GITHUB_TOKEN to lift it)";
          }
          const err = new Error("GitHub " + res.statusCode + ": " + why);
          err.status = res.statusCode;
          return reject(err);
        }
        resolve({ status: res.statusCode, headers: res.headers, body });
      });
    });
    req.setTimeout(60000, () => req.destroy(new Error("GitHub timed out for " + url)));
    req.on("error", reject);
  });
}

function apiHeaders() {
  const h = { Accept: "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) h.Authorization = "Bearer " + process.env.GITHUB_TOKEN;
  return h;
}

async function getJson(url, signal) {
  const { body } = await request(url, apiHeaders(), undefined, signal);
  return JSON.parse(body.toString("utf8"));
}

function parseRef(input) {
  const raw = String(input || "").trim().replace(/^@/, "");
  if (!raw) throw new Error("Missing extension name");
  const parts = raw.split("/").filter(Boolean);
  if (parts[0] === "extensions") parts.shift();
  const name = parts[parts.length - 1];
  const owner = parts.length >= 2 ? parts[0] : null;
  if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error("Invalid extension name: " + name);
  return { owner, name };
}

/// The files of extensions/<name>: one API request.
async function listFiles(name, signal) {
  let data;
  try {
    data = await getJson(API + "/git/trees/" + BRANCH + ":extensions/" + encodeURIComponent(name) + "?recursive=1", signal);
  } catch (err) {
    if (err.status === 404) throw new Error("No extension called " + name + " in raycast/extensions");
    throw err;
  }
  if (data.truncated) throw new Error("The extension's file list came back cut short; not installing part of it");
  return { sha: data.sha, files: (data.tree || []).filter((e) => e.type === "blob") };
}

function skipped(p) {
  return p === "package-lock.json" || p === "metadata" || p.startsWith("metadata/") || p.startsWith("media/");
}

async function downloadExtension(name, destDir, signal) {
  const ref = parseRef(name);
  const { sha, files } = await listFiles(ref.name, signal);
  signal?.throwIfAborted();
  fs.mkdirSync(destDir, { recursive: true });
  const todo = files.filter((f) => !skipped(f.path));
  // Six at a time.
  let next = 0;
  async function worker() {
    while (next < todo.length) {
      const f = todo[next++];
      const url = RAW + BRANCH + "/extensions/" + encodeURIComponent(ref.name) + "/" + f.path.split("/").map(encodeURIComponent).join("/");
      const { body } = await request(url, undefined, undefined, signal);
      signal?.throwIfAborted();
      const dest = path.join(destDir, ...f.path.split("/"));
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, body);
    }
  }
  await Promise.all([worker(), worker(), worker(), worker(), worker(), worker()]);
  return { name: ref.name, treeSha: sha, owner: ref.owner };
}

/// Every extension's folder name, from one request, kept a day in `cacheDir`.
async function listAll(cacheDir) {
  const file = path.join(cacheDir, "store.json");
  try {
    const st = fs.statSync(file);
    if (Date.now() - st.mtimeMs < 24 * 3600 * 1000) return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {}
  let names;
  try {
    const data = await getJson(API + "/git/trees/" + BRANCH + ":extensions");
    names = (data.tree || []).filter((e) => e.type === "tree").map((e) => e.path);
  } catch (err) {
    // Offline or limited: what was kept, however old.
    if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, "utf8"));
    throw err;
  }
  fs.mkdirSync(cacheDir, { recursive: true });
  fs.writeFileSync(file, JSON.stringify(names));
  return names;
}

/// An extension's package.json from raw (no API request): its title,
/// description, author and icon name, for the store's rows.
async function manifest(name) {
  const { body } = await request(RAW + BRANCH + "/extensions/" + encodeURIComponent(name) + "/package.json");
  return JSON.parse(body.toString("utf8"));
}

function iconUrl(name, icon) {
  return RAW + BRANCH + "/extensions/" + encodeURIComponent(name) + "/assets/" + encodeURIComponent(icon);
}

module.exports = { parseRef, listFiles, downloadExtension, listAll, manifest, iconUrl, getJson, request };
