# tools/test-helpers.sh
#
# Shared shell library for the sigchat test drivers.
# Source from other tools/*.sh scripts; do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "test-helpers.sh is a library; source it from another script." >&2
    exit 64
fi

# Resolve the repository root from this file's location, regardless of
# the caller's working directory.
sg_repo_root() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$here/.." && pwd
}

# Load tools/.env if present. Missing file is not fatal here — callers
# decide whether they need it.
sg_load_env() {
    local root env
    root="$(sg_repo_root)"
    env="$root/tools/.env"
    if [[ -f "$env" ]]; then
        # shellcheck source=/dev/null
        source "$env"
        return 0
    fi
    return 1
}

# Require a set of env-var names to be non-empty.
sg_require_env() {
    local missing=()
    local v
    for v in "$@"; do
        if [[ -z "${!v:-}" ]]; then
            missing+=("$v")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Missing required env vars: ${missing[*]}" >&2
        echo "Configure them in tools/.env (see tools/test-env.example)." >&2
        return 2
    fi
    return 0
}

# Require a command to be on PATH. Returns 2 if not found.
sg_require_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        echo "Required command not found: $cmd" >&2
        if [[ -n "$hint" ]]; then
            echo "  $hint" >&2
        fi
        return 2
    fi
    return 0
}

# Periodic signal-cli receive on an account. Without this, Signal flags
# the linked account as inactive after some quiet period. This exists
# as a helper for cron-style usage; recv-verify.sh calls signal-cli
# receive itself as part of verification, so this is informational.
sg_drain_receive() {
    local account="$1"
    timeout 30 signal-cli -a "$account" receive >/dev/null 2>&1 || true
}
