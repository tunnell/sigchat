#!/usr/bin/env bash
# tools/measure-renode.sh
#
# Runtime smoke test under Renode hardware emulation. Builds a Xous
# image with sigchat, boots it in Renode (no GUI), and checks that the
# binary reaches its event loop without panic, fault, or exception.
# Mirrors TESTING-PLAN.md Check 4.
#
# This is a smoke test, not a per-feature regression — it confirms the
# binary can boot and `INFO:sigchat: my PID is N` appears. Functional
# correctness is exercised in the Rust unit tests and the hosted-mode
# E2E drivers.
#
# Prerequisites:
#   - Renode v1.16.1 or later on PATH
#   - xous-core checkout at $XOUS_CORE_PATH (default ../xous-core) on
#     branch feat/05-curve25519-dalek-4.1.3
#   - sigchat release binary already built for the Xous target (run
#     measure-size.sh first if needed)
#
# Output:
#   - /tmp/sigchat-renode-boot-<timestamp>.log (full Renode console)
#
# Exit codes:
#   0 = boot reached event loop, no panic
#   1 = panic, fault, or did not reach event loop
#   2 = setup failure (Renode not installed, xous-core not found,
#       binary not built, OR known peripheral compile incompatibility
#       — see tests/renode/README.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
ROOT="$(sg_repo_root)"

sg_require_cmd renode \
    "Install Renode v1.16.1+: https://github.com/renode/renode/releases" \
    || exit 2

XOUS_CORE_PATH="${XOUS_CORE_PATH:-$ROOT/../xous-core}"
if [[ ! -d "$XOUS_CORE_PATH" ]]; then
    echo "xous-core not found at $XOUS_CORE_PATH" >&2
    exit 2
fi

TARGET="riscv32imac-unknown-xous-elf"
BIN_NAME="sigchat"
ELF="$ROOT/target/$TARGET/release/$BIN_NAME"
if [[ ! -f "$ELF" ]]; then
    echo "Binary not found: $ELF" >&2
    echo "Run ./tools/measure-size.sh first to build." >&2
    exit 2
fi

TS=$(date +%s)
LOG="/tmp/sigchat-renode-boot-${TS}.log"
RESC="$XOUS_CORE_PATH/emulation/xous-release.resc"

if [[ ! -f "$RESC" ]]; then
    echo "Renode script not found: $RESC" >&2
    exit 2
fi

COMMIT="$(cd "$ROOT" && git rev-parse --short=7 HEAD)"

echo "=== Building Renode image with sigchat ==="
cd "$XOUS_CORE_PATH"
# --git-describe must match vX.Y.Z-N-gHASH (xous-create-image.rs).
# The "sigchat:" cratespec uses xous-core's apps/manifest.json entry
# for sigchat, populating gam/src/apps.rs with APP_NAME_SIGCHAT.
# Required for both this build and subsequent `cargo test --features
# hosted` runs in this repo.
if ! cargo xtask renode-image \
        "$BIN_NAME:$ROOT/target/$TARGET/release/$BIN_NAME" \
        --no-verify \
        --git-describe "v0.9.8-0-g${COMMIT}" 2>&1 | tail -10; then
    echo "Renode image build failed." >&2
    exit 2
fi

echo ""
echo "=== Booting Renode (90s timeout) ==="
timeout --kill-after=10 90 \
    renode --console --disable-gui \
    -e "include @${RESC}; start" \
    >"$LOG" 2>&1 || true

echo "Boot log: $LOG"

# Detect known-environmental Renode peripheral compile failures, e.g.
# the LiteX_Timer_32.cs `long`/`ulong` incompatibility against newer
# Renode versions documented in tests/renode/README.md. These are not
# binary regressions; they're a Renode-vs-xous-core peripheral version
# mismatch that needs an upstream xous-core patch. Report SKIPPED so
# the orchestrator does not surface them as a FAIL.
if grep -qE "Could not compile assembly|peripherals/.*\.cs.*error CS" "$LOG"; then
    echo ""
    echo "=== Renode peripheral compile failure (environmental) ==="
    grep -E "Could not compile assembly|peripherals/.*\.cs" "$LOG" | head -5
    echo ""
    echo "This is a known Renode / xous-core peripheral incompatibility;"
    echo "see tests/renode/README.md for context. Skipping renode smoke."
    exit 2
fi

if grep -E "panic|abort|fault|exception|FATAL" "$LOG" >/dev/null 2>&1; then
    echo ""
    echo "=== Panic/fault detected ==="
    grep -E "panic|abort|fault|exception|FATAL" "$LOG" | head -20
    exit 1
fi

if ! grep "INFO:sigchat" "$LOG" >/dev/null 2>&1; then
    echo ""
    echo "=== Binary did not reach event loop ==="
    echo "Last 20 lines of boot log:"
    tail -20 "$LOG"
    exit 1
fi

echo ""
echo "=== Smoke test PASS ==="
grep "INFO:sigchat" "$LOG" | head -5
exit 0
