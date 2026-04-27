#!/usr/bin/env bash
# tools/scan-send.sh
#
# Hosted-mode end-to-end SEND test driver. Boots Xous with the
# sigchat-linked PDDB snapshot, navigates the emulator UI, types a
# message, presses Enter, and watches the scan log for the send
# result. Wire bytes are captured to /tmp/sigchat-wire-dump.txt via
# the XSCDEBUG_DUMP=1 env var for offline verification by
# tools/decode-wire.sh.
#
# Three-legged stool of verification (see tests/README.md):
#   leg 1: wire bytes — captured here, decoded by decode-wire.sh
#   leg 2: recipient parse — signal-cli on the sigchat-linked account
#          sees the SyncMessage::Sent fan-out for any send by sigchat
#          (run signal-cli receive after the scan)
#   leg 3: user-visible — open Signal on the recipient phone
#
# Prerequisites:
#   - tools/.env configured (see tools/test-env.example)
#   - signal-cli installed and on PATH
#   - sigchat linked as a secondary device on the sender account;
#     PDDB snapshot at $SIGCHAT_PDDB_IMAGE
#   - X11 display (default :10) where the emulator window appears
#   - python3 (ctypes; usually present)
#   - xous-core checkout at $XOUS_CORE_PATH on
#     feat/05-curve25519-dalek-4.1.3
#
# Output:
#   - Wire bytes to /tmp/sigchat-wire-dump.txt
#   - Scan log to /tmp/sigchat-scan-<timestamp>.log
#
# Exit codes:
#   0 = post: sent observed in log
#   1 = send failed (RetryExhausted, send error, or no post: sent)
#   2 = setup failure (missing env, prerequisites, build error)
#
# Usage:
#   ./tools/scan-send.sh                # send "Test"
#   ./tools/scan-send.sh "Hello world"  # send custom text

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
ROOT="$(sg_repo_root)"

if ! sg_load_env; then
    echo "tools/.env not found." >&2
    echo "Copy tools/test-env.example to tools/.env and configure." >&2
    exit 2
fi

sg_require_env SIGCHAT_LINKED_NUMBER || exit 2
sg_require_cmd cargo || exit 2
sg_require_cmd python3 || exit 2

XOUS_CORE_PATH="${XOUS_CORE_PATH:-$ROOT/../xous-core}"
if [[ ! -d "$XOUS_CORE_PATH" ]]; then
    echo "xous-core not found at $XOUS_CORE_PATH" >&2
    exit 2
fi

PDDB_IMAGE="${SIGCHAT_PDDB_IMAGE:-$XOUS_CORE_PATH/tools/pddb-images/hosted-linked-display-verified.bin}"
if [[ ! -f "$PDDB_IMAGE" ]]; then
    echo "PDDB image not found: $PDDB_IMAGE" >&2
    echo "Set SIGCHAT_PDDB_IMAGE in tools/.env to a linked-account snapshot." >&2
    exit 2
fi

MESSAGE="${1:-Test}"
TS=$(date +%s)
LOG="/tmp/sigchat-scan-${TS}.log"
WIRE_DUMP="/tmp/sigchat-wire-dump.txt"

export DISPLAY="${DISPLAY:-:10}"
export XSCDEBUG_DUMP=1

echo "=== sigchat send scan (ts=$TS) ==="
echo "  Message:    '$MESSAGE'"
echo "  Sender:     $SIGCHAT_LINKED_NUMBER (linked sigchat)"
echo "  Log:        $LOG"
echo "  Wire dump:  $WIRE_DUMP"
echo ""

: >"$WIRE_DUMP"

pkill -f "xous-kernel" 2>/dev/null || true
sleep 1

HOSTED_BIN="$XOUS_CORE_PATH/tools/pddb-images/hosted.bin"
echo "Restoring PDDB snapshot -> $HOSTED_BIN"
cp "$PDDB_IMAGE" "$HOSTED_BIN"

echo "Booting sigchat..."
(cd "$XOUS_CORE_PATH" && \
    timeout 360 cargo xtask run \
    "sigchat:$ROOT/target/release/sigchat" \
    >"$LOG" 2>&1) &
