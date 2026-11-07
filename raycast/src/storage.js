"use strict";

const fs = require("fs");
const path = require("path");
const { state } = require("./environment");

function atomicWrite(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + ".tmp-" + process.pid + "-" + require("crypto").randomUUID();
  try {
    fs.writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 });
    fs.renameSync(tmp, file);
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

function storagePath() {
  return path.join(state.storageDir || state.extensionDir, "local-storage.json");
}

function readAll() {
  try {
    return JSON.parse(fs.readFileSync(storagePath(), "utf8"));
  } catch {
    return {};
  }
}

function writeAll(data) {
  atomicWrite(storagePath(), data);
}

const LocalStorage = {
  async getItem(key) {
    const data = readAll();
    return Object.prototype.hasOwnProperty.call(data, key) ? data[key] : undefined;
  },
  async setItem(key, value) {
    const data = readAll();
    data[key] = value;
    writeAll(data);
  },
  async removeItem(key) {
    const data = readAll();
    delete data[key];
    writeAll(data);
  },
  async allItems() {
    return readAll();
  },
  async clear() {
    writeAll({});
  },
};

class Cache {
  constructor(options) {
    this.namespace = options && options.namespace ? String(options.namespace) : "default";
    this.capacity = options && options.capacity ? options.capacity : 0;
    this.listeners = new Set();
  }

  subscribe = (listener) => {
    if (!this.listeners) this.listeners = new Set();
    if (typeof listener !== "function") return () => {};
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  notify() {
    if (!this.listeners) return;
    for (const listener of this.listeners) {
      try {
        listener();
      } catch (err) {
        console.error(err);
      }
    }
  }

  file() {
    const safe = this.namespace.replace(/[^a-zA-Z0-9._-]/g, "_");
    return path.join(state.supportPath || state.extensionDir, "cache-" + safe + ".json");
  }

  read() {
    try {
      return JSON.parse(fs.readFileSync(this.file(), "utf8"));
    } catch {
      return {};
    }
  }

  write(data) {
    atomicWrite(this.file(), data);
  }

  get(key) {
    const data = this.read();
    return Object.prototype.hasOwnProperty.call(data, key) ? data[key] : undefined;
  }

  set(key, value) {
    const data = this.read();
    data[key] = String(value);
    this.write(data);
    this.notify();
  }

  has(key) {
    return this.get(key) !== undefined;
  }

  remove(key) {
    const data = this.read();
    delete data[key];
    this.write(data);
    this.notify();
  }

  clear() {
    this.write({});
    this.notify();
  }

  get isEmpty() {
    return Object.keys(this.read()).length === 0;
  }
}

module.exports = { LocalStorage, Cache, atomicWrite };
