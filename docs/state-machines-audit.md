# SamSearch: implicit state machines

Audit of `~/Developer/samsearch` at `08f30da` (Nov 7, 2026). Read-only: four parallel reviewers each took one area, and the top findings were spot-checked in source. Paths are relative to the repo root; `src/` is the Zig app, `quickask/` the Swift helper, `raycast/` the Node host for Raycast extensions.

An "implicit state machine" here is a lifecycle whose states and transitions aren't modeled in one place: several flags that together mean one mode, a status written from many places, re-entry guards, timers or callbacks that chain, or one fact kept in memory, on disk and in another process with no single owner.

About 60 machines turned up. They cluster into seven root patterns; fixing the pattern fixes most of the machines under it.

## The seven root patterns

1. **Borrowed memory freed mid-frame.** nanoui draws text, images and views from pointers after the view function returns. Synchronous callbacks (script commands, a failed write to the Node host, an app-index rescan) free the Ext view arena or an icon while the frame still uses it. Same class as the crashes fixed in `1cbc7c7` and `08f30da`, still present in three more places.
2. **The Quick Ask helper is a second process with no lifecycle.** SamSearch starts it once with `open -g` and never checks it again: no health check, no version check, no restart, no stop. Release builds don't even contain it. Pages in the panel can't tell "helper down" from "slow" and spin forever.
3. **Panel mode spread over flags.** What the panel shows (`onboard.active`, `settings_ui.open`, `ext.open`, `previewing`) and whether it's showing (AppKit `isVisible`/`isKeyWindow`) are read in four places with separate priority rules, and cleanup lives only in the resign-key callback. Any show or hide that skips `toggle` or that callback skips cleanup.
4. **Async work is never cancelled, only checked on arrival.** Google suggestions, sign-in polling, sync, Ask turns, Codes fetches, Node requests: each has a `waiting` counter or a text compare instead of a generation id. Stale results land on newer state (sign-in flow killed, suggestion cache poisoned, selection jumps).
5. **Saved before it works.** A new hot key is saved and synced before registration succeeds, and every platform unregisters the old key first. Failure only logs.
6. **Every ending is one hard path.** A Raycast command ends by SIGTERM plus a blocking `wait4` whether it exited, popped to root, crashed or failed a write. There's no "closing" state, so toasts, HUDs and errors are wiped before they show.
7. **Failures collapse into a log line.** Hot key registration, helper port bind, open-at-login "requires approval", page loads, render errors, permissions (Screen Recording, Automation, Full Disk Access) — none is a state the UI can show.

## Confirmed bugs (spot-checked in source)