XOUS_PID=$!

echo "Waiting for system to settle..."
WAIT=0
while (( WAIT < 120 )); do
    if grep -q "my PID is" "$LOG" 2>/dev/null && \
       grep -q "sigchat\|SigChat" "$LOG" 2>/dev/null; then
        echo "  System up at t=${WAIT}s"
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
done
sleep 10

echo ""
echo "=== Driving emulator (Home/Down navigation + type + Enter) ==="
python3 - "$MESSAGE" "$DISPLAY" <<'PYEOF'
import ctypes, time, os, sys

MESSAGE = sys.argv[1]
DISPLAY = sys.argv[2]

X11 = ctypes.cdll.LoadLibrary("libX11.so.6")
c_ulong = ctypes.c_ulong; c_int = ctypes.c_int; c_uint = ctypes.c_uint

X11.XOpenDisplay.restype = ctypes.c_void_p
X11.XOpenDisplay.argtypes = [ctypes.c_char_p]
X11.XSync.argtypes = [ctypes.c_void_p, c_int]
X11.XDefaultRootWindow.restype = c_ulong
X11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X11.XKeysymToKeycode.restype = c_uint
X11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, c_ulong]
X11.XFlush.argtypes = [ctypes.c_void_p]
X11.XFetchName.restype = c_int
X11.XFetchName.argtypes = [ctypes.c_void_p, c_ulong, ctypes.POINTER(ctypes.c_char_p)]
X11.XQueryTree.restype = c_int
X11.XQueryTree.argtypes = [ctypes.c_void_p, c_ulong, ctypes.POINTER(c_ulong),
    ctypes.POINTER(c_ulong), ctypes.POINTER(ctypes.POINTER(c_ulong)), ctypes.POINTER(c_uint)]
X11.XFree.argtypes = [ctypes.c_void_p]
X11.XSendEvent.restype = c_int
X11.XSendEvent.argtypes = [ctypes.c_void_p, c_ulong, c_int, c_ulong, ctypes.c_void_p]

class XEvent(ctypes.Union):
    class XKeyEvent(ctypes.Structure):
        _fields_ = [
            ('type', c_int), ('serial', c_ulong), ('send_event', c_int),
            ('display', ctypes.c_void_p), ('window', c_ulong), ('root', c_ulong),
            ('subwindow', c_ulong), ('time', c_ulong),
            ('x', c_int), ('y', c_int), ('x_root', c_int), ('y_root', c_int),
            ('state', c_uint), ('keycode', c_uint), ('same_screen', c_int),
        ]
    _fields_ = [('key', XKeyEvent), ('pad', ctypes.c_char * 192)]

def find_win(dpy, root, name_b):
    cname = ctypes.c_char_p()
    X11.XFetchName(dpy, root, ctypes.byref(cname))
    if cname.value and name_b in cname.value.lower():
        return root
    r=c_ulong(); p=c_ulong(); ch=ctypes.POINTER(c_ulong)(); n=c_uint()
    if X11.XQueryTree(dpy, root, ctypes.byref(r), ctypes.byref(p), ctypes.byref(ch), ctypes.byref(n)):
        children = [ch[i] for i in range(n.value)]
        if n.value: X11.XFree(ch)
        for c in children:
            w = find_win(dpy, c, name_b)
            if w: return w
    return None

def press(dpy, win, root, kc, wait, label, shift=False):
    ev = XEvent()
    ev.key.type = 2
    ev.key.send_event = 1
    ev.key.display = dpy
    ev.key.window = win
    ev.key.root = root
    ev.key.subwindow = 0
    ev.key.time = 0
    ev.key.x = ev.key.y = ev.key.x_root = ev.key.y_root = 0
    ev.key.state = 1 if shift else 0
    ev.key.keycode = kc
    ev.key.same_screen = 1
    X11.XSendEvent(dpy, win, 1, 1, ctypes.byref(ev))
    X11.XFlush(dpy)
    time.sleep(0.05)
    ev.key.type = 3
    X11.XSendEvent(dpy, win, 1, 2, ctypes.byref(ev))
    X11.XFlush(dpy)
    print(f"  [{label}] kc={kc}, wait={wait}s, shift={shift}")
    sys.stdout.flush()
    time.sleep(wait)

