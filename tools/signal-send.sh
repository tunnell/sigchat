#!/bin/bash
# signal-send.sh — send a timestamped Signal message to a username recipient.
#
# See ./signal-send.md for full usage docs.

set -eu

RECIPIENT="${SIGNAL_RECIPIENT:-PrecursorEmulator.02}"
LOG="${SIGNAL_LOG:-$HOME/workdir/sigchat/tools/signal-send.log}"

command -v signal-cli >/dev/null 2>&1 || {
    echo "ERROR: signal-cli not on PATH" >&2
    exit 2
}

# Auto-detect sender if unset: require exactly one account.
if [ -z "${SIGNAL_SENDER:-}" ]; then
    ACCOUNTS=$(signal-cli listAccounts 2>/dev/null | awk '/^Number:/ {print $2}')
    COUNT=$(printf "%s\n" "$ACCOUNTS" | grep -c . || true)
    if [ "$COUNT" -eq 1 ]; then
        SIGNAL_SENDER="$ACCOUNTS"
    else
        echo "ERROR: cannot auto-detect sender; found $COUNT accounts." >&2
        echo "Set SIGNAL_SENDER to the E.164 number of the linked account." >&2
        exit 2
    fi
fi

TS=$(date --iso-8601=seconds)
if [ "$#" -gt 0 ]; then
    MSG="[$TS] $*"
else
    MSG="[$TS]"
fi

mkdir -p "$(dirname "$LOG")"

echo "from=$SIGNAL_SENDER to=$RECIPIENT" >&2
echo "body=$MSG" >&2

set +e
OUT=$(signal-cli -a "$SIGNAL_SENDER" send --username "$RECIPIENT" -m "$MSG" 2>&1)
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
    printf "%s  SENT  sender=%s  recipient=%s  sig_ts=%s  body=%q\n" \
        "$TS" "$SIGNAL_SENDER" "$RECIPIENT" "$OUT" "$MSG" >> "$LOG"
    echo "OK $OUT"
    exit 0
else
    printf "%s  FAIL  sender=%s  recipient=%s  rc=%s  err=%q  body=%q\n" \
        "$TS" "$SIGNAL_SENDER" "$RECIPIENT" "$RC" "$OUT" "$MSG" >> "$LOG"
    echo "FAILED rc=$RC: $OUT" >&2
    exit 3
fi