| # | Sev | Bug | Evidence |
|---|---|---|---|
| B1 | H | ⌘Q while the panel is open quits SamSearch (what happened on Nov 7 at 10:55). | nanoui `menu.zig:273` gives the `.quit` role ⌘Q; `src/main.zig:312`; log: `terminate:` 1 s after the panel became key, `exit(0)` |
| B2 | H | Script command screen reads freed memory. Return on an argument form or "Run X?", ⌘↩ Run Again, Esc while running, or picking a dropdown option frees the view arena while `panel()` is still drawing it. | `src/raycast_view.zig:179-195` copies `v`/`acts`, `keys()` → `src/script_run.zig:184-211 said()` → `ext.stop()`/`ext.show` frees the arena (`raycast_view.zig:81,108`) |
| B3 | H | Same use-after-free when a write to a dead Node host fails mid-frame (`catch r.stop()`). | `src/raycast.zig:237`; `src/raycast_view.zig:179-195,305-317,436-452` |
| B4 | H | Dangling command icon: a running command borrows an app icon that `rc.refresh` frees on every panel show. | `src/raycast_live.zig:57-59,125`; `src/raycast_view.zig:70,496` |
| B5 | H | Release builds have no Quick Ask helper, and a local `install.sh` build reports 0.1.0, so auto-update swaps in a helper-less app; the old helper keeps serving old code until reboot, then Ask/DigUp/Codes stop. | `macos/package.sh` (no quickask step); `.github/workflows/release.yml:76`; `macos/install.sh:12`; `src/helper_mac.zig:15` |
| B6 | H | Model output is rendered as raw HTML (`marked.parse` → `innerHTML`). Injected HTML from a web page, OCR or email runs on 127.0.0.1:47213 and can call `/api/open`, `/api/t3`, `/api/open-url`. | `quickask/ask.html:77,131`; `quickask/main.swift:676,708-734` |
| B7 | M | Recording a shortcut, then "Show Welcome Again", leaves the key recorder on: every key is eaten and the global hot key stays off. | `src/settings_view.zig:54-57,375-377`; `src/recorder.zig:43-54`; `src/main.zig:399-415` |
| B8 | M | A failed hot key change leaves no hot key while Settings and sync claim the new one. | `src/hotkey_mac.zig:45-47`; `src/hotkey_win.zig:41-43`; `src/hotkey_x11.zig:168-184`; `src/main.zig:391-395,417-422` |
| B9 | M | Pages in the panel (Ask, DigUp, Codes) have no failure state: "Asking…" forever when the helper is down. Hiding the panel never tears the page down. | `src/preview.zig:84-100`; `src/view.zig:210-220,728-732`; `src/main.zig:336-357` |
| B10 | M | Opening SamSearch.app while it runs does nothing (no reopen handler). With the menu bar icon hidden and the hot key broken, nothing brings the panel back. | `src/main.zig:278-281,539`; nanoui `app.zig:322-328` |
| B11 | M | Cancel sign-in and sign in again: two poll chains run; a stale result can kill the new flow. A late 401 from a push signs you out without a state check. | `src/account.zig:115-173,266-269` |
| B12 | M | DigUp answers poison the Google suggestion cache: a query can permanently show no completions. | `src/view.zig:358-364,404`; `src/suggest.zig:161-176` |
| B13 | M | Ask can't be cancelled: leaving the page keeps Haiku, tools and `startT3()` running. "Open Answer Window" re-asks from scratch and can start a second T3 thread. A question typed while busy is lost. | `quickask/main.swift:765-806,868,899-900`; `quickask/ask.html:97-99,189-192,208` |
| B14 | M | Raycast render error freezes the screen with every action dead (`onUncaughtError` is a no-op, `reportRenderError` never called). | `raycast/src/reconciler.js:331-337,356,371` |
| B15 | M | Push unmounts the parent view and pop remounts it from scratch; search text, selection, form and dropdown state are module globals shared across views. | `raycast/src/navigation.js`; `raycast/src/reconciler.js:29-31,353-369,467-501` |
| B16 | M | No-view commands: requests never resolve (stdin never read), Escape is dead, toasts/HUDs/errors are wiped on exit, load errors flash and vanish. | `raycast/src/host.js:71-78,96-105`; `raycast/src/protocol.js:22-28`; `src/raycast.zig:297-298`; `src/raycast_view.zig:85` |
| B17 | M | Reinstalling or updating an extension wipes its LocalStorage, Cache and preferences; LocalStorage turns numbers and booleans into strings. | `raycast/src/install.js:146-147`; `raycast/src/storage.js:8,31,74` |
| B18 | M | Data-dir migration failure is fatal on every launch. | `src/main.zig:537`; `src/data_dir.zig:56-68` |
| B19 | M | Menu bar "Settings…" ends the welcome without marking it done; it comes back next launch. Esc on welcome step 1 ("Skip") applies whatever key the arrows were on. | `src/main.zig:471`; `src/onboard.zig:106,121-122,334-337` |
| B20 | M | After an auto-update restart the panel can come back shown but not key and with click-through off, so it blocks clicks and never auto-hides. | nanoui `update_auto.zig:229-247`; `src/main.zig:382,621,633-637` |
| B21 | L | `--toggle` on macOS relaunches instead of toggling (`single_mac.send` always returns false). | `src/single_mac.zig:50-52`; `src/main.zig:528-531,586` |
| B22 | L | Open at login reads "requires approval" as off. | `src/login.zig:24-25`; `src/onboard.zig:300` |
| B23 | L | Failed file drag leaves `swallowing` set; the next mouse-up is eaten. Drag maps last frame's row ids onto the current results. | `src/drag_mac.zig:35-36,163,196-201` |
| B24 | L | "Add ⌘, ⌥ or ⌃" label sticks after an interrupted recording (`refused` never reset). Settings selection is an index that shifts when the account state changes. | `src/settings_view.zig:49-57,83-84,150,384-389` |
| B25 | L | Full Disk Access advice names SamSearch, but `chat.db` is read by the Quick Ask process; SQLITE_CANTOPEN denials get no hint. | `quickask/codes.swift:156-163` |
| B26 | L | Calculator "Copied" chip isn't tied to the expression; in-flight Google answers still show after suggestions are turned off; launch counts of apps missing from the index are erased from kv. | `src/view.zig:539`; `src/main.zig:494-503`; `src/apps.zig:273-278` |
| B27 | L | Toast changes after `show()` never reach the screen; a HUD shown while hidden appears hours later; `popToRoot` kills the command mid-output. | `raycast/src/toast.js:21-29`; `src/raycast_view.zig:121-127,497`; `src/raycast.zig:285-298` |
| B28 | L | Helper leaks: screenshots and `screens[id]` entries never cleaned up; the `chrome_tabs` tool can launch Chrome; `install.sh` registers the throwaway zig-out helper with LaunchServices. | `quickask/main.swift:110,206-218,356-366`; `macos/install.sh:15`; `quickask/build.sh:18-20` |