dpy = X11.XOpenDisplay(DISPLAY.encode())
if not dpy:
    print("ERROR: cannot open display", file=sys.stderr); sys.exit(1)
root = X11.XDefaultRootWindow(dpy)

win = None
for attempt in range(30):
    win = find_win(dpy, root, b"precursor")
    if win:
        break
    print(f"  waiting for Precursor window (attempt {attempt+1})...")
    sys.stdout.flush()
    time.sleep(2)
if not win:
    print("ERROR: Precursor window not found", file=sys.stderr); sys.exit(1)

kc_home = X11.XKeysymToKeycode(dpy, 0xFF50)
kc_down = X11.XKeysymToKeycode(dpy, 0xFF54)
kc_return = X11.XKeysymToKeycode(dpy, 0xFF0D)

print("Navigating to sigchat...")
press(dpy, win, root, kc_home, 1.5,  "1. Home -> open main menu")
press(dpy, win, root, kc_down, 0.3,  "2. Down -> App")
press(dpy, win, root, kc_home, 4.5,  "3. Home -> select App")
press(dpy, win, root, kc_down, 0.3,  "4. Down -> sigchat")
press(dpy, win, root, kc_home, 25.0, "5. Home -> open sigchat (wait 25s for WS pull + decrypt)")

print(f"Typing message: '{MESSAGE}'")
for ch in MESSAGE:
    if ch == '!':
        kc = X11.XKeysymToKeycode(dpy, ord('1'))
        press(dpy, win, root, kc, 0.1, "char '!' (shift+1)", shift=True)
    elif ch == ' ':
        kc = X11.XKeysymToKeycode(dpy, 0x0020)
        press(dpy, win, root, kc, 0.1, "char ' '")
    elif ch.isupper():
        kc = X11.XKeysymToKeycode(dpy, ord(ch.lower()))
        press(dpy, win, root, kc, 0.1, f"char '{ch}' (shift+{ch.lower()})", shift=True)
    else:
        kc = X11.XKeysymToKeycode(dpy, ord(ch))
        press(dpy, win, root, kc, 0.1, f"char '{ch}'")

print("Pressing Enter to submit")
press(dpy, win, root, kc_return, 2.0, "Enter -> submit")
PYEOF

echo ""
echo "=== Watching scan log for send completion (90s timeout) ==="
WAIT=0
RESULT="timeout"
while (( WAIT < 90 )); do
    if grep -q "post: sent to" "$LOG" 2>/dev/null; then
        RESULT="sent"
        break
    fi
    if grep -qE "post: send failed|RetryExh" "$LOG" 2>/dev/null; then
        RESULT="failed"
        break
    fi
    sleep 5
    WAIT=$((WAIT + 5))
done

echo ""
echo "=== Send result ($RESULT after ${WAIT}s) ==="
grep -E "got SigchatOp::Post|post:|send:|attempt|sent to|RetryExh" "$LOG" 2>/dev/null | tail -15

echo ""
echo "=== Cleaning up emulator ==="
pkill -f "xous-kernel" 2>/dev/null || true
wait "$XOUS_PID" 2>/dev/null || true

case "$RESULT" in
    sent)
        echo ""
        echo "RESULT: PASS (post: sent)"
        echo "  Wire dump: $WIRE_DUMP"
        echo "  Run ./tools/decode-wire.sh to verify wire bytes."
        echo "  Run signal-cli -a $SIGCHAT_LINKED_NUMBER receive for leg-2."
        echo "  Check the recipient phone for leg-3."
        exit 0 ;;
    failed)
        echo ""
        echo "RESULT: FAIL (send failed in log)"
        exit 1 ;;
    *)
        echo ""
        echo "RESULT: FAIL (no terminal log line in 90s)"
        exit 1 ;;
esac
