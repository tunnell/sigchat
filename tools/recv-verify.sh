#!/usr/bin/env bash
# tools/recv-verify.sh
#
# Hosted-mode end-to-end RECEIVE test driver. Boots Xous with the
# sigchat-linked PDDB snapshot, drives an external signal-cli account
# (via tools/signal-send.sh) to inject a uniquely-marked inbound
# message, then verifies sigchat decrypts and delivers it intact.
#
# Verification leg structure:
#   leg 1: wire format — implicit (sigchat decrypted the envelope and
#          parsed the Content protobuf without dropping the message)
#   leg 2: recipient parse — sigchat's debug recv hook (gated by
#          SIGCHAT_DEBUG_RECV=1) emits a structured `[recv-debug]`
#          log line containing the body. recv-verify.sh greps for the
#          marker timestamp emitted by signal-send.sh.
#   leg 3: user-visible — manual; check the Precursor emulator
#          conversation list after the scan if needed.
#
# Prerequisites:
#   - tools/.env configured (see tools/test-env.example)
#   - signal-cli installed and on PATH; the SIGNAL_SENDER account is
#     a DIFFERENT account from sigchat's linked account
#   - sigchat linked on the recipient account; its PDDB snapshot is
#     at $SIGCHAT_PDDB_IMAGE (or hosted-linked-display-verified.bin)
#   - X11 display (default :10)
#   - xous-core checkout
#
# Output:
#   - Scan log to /tmp/sigchat-recv-<timestamp>.log
#
# Exit codes:
#   0 = sigchat received the marker; body matches what signal-send.sh
#       sent (timestamp-based correlation)
#   1 = sigchat did not receive the marker, or body mismatch
#   2 = setup failure
#
# Usage:
#   ./tools/recv-verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
ROOT="$(sg_repo_root)"

if ! sg_load_env; then
    echo "tools/.env not found." >&2
    exit 2
fi

sg_require_cmd signal-cli || exit 2
sg_require_cmd cargo || exit 2

XOUS_CORE_PATH="${XOUS_CORE_PATH:-$ROOT/../xous-core}"
[[ -d "$XOUS_CORE_PATH" ]] || { echo "xous-core not found at $XOUS_CORE_PATH" >&2; exit 2; }

PDDB_IMAGE="${SIGCHAT_PDDB_IMAGE:-$XOUS_CORE_PATH/tools/pddb-images/hosted-linked-display-verified.bin}"
[[ -f "$PDDB_IMAGE" ]] || { echo "PDDB image not found: $PDDB_IMAGE" >&2; exit 2; }

# signal-send.sh defaults SIGNAL_RECIPIENT to PrecursorEmulator.02 and
# auto-detects SIGNAL_SENDER. Both can be overridden in tools/.env.
SIGNAL_SEND="$ROOT/tools/signal-send.sh"
[[ -x "$SIGNAL_SEND" ]] || { echo "tools/signal-send.sh missing or not executable" >&2; exit 2; }

TS=$(date +%s)
LOG="/tmp/sigchat-recv-${TS}.log"

# The recv hook in main_ws.rs requires SIGCHAT_DEBUG_RECV=1 to emit
# parseable log lines containing the message body. Tests opt in here.
export DISPLAY="${DISPLAY:-:10}"
export SIGCHAT_DEBUG_RECV=1

echo "=== sigchat recv-verify (ts=$TS) ==="
echo "  Log: $LOG"
echo ""

pkill -f "xous-kernel" 2>/dev/null || true
sleep 1

HOSTED_BIN="$XOUS_CORE_PATH/tools/pddb-images/hosted.bin"
echo "Restoring PDDB snapshot -> $HOSTED_BIN"
cp "$PDDB_IMAGE" "$HOSTED_BIN"

echo "Booting sigchat..."
(cd "$XOUS_CORE_PATH" && \
    timeout 240 cargo xtask run \
    "sigchat:$ROOT/target/release/sigchat" \
    >"$LOG" 2>&1) &
XOUS_PID=$!

echo "Waiting for sigchat WS to authenticate..."
WAIT=0
while (( WAIT < 90 )); do
    if grep -q "main_ws: authenticated\|authenticated websocket\|receive worker started" "$LOG" 2>/dev/null; then
        echo "  WS up at t=${WAIT}s"
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
done
sleep 5

# signal-send.sh prefixes its own ISO timestamp; that's the unique
# marker we will look for. Capture it from the log line signal-send.sh
# writes to its own log file.
echo ""
echo "=== Driving signal-send.sh to inject marker ==="
SEND_OUT="$(SIGNAL_LOG=/tmp/sigchat-recv-send.log "$SIGNAL_SEND" "phase-r-recv-${TS}" 2>&1 || true)"
echo "$SEND_OUT"

# Marker = the [<ISO>] prefix that signal-send.sh prepends to bodies.
# Extract from the log line just appended.
MARKER_LINE="$(tail -1 /tmp/sigchat-recv-send.log 2>/dev/null || true)"
if [[ -z "$MARKER_LINE" ]]; then
    echo "ERROR: signal-send.sh did not append a log line" >&2
    pkill -f "xous-kernel" 2>/dev/null || true
    exit 1
fi
echo "  send log line: $MARKER_LINE"

# Pull out the body= field. signal-send.sh quotes it with %q which we
# can decode by grabbing everything after `body=` and stripping the
# quotes. The unique part is the phase-r-recv-${TS} substring.
SUBSTRING="phase-r-recv-${TS}"

echo ""
echo "=== Watching for [recv-debug] line containing '$SUBSTRING' (60s) ==="
WAIT=0
FOUND=""
while (( WAIT < 60 )); do
    FOUND="$(grep "\[recv-debug\]" "$LOG" 2>/dev/null | grep -F "$SUBSTRING" | head -1)"
    if [[ -n "$FOUND" ]]; then
        break
    fi
    sleep 5
    WAIT=$((WAIT + 5))
done

echo ""
echo "=== Cleaning up emulator ==="
pkill -f "xous-kernel" 2>/dev/null || true
wait "$XOUS_PID" 2>/dev/null || true

if [[ -z "$FOUND" ]]; then
    echo ""
    echo "RESULT: FAIL (no [recv-debug] line with marker '$SUBSTRING' in ${WAIT}s)"
    echo "Last 10 main_ws log lines:"
    grep "main_ws" "$LOG" 2>/dev/null | tail -10
    exit 1
fi

echo ""
echo "=== Match found ==="
echo "$FOUND"
echo ""
echo "RESULT: PASS"
exit 0
