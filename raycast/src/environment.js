"use strict";

const fs = require("fs");
const path = require("path");

const state = {
  extensionDir: "",
  extensionName: "",
  commandName: "",
  assetsPath: "",
  supportPath: "",
  storageDir: "",
  appearance: "dark",
  launchType: "userInitiated",
  packageJson: null,
  command: null,
  preferences: {},
};

function loadPreferences(pkg, command, dir) {
  const prefs = {};
  const all = []
    .concat(Array.isArray(pkg.preferences) ? pkg.preferences : [])
    .concat(command && Array.isArray(command.preferences) ? command.preferences : []);
  for (const pref of all) {
    if (!pref || !pref.name) continue;
    if (pref.default !== undefined) prefs[pref.name] = pref.default;
    else if (pref.type === "checkbox") prefs[pref.name] = false;
    else prefs[pref.name] = "";
  }
  const file = path.join(dir, "preferences.json");
  if (fs.existsSync(file)) {
    try {
      const override = JSON.parse(fs.readFileSync(file, "utf8"));
      Object.assign(prefs, override);
    } catch (err) {
      console.error("preferences.json:", err.message);
    }
  }
  return prefs;
}

function init(extensionDir, commandName) {
  const pkgPath = path.join(extensionDir, "package.json");
  const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  const command = (pkg.commands || []).find((c) => c.name === commandName) || { name: commandName, mode: "view" };
  state.extensionDir = extensionDir;
  state.extensionName = pkg.name || path.basename(extensionDir);
  state.commandName = commandName;
  state.assetsPath = path.join(extensionDir, "assets");
  // Mutable data is a sibling of installed bundles and survives replacement.
  state.storageDir = path.join(path.dirname(extensionDir), ".data", path.basename(extensionDir));
  fs.mkdirSync(state.storageDir, { recursive: true });
  for (const name of ["local-storage.json", "preferences.json", "support"]) {
    const old = path.join(extensionDir, name);
    const dest = path.join(state.storageDir, name);
    if (fs.existsSync(old) && !fs.existsSync(dest)) fs.cpSync(old, dest, { recursive: true });
  }
  state.supportPath = path.join(state.storageDir, "support");
  state.packageJson = pkg;
  state.command = command;
  state.preferences = loadPreferences(pkg, command, state.storageDir);
  fs.mkdirSync(state.supportPath, { recursive: true });
  return { pkg, command };
}

function environment() {
  return {
    extensionName: state.extensionName,
    commandName: state.commandName,
    commandMode: (state.command && state.command.mode) || "view",
    assetsPath: state.assetsPath,
    supportPath: state.supportPath,
    isDevelopment: false,
    raycastVersion: "1.80.0",
    appearance: state.appearance,
    textSize: "medium",
    launchType: state.launchType,
    canAccess: () => false,
    theme: state.appearance,
    subscribe(callback) {
      if (typeof callback !== "function") return () => {};
      return () => {};
    },
  };
}

function getPreferenceValues() {
  return { ...state.preferences };
}

function setAppearance(value) {
  if (value) state.appearance = value;
}

module.exports = { state, init, environment, getPreferenceValues, setAppearance, loadPreferences };
