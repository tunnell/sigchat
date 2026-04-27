#!/usr/bin/env bash
# tools/run-all-tests.sh
#
# Runs all test families and reports a per-family PASS / SKIPPED /
# FAIL summary. The orchestrator is the documented entry point for
# "run the full test suite before declaring this PR ready" — see
# tests/README.md for the testing methodology.
#
# Test families (sigchat has both send and receive surface):
#   1. Rust unit and integration tests (cargo test)
#   2. Hosted-mode end-to-end SEND (requires tools/.env + signal-cli +
#      X11 display + a linked PDDB snapshot)
#   3. Hosted-mode end-to-end RECEIVE (requires the SEND prereqs PLUS
#      a separate signal-cli account that can send to the linked
#      account's username)
#   4. Memory footprint (static binary size against the documented
#      budget; Renode boot smoke test if Renode is installed)
#
# Families whose prerequisites aren't met are SKIPPED, not FAIL.
#
# Usage:
#   ./tools/run-all-tests.sh
#   ./tools/run-all-tests.sh --skip-e2e          # both send and recv
#   ./tools/run-all-tests.sh --skip-send
#   ./tools/run-all-tests.sh --skip-recv
#   ./tools/run-all-tests.sh --skip-footprint
#   ./tools/run-all-tests.sh --skip-renode
#
# Exit codes:
#   0 = every runnable family passed
#   1 = at least one runnable family failed
#   2 = setup error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
ROOT="$(sg_repo_root)"

SKIP_SEND=0
SKIP_RECV=0
SKIP_FOOTPRINT=0
SKIP_RENODE=0
for arg in "$@"; do
    case "$arg" in
        --skip-e2e) SKIP_SEND=1; SKIP_RECV=1 ;;
        --skip-send) SKIP_SEND=1 ;;
        --skip-recv) SKIP_RECV=1 ;;
        --skip-footprint) SKIP_FOOTPRINT=1 ;;
        --skip-renode) SKIP_RENODE=1 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

cd "$ROOT"
declare -A RESULTS
declare -A DETAIL

# --- Family 1: Rust tests ---
echo "================================================"
echo "Family 1: Rust unit/integration tests"
echo "================================================"
RUST_LOG="/tmp/sigchat-rust-test.log"
if cargo test --features hosted 2>&1 | tee "$RUST_LOG" | tail -10; then
    RESULTS[rust]="PASS"
    DETAIL[rust]="$(grep -E "^test result: ok\. [1-9]" "$RUST_LOG" | head -1)"
    [[ -z "${DETAIL[rust]}" ]] && \
        DETAIL[rust]="$(grep -E "^test result:" "$RUST_LOG" | head -1)"
else
    RESULTS[rust]="FAIL"
    DETAIL[rust]="see $RUST_LOG"
fi

# --- Family 2: Hosted send ---
echo ""
echo "================================================"
echo "Family 2: Hosted-mode E2E send"
echo "================================================"
if (( SKIP_SEND )); then
    RESULTS[send-e2e]="SKIPPED"
    DETAIL[send-e2e]="--skip-send"
elif [[ ! -f "$ROOT/tools/.env" ]]; then
    RESULTS[send-e2e]="SKIPPED"
    DETAIL[send-e2e]="tools/.env not configured (see tools/test-env.example)"
elif ! command -v signal-cli &>/dev/null; then
    RESULTS[send-e2e]="SKIPPED"
    DETAIL[send-e2e]="signal-cli not installed"
else
    if "$SCRIPT_DIR/scan-send.sh"; then
        RESULTS[send-e2e]="PASS"
        DETAIL[send-e2e]="post: sent observed; verify via decode-wire.sh + signal-cli + phones"
    else
        RC=$?
        if (( RC == 2 )); then
            RESULTS[send-e2e]="SKIPPED"
            DETAIL[send-e2e]="setup failure in scan-send.sh"
        else
            RESULTS[send-e2e]="FAIL"
            DETAIL[send-e2e]="scan-send.sh exit $RC"
        fi
    fi
fi

# --- Family 3: Hosted recv ---
echo ""
echo "================================================"
echo "Family 3: Hosted-mode E2E receive"
echo "================================================"
if (( SKIP_RECV )); then
    RESULTS[recv-e2e]="SKIPPED"
    DETAIL[recv-e2e]="--skip-recv"
elif [[ ! -f "$ROOT/tools/.env" ]]; then
    RESULTS[recv-e2e]="SKIPPED"
    DETAIL[recv-e2e]="tools/.env not configured (see tools/test-env.example)"
elif ! command -v signal-cli &>/dev/null; then
    RESULTS[recv-e2e]="SKIPPED"
    DETAIL[recv-e2e]="signal-cli not installed"
else
    if "$SCRIPT_DIR/recv-verify.sh"; then
        RESULTS[recv-e2e]="PASS"
        DETAIL[recv-e2e]="marker received and decrypted by sigchat"
    else
        RC=$?
        if (( RC == 2 )); then
            RESULTS[recv-e2e]="SKIPPED"
            DETAIL[recv-e2e]="setup failure in recv-verify.sh"
        else
            RESULTS[recv-e2e]="FAIL"
            DETAIL[recv-e2e]="recv-verify.sh exit $RC"
        fi
    fi
fi

# --- Family 4: Footprint ---
echo ""
echo "================================================"
echo "Family 4: Memory footprint"
echo "================================================"
if (( SKIP_FOOTPRINT )); then
    RESULTS[footprint]="SKIPPED"
    DETAIL[footprint]="--skip-footprint"
else
    SIZE_RC=0
    "$SCRIPT_DIR/measure-size.sh" || SIZE_RC=$?

    RENODE_RC=0
    RENODE_NOTE=""
    if (( SKIP_RENODE )); then
        RENODE_NOTE="renode skipped (--skip-renode)"
    elif ! command -v renode &>/dev/null; then
        RENODE_NOTE="renode not installed"
    else
        "$SCRIPT_DIR/measure-renode.sh" || RENODE_RC=$?
    fi

    case "$SIZE_RC" in
        0) SIZE_NOTE="size budgets pass" ;;
        1) SIZE_NOTE="size budget breached (see report)" ;;
        2) SIZE_NOTE="size measurement setup failed" ;;
        *) SIZE_NOTE="size unknown ($SIZE_RC)" ;;
    esac
    case "$RENODE_RC" in
        0) [[ -z "$RENODE_NOTE" ]] && RENODE_NOTE="renode boot smoke pass" ;;
        1) RENODE_NOTE="renode boot smoke FAIL" ;;
        2) RENODE_NOTE="renode setup failed" ;;
    esac

    if (( SIZE_RC == 0 )) && { (( RENODE_RC == 0 )) || (( RENODE_RC == 2 )); }; then
        RESULTS[footprint]="PASS"
    elif (( SIZE_RC == 2 )); then
        RESULTS[footprint]="SKIPPED"
    else
        RESULTS[footprint]="FAIL"
    fi
    DETAIL[footprint]="$SIZE_NOTE; $RENODE_NOTE"
fi

# --- Summary ---
echo ""
echo "================================================"
echo "Summary"
echo "================================================"
for fam in rust send-e2e recv-e2e footprint; do
    printf "  %-12s %-8s %s\n" \
        "${fam}:" "${RESULTS[$fam]:-?}" "${DETAIL[$fam]:-}"
done

ANY_FAIL=0
for r in "${RESULTS[@]:-}"; do
    [[ "$r" == "FAIL" ]] && ANY_FAIL=1
done
exit "$ANY_FAIL"