## Ranked list

Severity: H high, M medium, L low. "Explicit?" = worth turning into one modeled state machine.

### Panel and app lifecycle (`src/main.zig`, `panel_*`, `single*`, `hotkey*`, `onboard`, `drag_mac`, `preview`)

| Sev | Machine | Where | Key problems | Explicit? |
|---|---|---|---|---|
| H | Panel visibility/focus: hidden → placed → fading → shown+key → resign → hidden (also shown-not-key, app-hidden) | `src/main.zig:336-385,458-485`; `src/panel_mac.zig:36-91`; `src/drag_mac.zig:214-226`; `src/raycast_live.zig:95-98` | Six hide paths with different cleanup; auto-update restore bypasses `toggle`; `drag.active` silently drops the hot key; `menuShow`/`menuSettings` disagree on "already showing"; ⌘Q/⌘H act on the app | Yes |
| M | Panel content mode: rows / page / settings / ext / onboarding | `src/view.zig:134-150,189-205,243-254,722-732`; `src/main.zig:471` | Priority written in four places; `reveal()` resets some modes, not others; outside code writes `o.active` | Yes, one enum |
| M | Page in panel: none → loading → shown → failed → emptied | `src/view.zig:122-129,698-732`; `src/preview.zig:26-126`; `src/main.zig:245-262` | B9; `previewing` duplicated in the web view's hidden state | Yes |
| M | Hot key registration: none → registered → paused (recording) → registered | `src/hotkey_*.zig`; `src/main.zig:158-165,391-422,588` | B8; sync can re-register mid-recording | Yes |
| M | Onboarding: inactive → key → try_it → done → finished | `src/onboard.zig:49-118,325-342`; `src/main.zig:373-376,458-462,471,595` | B19; step 2 waits forever if the key never registers | Partly |
| M | Update / auto-restart: off → checking → ready → waiting-away → restart → restored | `src/main.zig:320-331,608-637`; `src/update_pc.zig`; nanoui `update_auto.zig` | B20; manual vs auto restart differ | Yes |
| M | Single instance: claim → others terminated → listening | `src/single*.zig`; `src/main.zig:528-531,586` | B10, B21; dev and installed builds kill each other | Partly |
| L | Native drag: idle → candidate → window-move / file-drag → ended | `src/drag_mac.zig:52-226` | B23 | Small enum |
| L | Click-through, `keep_open`, launch mode, open at login, panel position | `src/clickthrough.zig`; `src/main.zig:93-94,349-357,627-637`; `src/login.zig` | `keep_open` can stick; B22; login launch takes focus | No |

