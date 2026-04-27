#!/usr/bin/env bash
# tools/decode-wire.sh
#
# Decodes Content protobufs captured during a scan-send.sh run via the
# XSCDEBUG_DUMP env var, and verifies field tags match canonical
# SignalService.proto. The dump file format is one labelled hex line
# per artifact, e.g.:
#
#   [<ts>] Content protobuf (DataMessage, ...) (len=N): <hex>
#   [<ts>] Padded plaintext (...) (len=160): <hex>
#   [<ts>] Ciphertext (envelope type=N) for <uuid>/<dev> (len=N): <hex>
#
# This script:
#   - Decodes every Content protobuf line via `protoc --decode_raw`.
#   - Verifies DataMessage has tag 1 (body) and tag 7 (timestamp) at
#     the canonical positions per Signal's SignalService.proto. The
#     v6 sigchat regression — emitting timestamp at tag 5 instead of
#     tag 7 — is exactly what this verification catches: wire bytes
#     against canonical, NOT against our own decoder.
#   - Reports the timestamp value(s) seen across all locations and
#     flags inconsistencies.
#
# Prerequisites:
#   - protoc on PATH (apt: protobuf-compiler)
#   - xxd on PATH
#   - A wire dump file (default /tmp/sigchat-wire-dump.txt)
#
# Output:
#   - Per-protobuf decoded structure on stdout
#   - Verification summary at the end
#
# Exit codes:
#   0 = all Content protobufs parsed and required tags present
#   1 = at least one Content protobuf failed verification (e.g.
#       canonical-tag mismatch — currently expected on sigchat
#       because of the documented v6 timestamp tag-5 bug)
#   2 = setup failure (missing tools, missing dump file)
#
# Usage:
#   ./tools/decode-wire.sh
#   ./tools/decode-wire.sh /path/to/sigchat-wire-dump.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

DUMP_FILE="${1:-/tmp/sigchat-wire-dump.txt}"

sg_require_cmd protoc "apt install protobuf-compiler" || exit 2
sg_require_cmd xxd "apt install xxd" || exit 2

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "Wire dump not found: $DUMP_FILE" >&2
    echo "Run a scan with XSCDEBUG_DUMP=1 first (./tools/scan-send.sh)." >&2
    exit 2
fi

decode_hex() {
    local hex="$1"
    echo "$hex" | xxd -r -p | protoc --decode_raw
}

DM_COUNT=0
SM_COUNT=0
ALL_TS=()
FAIL=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ Content\ protobuf\ \(([^,]+),.*\(len=([0-9]+)\):\ ([0-9a-fA-F]+)$ ]]; then
        kind="${BASH_REMATCH[1]}"
        hex="${BASH_REMATCH[3]}"
        echo "================================================"
        echo "Content: $kind"
        echo "================================================"
        decoded="$(decode_hex "$hex" 2>&1)" || {
            echo "DECODE FAILED" >&2
            echo "$decoded"
            FAIL=1
            continue
        }
        echo "$decoded"

        if [[ "$kind" == *DataMessage* ]]; then
            DM_COUNT=$((DM_COUNT + 1))
            if ! grep -E "^\s*1: \"" <<<"$decoded" >/dev/null; then
                echo "  WARN: DataMessage.body (tag 1) absent" >&2
                FAIL=1
            fi
            if ! grep -E "^\s*7: [0-9]+" <<<"$decoded" >/dev/null; then
                echo "  FAIL: DataMessage.timestamp (tag 7) absent — would be the v6 bug class" >&2
                # Check whether tag 5 is being misused for the timestamp
                # (the documented v6 sigchat regression).
                if grep -E "^\s*5: [0-9]+" <<<"$decoded" >/dev/null; then
                    echo "  FAIL: DataMessage uses tag 5 (expireTimer slot) for timestamp; canonical SignalService.proto requires tag 7" >&2
                fi
                FAIL=1
            fi
            ts="$(grep -E "^\s*7: [0-9]+$" <<<"$decoded" | head -1 | awk '{print $2}')"
            [[ -n "$ts" ]] && ALL_TS+=("dm:$ts")
        elif [[ "$kind" == *SyncMessage* ]]; then
            SM_COUNT=$((SM_COUNT + 1))
            if ! grep -E "^\s*2: [0-9]+" <<<"$decoded" >/dev/null; then
                echo "  FAIL: Sent.timestamp (tag 2) absent" >&2
                FAIL=1
            fi
            if ! grep -E "^\s*3 \{" <<<"$decoded" >/dev/null; then
                echo "  FAIL: Sent.message (tag 3) absent" >&2
                FAIL=1
            fi
            if ! grep -E "^\s*7: \"" <<<"$decoded" >/dev/null; then
                echo "  WARN: Sent.destinationServiceId (tag 7) absent" >&2
            fi
            while IFS= read -r ts; do
                [[ -n "$ts" ]] && ALL_TS+=("sm:$ts")
            done < <(grep -E "^\s*[27]: [0-9]+$" <<<"$decoded" | awk '{print $2}')
        fi
        echo ""
    fi
done < "$DUMP_FILE"

echo "================================================"
echo "Verification summary"
echo "================================================"
echo "  DataMessage Content protobufs: $DM_COUNT"
echo "  SyncMessage Content protobufs: $SM_COUNT"

declare -A SEEN
for entry in "${ALL_TS[@]:-}"; do
    val="${entry#*:}"
    SEEN[$val]=1
done
distinct_count=${#SEEN[@]}
echo "  Distinct timestamp values: $distinct_count"
for ts in "${!SEEN[@]}"; do
    echo "    $ts"
done

if (( DM_COUNT == 0 )); then
    echo "  FAIL: no DataMessage Content protobufs decoded" >&2
    FAIL=1
fi

if (( distinct_count > 1 && SM_COUNT > 0 )); then
    echo "  WARN: multiple distinct timestamps across DataMessage + SyncMessage." >&2
fi

if (( FAIL )); then
    echo ""
    echo "RESULT: FAIL"
    exit 1
fi

echo ""
echo "RESULT: PASS"
exit 0
