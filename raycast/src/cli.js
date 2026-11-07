"use strict";

const { send, log } = require("./protocol");
const { installExtension, listExtensions, removeExtension } = require("./install");
const { runCommand, runStore } = require("./host");

async function main(argv) {
  const [cmd, a, b] = argv;
  if (cmd === "install") {
    if (!a || !b) throw new Error("Usage: host.js install <name-or-owner/name> <extensions-dir>");
    const result = await installExtension(a, b);
    process.stdout.write(JSON.stringify(result) + "\n");
    return;
  }
  if (cmd === "list") {
    if (!a) throw new Error("Usage: host.js list <extensions-dir>");
    process.stdout.write(JSON.stringify(listExtensions(a)) + "\n");
    return;
  }
  if (cmd === "remove") {
    if (!a || !b) throw new Error("Usage: host.js remove <name> <extensions-dir>");
    process.stdout.write(JSON.stringify(removeExtension(a, b)) + "\n");
    return;
  }
  if (cmd === "run") {
    if (!a || !b) throw new Error("Usage: host.js run <extension-dir> <command-name>");
    await runCommand(a, b);
    return;
  }
  if (cmd === "store") {
    if (!a) throw new Error("Usage: host.js store <extensions-dir>");
    runStore(a);
    return;
  }
  throw new Error("Unknown command. Use install, list, run, store, or remove.");
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((err) => {
    const message = err && err.message ? err.message : String(err);
    log(err && err.stack ? err.stack : message);
    if (process.argv[2] === "run" || process.argv[2] === "store") send({ type: "error", message });
    else process.stdout.write(JSON.stringify({ ok: false, error: message }) + "\n");
    // Let the protocol error reach Zig before the pipe closes.
    process.stdout.write("", () => process.exit(1));
  });
}

module.exports = { main };