### Search and results (`src/view.zig`, `results.zig`, `suggest.zig`, `files*`, `digup*`, `apps*`)

| Sev | Machine | Where | Key problems | Explicit? |
|---|---|---|---|---|
| M | Query → results pipeline: typed → rebuilt → partial answers land → settled | `src/view.zig:332-414`; `src/files_view.zig:19-80`; `src/results.zig:136-207` | Rows point into other lists by index; `rebuild` runs twice per frame; every open asks each source twice; `answered()` does two jobs (B12) | Yes: one generation per query, per-source status, stable row keys |
| M | Google suggestions: idle → debounce → in-flight → answered/failed | `src/main.zig:212-243,489-504`; `src/suggest.zig:125-178` | Never cancelled; failures not cached or retried; cache never expires; B12, B26 | Yes, small |
| M | File search worker: debounce → busy → answered/dropped | `src/files_live.zig:10-94` | One worker waits up to ~2 s for the previous mdfind; stale rows stay up on failure | Share one debounced-worker type with DigUp |
| M | DigUp inline hits (via the helper) | `src/digup_live.zig:18-107` | No retry after the 1.5 s timeout; cold-start misses stick until the query changes | Yes, with helper status |
| M | App index lifecycle: scanned → loaded → refresh → kept/swapped | `src/apps.zig:65-313`; `src/raycast_live.zig:105-151` | Full rescan on the main thread every open; swap frees borrowed icons (B4); parallel arrays | Partly |
| L | Learned picks, selection across refills, calculator row | `src/apps.zig:224-270`; `src/view.zig:364-413,539`; `src/results.zig:118-122` | No cap on picks; ⌘4–⌘9 numbers shift as completions land | No |

### Raycast extensions (`src/raycast*.zig`, `src/script_run.zig`, `raycast/src`)

| Sev | Machine | Where | Key problems | Explicit? |
|---|---|---|---|---|
| H | Host process: spawning → starting → running → {exit, pop_to_root, EOF, write failed, replaced} → killed | `src/raycast.zig:181-257`; `raycast/src/host.js:80-148` | One `stop()` for every ending; SIGTERM + blocking `wait4` on the UI thread; B3, B16; no crash handlers | Yes, with a closing state |
| H | View ownership / render generation | `src/raycast_view.zig:78-118,175-196` | B2, B3; push, pop and refresh look the same to Zig | Yes: view generation, never free during a frame |
| H | Script command run: idle → form/confirm → running → done/failed → popped | `src/script_run.zig:64-271`; `src/raycast_view.zig:176-237` | B2; `ended()` blocks on `wait`; arena grows each Run Again | Yes |
| H | Navigation stack | `raycast/src/navigation.js`; `raycast/src/reconciler.js:353-369` | B15 | Yes: one stack of mounted roots |
| H | Render error | `raycast/src/reconciler.js:331-371` | B14 | Yes |
| M | Request/reply | `raycast/src/protocol.js:20-36`; `src/raycast.zig:304-323` | Not listened to in no-view commands; no timeout; not rejected on stop; 64 KB reply cap; `confirm` always yes | Yes |
| M | Form state | `raycast/src/reconciler.js:203-242,414-455`; `src/raycast_view.zig:395-472` | Untouched defaults left out of submit; controlled values ignored after typing | Yes |
| M | Search and selection sync | `src/raycast_view.zig:204-264,300-311`; `raycast/src/reconciler.js:269-297,382-412` | Controlled `searchText` ignored; highlight jumps back after typing | Yes |
| M | Action registry | `raycast/src/reconciler.js:33-90,111-116,435-455` | Positional ids shift while streaming, so ⌘↩ is dropped; a React root leaks per item per render | Yes: stable ids |
| M | Toast/HUD | `raycast/src/toast.js`; `src/raycast_view.zig:121-127,497-501` | B27 | Yes |
| M | Install/update/remove, LocalStorage/Cache | `raycast/src/install.js:90-157`; `raycast/src/storage.js` | B17; non-atomic writes; Escape mid-install leaves temp folders and npm children | Yes |
| M | Dropdown init | `raycast/src/reconciler.js:467-501`; `raycast/src/host.js:129-132` | Fires once per process, never after a remount | Yes |
| L | Icon caches, startup caches, shared `Ext` | `src/raycast_view.zig:345-352`; `src/raycast.zig:149-165` | Failed reads cached forever; half-written cache files trusted | No |

