<p align="center"><img src="src/icon-256.png" alt="SamSearch's icon" width="96" height="96"></p>

<h1 align="center">SamSearch</h1>
<p align="center"><b>A launcher for the Mac, Windows and Linux, drawn by <a href="https://github.com/justrach/nanoui">nanoui</a>.</b><br>
Apps, math, Google, Quick Ask, T3, DigUp and Raycast extensions: one keystroke away. Native Zig, no Electron, about 2 MB.</p>

<p align="center"><a href="https://github.com/justrach/nanolight/raw/refs/heads/main/docs/promo.mp4"><img src="docs/promo-preview.gif" alt="Introducing SamSearch 2.0, now on Mac, Windows and Linux, in 40 seconds: a MacBook Air and a Dell XPS 13 side by side, then Settings, a Raycast extension and a script command on a MacBook Air, then Windows and Linux on a Dell XPS 13" width="760"></a><br><sub><a href="https://github.com/justrach/nanolight/raw/refs/heads/main/docs/promo.mp4"><b>Watch it with sound →</b></a> · <a href="docs/promo.md">How it was made</a></sub></p>

<p align="center"><img src="docs/images/nanolight.jpg" alt="SamSearch's panel has found Safari from &quot;saf&quot;" width="760"></p>

## What it does

- **Finds apps as you type**: whole names, starts of words, initials (`ss` is System Settings), letters in order, and typos (`chorme` is Chrome). What you open often climbs.
- **System Settings panes** (Mac): "login items", "wifi" or "dark mode" lists the pane, under the apps, and Return opens System Settings right at it.
- **Completes inline**: the rest of the top app's name, or of Google's top suggestion, is drawn faintly after the caret. Tab or → takes it; Return never does.
- **Does math**: `2^10 * 3` answers 3,072 (and `0xC00`). Return copies it.
- **Google suggestions**: up to four, under the apps, the words you add in bold. Nothing that reads as an address (a dot, a slash, an @) is sent.
- **Results in the panel**: Return on a search shows Google's page in the panel itself. Esc goes back to the list, ⌘↩ opens it in your browser, ⌘[ goes back a page. Prefer the browser? Turn on **Open Searches in Browser** in Settings: Return opens your browser, and ⌘↩ shows the page in the panel.
- **Ask & Search**: Quick Ask (Haiku with screen context), a new T3 Code thread with default settings, or DigUp for files, screenshots, email and Drive. Quick Ask and DigUp show local helper pages in the panel at `http://127.0.0.1:47213`; ⌘↩ on Quick Ask opens its floating answer window. T3 opens through `quickask://t3-thread-create`. The helper must be running and registered for `quickask://` links.
- **Raycast extensions**: extensions from the [Raycast Store's repository](https://github.com/raycast/extensions) (MIT) run in the panel: their lists, details and forms, their actions on ⌘K. Choose **Install Raycast Extension…** to search the store. They are React and TypeScript, so they need [Node.js](https://nodejs.org) 20 or later on your computer; SamSearch brings none, and runs them through its own version of `@raycast/api` ([raycast/README.md](raycast/README.md)). AI, OAuth and the menu bar aren't supported.
- **Raycast script commands** ([raycast/script-commands](https://github.com/raycast/script-commands), MIT): any script with `@raycast.*` comments, dropped in the Script Commands folder, is a row. SamSearch runs it itself, no Node needed: its arguments as a form, its output as it prints (`fullOutput`), its last line (`compact`), or nothing (`silent`).
- **Settings in the panel**: ⌘, (Ctrl+, on a PC), the gear in the footer, or type "settings".
- **⌘1–⌘9** run a row at once; ↑ ↓ and ⌃N ⌃P move.
- On the Mac it lives in the menu bar: no Dock icon, and nothing drawn while it's idle. **Show in Menu Bar** in Settings hides the icon; Settings stays a ⌘, away in the panel.

## Sync across computers (optional)

Off until you turn it on: choose **Sign In with Codegraff** in Settings (or the menu bar icon's menu on the Mac). Your browser opens codegraff.com to approve the sign-in, and from then on every computer signed in to the same account shares:

- the key that opens SamSearch,
- whether Google suggestions are on,
- how often you open each app, so an empty panel suggests the same apps everywhere.

Two Macs merge rather than overwrite: the key and the suggestions setting follow whichever Mac changed them last, and each app keeps its higher count. Nothing else is sent: no queries, no history, no files. The sign-in key is kept in your Keychain, and **Sign Out of Codegraff** revokes it.

Syncing goes through your Codegraff account, so [Codegraff's terms](https://codegraff.com/terms) and [privacy policy](https://codegraff.com/privacy) apply to it. New accounts made by signing in from SamSearch get $2 of Codegraff credit.

## Install

Build locally with `zig build app`. The bundle is `zig-out/SamSearch.app`; copy it to Applications when ready. Building does not launch it.

On first run a short welcome picks the key that opens it and says who else holds it. On the Mac that's ⌘Space, ⌥Space, ⌃Space or ⌥⌘Space (any other, such as ⌥X, can be recorded later in Settings; Spotlight gives up ⌘Space in System Settings → Keyboard → Keyboard Shortcuts → Spotlight); on a PC, Alt Space, Ctrl Alt Space, Ctrl Space or Ctrl Shift Space. Updates use only `Samin12/samsearch` releases and the separate SamSearch cache. Missing releases or failed checks leave the installed app in place; updates are disabled if `NANOUI_UPDATE_FEED` is set.

## Build

You need Zig 0.17.1 and Xcode or the Command Line Tools.

```sh
zig build test      # search, math, suggestions and the panel, through nanoui's Tester
zig build run       # build and open it
zig build app       # zig-out/SamSearch.app, for /Applications
VERSION=0.1.0 sh macos/package.sh   # the Mac release: signed app, disk image, update zip, manifest.json
VERSION=0.1.0 sh pc/package.sh      # Windows' zip and Linux's tarballs, added to manifest.json
zig build -Dtarget=x86_64-windows-gnu   # any target from any machine
cd raycast && npm test              # the Raycast extensions' host
```

`macos/package.sh` signs with `$CODESIGN_IDENTITY` and notarizes when notary credentials are set (see the script); otherwise it signs ad hoc. Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds, signs and attaches the release.

SamSearch keeps its data in `~/Library/Application Support/SamSearch` on macOS. On first run, if that folder is absent, it copies `extensions/` and `script-commands/` from Nanolight's data folder, preserving the originals. Preferences and the Keychain service belong to SamSearch.

## How it's made

| File | What |
| --- | --- |
| `src/main.zig` | The app: the window, the hot key, the menu bar icon, updates |
| `src/view.zig` | The panel: query, rows, footer, keys |
| `src/results.zig` | What a query lists, in order |
| `src/search.zig` | Fuzzy matching and ranking, allocation-free |
| `src/calc.zig` | The calculator |
| `src/suggest.zig` | Google's completions: the privacy guard, decoding, the cache (after [browse](https://github.com/justrach/browse)) |
| `src/preview.zig` | The results page in the panel (WKWebView, the Mac) |
| `src/panel_mac.zig`, `src/panel_pc.zig` | The panel's window on the Mac, and on Windows and Linux |
| `src/hotkey*.zig`, `src/apps_*.zig`, `src/single*.zig`, `src/login.zig`, `src/keychain*.zig` | Each platform's key, apps, single copy, login item and secret |
| `src/raycast*.zig`, `raycast/` | Raycast extensions: the panel's screen, the Node host and its `@raycast/api` |
| `src/script_commands.zig`, `src/script_run.zig` | Raycast script commands, run in Zig |
| `src/onboard.zig`, `src/shortcut.zig`, `src/recorder.zig` | The welcome, which key is free, recording one's own |
| `src/film.zig`, `src/stage.zig`, `tools/film.sh` | The walkthrough, rendered offscreen |
| `src/promo.zig`, `src/promo_scene.zig`, `src/promo_camera.zig`, `tools/promo.sh`, `tools/promo/` | The promo: nanoui's shots, Blender's laptops, the Windows and Linux recordings ([docs/promo.md](docs/promo.md)) |

The icon is drawn by `tools/icon.py`. `src/backdrop.jpg` (the film's cover art) was made with OpenAI's image model.

Forked from [justrach/nanolight](https://github.com/justrach/nanolight), with the original code structure and nanoui renderer.

## License

MIT
