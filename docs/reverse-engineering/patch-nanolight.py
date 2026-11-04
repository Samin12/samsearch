"""Swap Nanolight's built-in "Ask Grok" and "Search X" rows for Quick Ask and a new T3 thread.

Nanolight hardcodes those rows, so this patches the app's strings in place (same byte
length each), re-signs it ad hoc and restarts it. The rows then open quickask:// links,
which ~/Applications/Quick Ask.app handles. Re-run after every Nanolight update.

Usage: python3 -I patch-nanolight.py            patch (backs up the original first)
       python3 -I patch-nanolight.py --restore  put the backed-up original back
"""
import os, shutil, subprocess, sys, time
from pathlib import Path

APP = Path("/Applications/Nanolight.app")
BIN = APP / "Contents/MacOS/nanolight"
BACKUP = Path(__file__).resolve().parent / "backup"

SWAPS = [
    ("https://grok.com/?q=", "quickask://answer?q="),
    ("https://x.com/search?f=live&q=", "quickask://t3-thread-create?q="),
    ("\0Ask Grok\0", "\0Ask fast\0"),
    ("\0Search X for\0", "\0New T3 task:\0"),
    ("\0grok.com\0", "\0Haiku   \0"),
    ("\0x.com · Latest\0", "\0T3 Code · Opus\0"),
    ("\0𝕏\0", "\0T3 \0"),
    ("Search apps, do math, ask Grok…", "Search apps, do math, ask fast…"),
]

# The Grok/X rows hand their URL to Nanolight's item launcher, which only opens http(s) links and
# drops quickask:// ones. In the row handler (fcn.1000b9f24, Nanolight 0.2.6) call its
# NSWorkspace openURL: wrapper (fcn.10007eb48) directly instead, then hide the window as before.
# File offset = address - 0x100000000 (thin arm64 binary). See re/FINDINGS.md.
CODE = [
    (0xBA27C, "a8a641f9", "b3a241f9"),  # ldr x8, [x21,#0x348]  -> ldr x19, [x21,#0x340]
    (0xBA280, "b3a241f9", "e00301aa"),  # ldr x19, [x21,#0x340] -> mov x0, x1   (url ptr)
    (0xBA284, "e00313aa", "e10302aa"),  # mov x0, x19           -> mov x1, x2   (url len)
    (0xBA288, "00013fd6", "3012ff97"),  # blr x8 (launcher)     -> bl 0x10007eb48 (openURL)
]


def restart():
    subprocess.run(["osascript", "-e", 'quit app "Nanolight"'], capture_output=True)
    time.sleep(1.5)
    subprocess.run(["pkill", "-x", "nanolight"], capture_output=True)
    time.sleep(0.5)
    subprocess.run(["open", "-a", str(APP)])


def patch():
    version = subprocess.run(["defaults", "read", str(APP / "Contents/Info"), "CFBundleShortVersionString"],
                             capture_output=True, text=True).stdout.strip()
    data = BIN.read_bytes()
    changed = 0
    for old, new in SWAPS:
        o, n = old.encode(), new.encode()
        assert len(o) == len(n), f"length mismatch: {old!r} -> {new!r}"
        if o in data:
            data = data.replace(o, n)
            changed += 1
        elif n not in data:
            sys.exit(f"Couldn't find {old!r}. Nanolight {version} changed; update SWAPS before patching.")
    data = bytearray(data)
    for off, old, new in CODE:
        o, n = bytes.fromhex(old), bytes.fromhex(new)
        here = bytes(data[off:off + 4])
        if here == o:
            data[off:off + 4] = n
            changed += 1
        elif here != n:
            sys.exit(f"Unexpected code at {off:#x}. Nanolight {version} changed; update CODE before patching.")
    data = bytes(data)
    if not changed:
        print(f"Nanolight {version} is already patched.")
        return
    keep = BACKUP / f"Nanolight-{version}.app"
    if not keep.exists():
        BACKUP.mkdir(exist_ok=True)
        subprocess.run(["ditto", str(APP), str(keep)], check=True)
        print(f"Backed up the original to {keep}")
    # Write a new file and swap it in, so the running copy isn't modified under itself.
    tmp = BIN.with_name("nanolight.patched")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o755)
    os.replace(tmp, BIN)
    subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", str(APP)], check=True)
    print(f"Patched {changed} spots in Nanolight {version}.")
    restart()


def restore():
    backups = sorted(BACKUP.glob("Nanolight-*.app"))
    if not backups:
        sys.exit("No backup found.")
    src = backups[-1]
    tmp = APP.with_name("Nanolight.restoring.app")
    subprocess.run(["ditto", str(src), str(tmp)], check=True)
    old = APP.with_name("Nanolight.patched.app")
    os.replace(APP, old)
    os.replace(tmp, APP)
    print(f"Restored {src.name}. The patched copy is at {old}.")
    restart()


if __name__ == "__main__":
    restore() if "--restore" in sys.argv else patch()
