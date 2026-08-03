#!/usr/bin/env bash
# test-orchestra-url-precedence.sh
#
# Exercises the ORCHESTRA_URL/UNITY_COMMS_URL precedence fix in
# {macos,ubuntu}/tools/setup.sh and windows/tools/setup.ps1:
#   1. an explicit --orchestra-url/--unity-comms-url (-OrchestraUrl/-UnityCommsUrl)
#      must always win over the ~/.unity compose-file auto-detect
#      (apply_compose_self_host_mode / Apply-ComposeSelfHostMode), and
#   2. it must also win over a stale .env fallback on --reconfigure/-Reconfigure,
#      so a poisoned 127.0.0.1 + SELF_HOST=1 .env from a prior self-hosted run
#      can't keep a device pinned to localhost forever.
#
# Runs against the REAL functions/code in setup.sh and setup.ps1, extracted up
# to their "# Main Execution" dispatch line so nothing here touches installed
# services, launchd/systemd, or the network. The windows/setup.ps1 checks are
# skipped (not failed) if pwsh isn't installed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

check() {
    local desc=$1 actual=$2 expected=$3
    if [[ "$actual" == "$expected" ]]; then
        echo "  ok - $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL - $desc: expected [$expected], got [$actual]" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# macOS / Ubuntu (bash)
# ---------------------------------------------------------------------------
test_bash_platform() {
    local platform=$1
    local setup_sh="$REPO_ROOT/$platform/tools/setup.sh"
    local tmpdir home_dir envdir lib snippet out env_shim source_env_shim

    tmpdir="$(mktemp -d)"
    home_dir="$tmpdir/home"
    envdir="$tmpdir/agent-service"
    mkdir -p "$home_dir" "$envdir"

    # Function defs + defaults + arg parsing, without the install/dispatch tail.
    lib="$tmpdir/lib.sh"
    awk '/^# Main Execution$/{exit} {print}' "$setup_sh" > "$lib"

    # Just the URL-precedence resolution inside the --reconfigure branch
    # (between "apply_compose_self_host_mode" and its enclosing "fi"), without
    # the surrounding registration/service calls.
    snippet="$tmpdir/reconf-precedence.sh"
    awk '/^    apply_compose_self_host_mode$/{p=1} p{print; if (/^    fi$/) exit}' "$setup_sh" > "$snippet"

    # ubuntu/tools/setup.sh's get_env_value uses GNU grep's `-oP`, which is
    # only guaranteed on the Ubuntu target, not on a macOS test box. Swap in a
    # portable equivalent so this test exercises the precedence logic added
    # here rather than the host's grep flavor.
    env_shim="$tmpdir/portable-get-env-value.sh"
    cat > "$env_shim" <<'EOF'
get_env_value() {
    local key=$1
    local env_file="$AGENT_SERVICE_DIR/.env"
    local line
    [[ -f "$env_file" ]] || return 0
    line=$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -1)
    line="${line#${key}=}"
    line="${line%\"}"; line="${line#\"}"
    printf '%s' "$line"
}
EOF
    local source_env_shim=""
    if [[ "$platform" == "ubuntu" ]]; then
        source_env_shim="source '$env_shim';"
    fi

    echo "== $platform: apply_compose_self_host_mode() =="

    mkdir -p "$home_dir/.unity"
    : > "$home_dir/.unity/docker-compose.yml"

    out=$(HOME="$home_dir" bash -c "source '$lib'; apply_compose_self_host_mode; echo \"\$ORCHESTRA_URL|\$SELF_HOST_MODE\"" | tail -1)
    check "$platform: local-stack auto-detect applies with no explicit flag" "$out" "http://127.0.0.1:8000/v0|true"

    out=$(HOME="$home_dir" bash -c "source '$lib'; apply_compose_self_host_mode; echo \"\$ORCHESTRA_URL|\$SELF_HOST_MODE\"" -- \
        --orchestra-url "https://staging.example/v0" --unity-comms-url "https://staging-comms.example" | tail -1)
    check "$platform: explicit --orchestra-url wins over compose auto-detect" "$out" "https://staging.example/v0|false"

    rm -rf "$home_dir/.unity"

    echo "== $platform: --reconfigure URL precedence =="

    cat > "$envdir/.env" <<EOF
ORCHESTRA_URL=http://127.0.0.1:8000/v0
UNITY_COMMS_URL=http://127.0.0.1:8001
SELF_HOST=1
EOF
    out=$(HOME="$home_dir" bash -c "
        source '$lib'
        $source_env_shim
        AGENT_SERVICE_DIR='$envdir'
        ORCHESTRA_URL='https://staging.example/v0'; ORCHESTRA_URL_EXPLICIT=true
        UNITY_COMMS_URL='https://staging-comms.example'; UNITY_COMMS_URL_EXPLICIT=true
        source '$snippet'
        echo \"\$ORCHESTRA_URL|\$SELF_HOST_MODE\"
    " | tail -1)
    check "$platform: explicit flags survive a poisoned .env on --reconfigure" "$out" "https://staging.example/v0|false"

    cat > "$envdir/.env" <<EOF
ORCHESTRA_URL=https://staging.example/v0
UNITY_COMMS_URL=https://staging-comms.example
SELF_HOST=0
EOF
    out=$(HOME="$home_dir" bash -c "
        source '$lib'
        $source_env_shim
        AGENT_SERVICE_DIR='$envdir'
        source '$snippet'
        echo \"\$ORCHESTRA_URL|\$SELF_HOST_MODE\"
    " | tail -1)
    check "$platform: no-flag reconfigure preserves baked staging URL from .env (Settings-only key change)" "$out" "https://staging.example/v0|false"

    cat > "$envdir/.env" <<EOF
ORCHESTRA_URL=http://127.0.0.1:8000/v0
UNITY_COMMS_URL=http://127.0.0.1:8001
SELF_HOST=1
EOF
    out=$(HOME="$home_dir" bash -c "
        source '$lib'
        $source_env_shim
        AGENT_SERVICE_DIR='$envdir'
        source '$snippet'
        echo \"\$ORCHESTRA_URL|\$SELF_HOST_MODE\"
    " | tail -1)
    check "$platform: no-flag reconfigure still auto-applies a legit self-host .env" "$out" "http://127.0.0.1:8000/v0|true"

    rm -rf "$tmpdir"
}

test_bash_platform macos
test_bash_platform ubuntu

# ---------------------------------------------------------------------------
# Windows (PowerShell) — skipped if pwsh isn't installed
# ---------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    setup_ps1="$REPO_ROOT/windows/tools/setup.ps1"
    tmpdir="$(mktemp -d)"
    home_dir="$tmpdir/home"
    envdir="$tmpdir/agent-service"
    mkdir -p "$home_dir" "$envdir"

    lib="$tmpdir/lib.ps1"
    awk '/^# Main Execution$/{exit} {print}' "$setup_ps1" > "$lib"
    snippet="$tmpdir/reconf-precedence.ps1"
    awk '/^    Apply-ComposeSelfHostMode$/{p=1} p{print; if (/^    }$/) exit}' "$setup_ps1" > "$snippet"

    echo "== windows: Apply-ComposeSelfHostMode =="

    mkdir -p "$home_dir/.unity"
    : > "$home_dir/.unity/docker-compose.yml"

    out=$(USERPROFILE="$home_dir" pwsh -NoProfile -Command ". '$lib' -UnifyKey 'x'; Apply-ComposeSelfHostMode; Write-Output \"\$OrchestraUrl|\$(\$script:SelfHostMode)\"" | tail -1)
    check "windows: local-stack auto-detect applies with no explicit param" "$out" "http://127.0.0.1:8000/v0|True"

    out=$(USERPROFILE="$home_dir" pwsh -NoProfile -Command ". '$lib' -UnifyKey 'x' -OrchestraUrl 'https://staging.example/v0' -UnityCommsUrl 'https://staging-comms.example'; Apply-ComposeSelfHostMode; Write-Output \"\$OrchestraUrl|\$(\$script:SelfHostMode)\"" | tail -1)
    check "windows: explicit -OrchestraUrl wins over compose auto-detect" "$out" "https://staging.example/v0|False"

    rm -rf "$home_dir/.unity"

    echo "== windows: -Reconfigure URL precedence =="

    cat > "$envdir/.env" <<EOF
ORCHESTRA_URL=http://127.0.0.1:8000/v0
UNITY_COMMS_URL=http://127.0.0.1:8001
SELF_HOST=1
EOF
    out=$(USERPROFILE="$home_dir" pwsh -NoProfile -Command "
        . '$lib' -UnifyKey 'x' -OrchestraUrl 'https://staging.example/v0' -UnityCommsUrl 'https://staging-comms.example'
        \$script:AgentServiceDir = '$envdir'
        . '$snippet'
        Write-Output \"\$OrchestraUrl|\$(\$script:SelfHostMode)\"
    " | tail -1)
    check "windows: explicit params survive a poisoned .env on -Reconfigure" "$out" "https://staging.example/v0|False"

    cat > "$envdir/.env" <<EOF
ORCHESTRA_URL=https://staging.example/v0
UNITY_COMMS_URL=https://staging-comms.example
SELF_HOST=0
EOF
    out=$(USERPROFILE="$home_dir" pwsh -NoProfile -Command "
        . '$lib' -UnifyKey 'x'
        \$script:AgentServiceDir = '$envdir'
        . '$snippet'
        Write-Output \"\$OrchestraUrl|\$(\$script:SelfHostMode)\"
    " | tail -1)
    check "windows: no-param reconfigure preserves baked staging URL from .env" "$out" "https://staging.example/v0|False"

    cat > "$envdir/.env" <<EOF
ORCHESTRA_URL=http://127.0.0.1:8000/v0
UNITY_COMMS_URL=http://127.0.0.1:8001
SELF_HOST=1
EOF
    out=$(USERPROFILE="$home_dir" pwsh -NoProfile -Command "
        . '$lib' -UnifyKey 'x'
        \$script:AgentServiceDir = '$envdir'
        . '$snippet'
        Write-Output \"\$OrchestraUrl|\$(\$script:SelfHostMode)\"
    " | tail -1)
    check "windows: no-param reconfigure still auto-applies a legit self-host .env" "$out" "http://127.0.0.1:8000/v0|True"

    rm -rf "$tmpdir"
else
    echo "== windows: skipped (pwsh not installed) =="
fi

echo ""
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
