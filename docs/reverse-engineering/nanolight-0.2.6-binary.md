# Nanolight 0.2.6: how the root rows work (REA + Eleven's Rizin, 2026-11-03)

Binary: `backup/Nanolight-0.2.6.app/Contents/MacOS/nanolight` (arm64 Mach-O, Zig + nanoui, closed source).
Hopper through `rea analyze` hung; Eleven's bundled Rizin (`/Applications/Eleven.app/Contents/Resources/rizin/bin/rizin`, `aaa`) took 16 seconds.

## Picking a row: `fcn.1000b9f24`
Called from the row builder `fcn.1000b1e90` (which also references "Ask Grok" and "Search X for").
It reads the selected row's kind byte (`[row+0x2c]`) and branches:
- kind 2 = Ask Grok, kind 3 = Search X: `fcn.10006b8c0(buf, prefix, len)` opens prefix + the typed query.
  The prefix is `csel` between `https://grok.com/?q=` (len 0x14) and `https://x.com/search?f=live&q=` (len 0x1e).
- kind 0: `fcn.1000c4834(query)` (calculator-style result), then a callback.
- kind 1: an item from the results list at `[state+0x280]`, launched through `fcn.10008a07c`.
- kind 5 and kind 7+ (suggestions): `fcn.1000c4374`, which sets the query text and refreshes.

## Launching an item: `fcn.10008d80c`
It takes an item id string and branches on its prefix: `http:`/`https:`, `raycast_store:`, `script_folder:`, `script:`,
`x-apple.systempreferences:`, `raycast:` (extension command). Raycast commands start Node with
`~/Library/Caches/Nanolight/raycast-host-*.js run <ext-dir> <command>` (`fcn.10009b888` builds the `raycast:` id).
The host protocol has no starting-text or arguments field: only `search`, `action`, `select`, `field`, `checkbox`, `pop`, `reply` messages on stdin.

## What that means
- The Grok and X rows have no inline answer; they just open a URL. Pointing them at `quickask://` (the current patch)
  does exactly what Nanolight does.
- Opening Quick Ask *inside* Nanolight with your query needs a code patch: make kinds 2/3 call the launcher
  (`fcn.10008d80c`) with a fixed `raycast:…/samin-quick-ask#ask` id, and get the query to the extension
  another way (e.g. the helper writes it to a file the extension reads on launch). Possible, but it's assembly
  edits that break on every Nanolight update.

## Side effect found while testing
Restarting Nanolight let ClickUp's desktop app take Ctrl+Space (ClickUp re-registers the shortcut when it's free).