### Settings, account and the Quick Ask helper (`src/settings*`, `src/account*`, `quickask/`, `macos/`)

| Sev | Machine | Where | Key problems | Explicit? |
|---|---|---|---|---|
| H | Helper process: absent → launching → listening / bind-failed → crashed / orphaned / stale | `src/helper_mac.zig:12-23`; `src/main.zig:598`; `quickask/main.swift:595-610,907-911`; `macos/package.sh` | B5; launched once, never supervised; a bind failure keeps a dead process alive; survives SamSearch quitting | Yes: `/health` + version handshake, restart, stop with SamSearch |
| H | Ask turn: idle → capturing → streaming / tool → done / handoff / error / cancelled | `quickask/main.swift:200-228,376-467,765-806`; `quickask/ask.html:97-156` | B6, B13; no terminal line → "Thinking…" forever; capture has no timeout | Yes: turn id, cancel on disconnect, always a terminal state |
| H | Answer surface: panel page ↔ floating panel | `quickask/main.swift:816-902`; `src/view.zig:704-716` | B13; history only in each page's JS | Yes |
| M | Account sign-in: signed_out → starting → waiting → signed_in | `src/account.zig:39,87-185` | B11; `starting` can't be cancelled | Yes: flow epoch |
| M | Sync: idle → pulling → applying → pushing | `src/account.zig:190-269`; `src/main.zig:146-193` | Stale pull applied after re-sign-in; `applySynced` re-registers the hot key while recording | Partly |
| M | Shortcut recording: idle → recording → refused → key/cancel | `src/settings_view.zig:33-57,156-182`; `src/main.zig:337-341,400-414`; `src/recorder.zig` | B7, B24; two owners clear different flags | Yes, one owner |
| M | Codes fetch: idle → in-flight → cached; page polling | `quickask/codes.swift:84-103,197-233`; `quickask/codes.html:49-113` | No overall timeout, so one hung Composio call blocks every later request; B25 | Partly |
| M | DigUp service in the helper | `quickask/main.swift:511-590` | Write can race termination (SIGPIPE); cold start can pass the 20 s timeout | Optional |
| M | Data-dir migration | `src/data_dir.zig:24-69` | B18 | Make non-fatal |
| M | Permissions (Screen Recording, Automation, Full Disk Access) | `quickask/main.swift:108-160`; `quickask/codes.swift:156-163` | Denied, undetermined and blocked prompt all look like "no text" or a hang | Yes: enum at `/api/status` |
| L | Settings selection, install script, knowledge cache | `src/settings_view.zig:83-84,384-389`; `macos/install.sh:19-25`; `quickask/main.swift:257-283` | B24; install waits a fixed 1 s then deletes the bundle; failed knowledge fetch not retried for 30 min | No |
