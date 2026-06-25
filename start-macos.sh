#!/bin/bash
# start-macos.sh - Single-run mitmdump proxy helper for Codex.
#
# This script has no command-line arguments. Local differences live in config:
#   - Target app: config codex_app_path, then auto-detected Codex.app
#   - Config path: config.json next to this script
#   - Install method: auto (brew -> uv -> pipx -> pip-user)
#   - CA path: ~/.mitmproxy/mitmproxy-ca-cert.pem
#   - Local capture: mitmproxy local mode for Codex process names
#
# On each run it:
#   1. Resolves the Codex app path and ensures Codex is not already running
#   2. Ensures mitmdump is available (auto-installs if missing)
#   3. Ensures mitmproxy CA exists and is trusted system-wide
#   4. Ensures the mitmproxy local redirector extension is enabled
#   5. Starts mitmdump local capture and launches Codex with system proxy bypassed
#
# See README.md for full documentation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWRITE_SCRIPT="$SCRIPT_DIR/rewrite.py"
CONFIG_FILE="$SCRIPT_DIR/config.json"

TARGET_APP="Codex.app"
CODEX_APP_PATH=""
CODEX_EXECUTABLE=""
MITM_LOCAL_SPEC="Codex (Service),Codex,codex"
NO_PROXY_LIST="*"
PROXY_BYPASS_LIST="*"
CA_DIR="${HOME}/.mitmproxy"
CA_CERT="${CA_DIR}/mitmproxy-ca-cert.pem"

info() {
    echo "$*" >&2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Argument check - no arguments accepted
# ---------------------------------------------------------------------------
if [ $# -gt 0 ]; then
    echo "Error: this script accepts no arguments." >&2
    echo "Usage: $(basename "$0")" >&2
    echo "Use $CONFIG_FILE for local settings." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: run a command with proxy env for networked installs
# ---------------------------------------------------------------------------
# Honors the local proxy convention: defaults to http://127.0.0.1:7890
# when http_proxy/HTTP_PROXY is not already set, but only inside the
# install command environment (never leaks to the rest of the script).
# ---------------------------------------------------------------------------
with_install_proxy() {
    if [ -z "${http_proxy:-}" ] && [ -z "${HTTP_PROXY:-}" ]; then
        env http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 "$@"
    else
        "$@"
    fi
}

config_value() {
    local key="$1"
    if [ ! -f "$CONFIG_FILE" ] || ! command -v plutil >/dev/null 2>&1; then
        return 0
    fi
    plutil -extract "$key" raw -o - "$CONFIG_FILE" 2>/dev/null || true
}

expand_path() {
    local path="$1"
    if [[ "$path" == "~/"* ]]; then
        path="${HOME}/${path#~/}"
    fi
    printf '%s\n' "$path"
}

executable_from_app_path() {
    local path
    path="$(expand_path "$1")"
    if [[ "$path" == *.app ]]; then
        printf '%s/Contents/MacOS/Codex\n' "$path"
    else
        printf '%s\n' "$path"
    fi
}

app_path_from_executable() {
    local path="$1"
    case "$path" in
        *.app/Contents/MacOS/*)
            printf '%s\n' "${path%%.app/Contents/MacOS/*}.app"
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

resolve_codex_app() {
    local configured candidate executable
    configured="$(config_value codex_app_path)"
    if [ -n "$configured" ]; then
        executable="$(executable_from_app_path "$configured")"
        if [ -x "$executable" ]; then
            CODEX_EXECUTABLE="$executable"
            CODEX_APP_PATH="$(app_path_from_executable "$executable")"
            TARGET_APP="$(basename "$CODEX_APP_PATH")"
            return 0
        fi
        die "configured codex_app_path is not executable: $configured"
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        executable="$(executable_from_app_path "$candidate")"
        if [ -x "$executable" ]; then
            CODEX_EXECUTABLE="$executable"
            CODEX_APP_PATH="$(app_path_from_executable "$executable")"
            TARGET_APP="$(basename "$CODEX_APP_PATH")"
            return 0
        fi
    done < <(
        {
            find /Applications "$HOME/Applications" -maxdepth 1 -name 'Codex.app' -type d -print 2>/dev/null || true
            mdfind 'kMDItemFSName == "Codex.app"' 2>/dev/null || true
        } | awk '!seen[$0]++'
    )

    die "could not find Codex.app. Set codex_app_path in $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Step 1: Ensure Codex startup state
# ---------------------------------------------------------------------------
ensure_codex_not_running() {
    info "[1/5] Codex app: $CODEX_APP_PATH"

    local process_lines
    process_lines="$(
        ps axww -o pid=,comm= | awk -v expected="$CODEX_EXECUTABLE" '
            $2 == expected {
                print
            }
        '
    )"
    if [ -n "$process_lines" ]; then
        echo "Error: ${TARGET_APP} is already running." >&2
        echo "Quit Codex first, then run this script again." >&2
        echo "Current matching processes:" >&2
        echo "$process_lines" | sed 's/^/      /' >&2
        exit 1
    else
        info "      not running"
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Ensure mitmdump is available
# ---------------------------------------------------------------------------
ensure_mitmdump() {
    if command -v mitmdump &>/dev/null; then
        info "[2/5] mitmdump: $(command -v mitmdump)"
        return 0
    fi

    info "[2/5] mitmdump: installing mitmproxy"

    local method_list=(brew uv pipx pip-user)
    local installed=false

    for method in "${method_list[@]}"; do
        case "$method" in
            brew)
                if ! command -v brew &>/dev/null; then
                    continue
                fi
                info "      using brew"
                with_install_proxy brew install mitmproxy
                installed=true
                break
                ;;
            uv)
                if ! command -v uv &>/dev/null; then
                    continue
                fi
                info "      using uv"
                with_install_proxy uv tool install mitmproxy
                installed=true
                break
                ;;
            pipx)
                if ! command -v pipx &>/dev/null; then
                    continue
                fi
                info "      using pipx"
                with_install_proxy pipx install mitmproxy
                installed=true
                break
                ;;
            pip-user)
                if ! command -v python3 &>/dev/null; then
                    continue
                fi
                info "      using python3 -m pip"
                with_install_proxy python3 -m pip install --user mitmproxy
                installed=true
                break
                ;;
        esac
    done

    if ! $installed; then
        echo "Error: could not install mitmproxy. No suitable package manager found." >&2
        echo "Install one of: Homebrew, uv, pipx, or ensure python3+pip are available." >&2
        exit 1
    fi

    # Verify installation succeeded
    if ! command -v mitmdump &>/dev/null; then
        echo "Error: mitmdump still not found after installation." >&2
        echo "Check your PATH or install manually." >&2
        exit 1
    fi

    info "      installed: $(command -v mitmdump)"
}

# ---------------------------------------------------------------------------
# Step 3: Ensure mitmproxy CA exists and is trusted system-wide
# ---------------------------------------------------------------------------
ensure_ca() {
    info "[3/5] mitmproxy CA"

    # --- Phase A: Ensure CA file exists ---
    if [ ! -f "$CA_CERT" ]; then
        info "      generating CA"

        # Start mitmdump briefly - CA files are created on first startup.
        # Use a throwaway port with no proxy interception.
        mitmdump --listen-port 22339 --set block_global=false &
        local mitm_pid=$!

        # Clean up background mitmdump on script exit
        _ca_cleanup() {
            kill "$mitm_pid" 2>/dev/null || true
            wait "$mitm_pid" 2>/dev/null || true
        }
        trap _ca_cleanup EXIT

        # Poll for up to 10 seconds
        local waited=0
        while [ ! -f "$CA_CERT" ] && [ $waited -lt 10 ]; do
            sleep 1
            waited=$((waited + 1))
        done

        # Clean up background process
        _ca_cleanup
        trap - EXIT

        if [ -f "$CA_CERT" ]; then
            info "      generated: $CA_CERT"
        else
            echo "Error: CA generation timed out after 10 seconds." >&2
            echo "CA file is missing at $CA_CERT and cannot be created." >&2
            echo "Try running mitmdump once manually to generate the CA, then re-run." >&2
            return 1
        fi
    else
        info "      exists: $CA_CERT"
    fi

    # --- Phase B: Ensure CA is trusted system-wide ---
    if security verify-cert -c "$CA_CERT" &>/dev/null; then
        info "      trusted"
    else
        info "      trusting with sudo security add-trusted-cert"
        sudo security add-trusted-cert -d -r trustRoot \
            -k /Library/Keychains/System.keychain \
            "$CA_CERT"
        info "      trusted"
    fi
}

# ---------------------------------------------------------------------------
# Step 4: Ensure mitmproxy local redirector is enabled
# ---------------------------------------------------------------------------
ensure_local_redirector_enabled() {
    info "[4/5] local redirector"

    if systemextensionsctl list 2>/dev/null \
        | grep -F "org.mitmproxy.macos-redirector.network-extension" \
        | grep -Fq "[activated enabled]"; then
        info "      enabled"
        return 0
    fi

    echo "Error: Mitmproxy Redirector network extension is not enabled." >&2
    echo "Enable it in System Settings -> General -> Login Items & Extensions -> Mitmproxy Redirector -> Network Extension." >&2
    echo "Then re-run this script." >&2
    exit 1
}

find_existing_capture_pids() {
    ps axww -o pid=,command= | awk -v script="$REWRITE_SCRIPT" -v current="$$" '
        $1 != current && /mitmdump/ && index($0, script) && $0 !~ /awk -v script/ {
            print $1
        }
    '
}

stop_existing_capture() {
    local pids pid still_running failed
    pids="$(find_existing_capture_pids)"
    [ -n "$pids" ] || return 0

    info "      stopping previous mitmdump capture: $(echo "$pids" | tr '\n' ' ')"
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null || true
    done <<< "$pids"

    sleep 1
    still_running=""
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            still_running="${still_running}${pid} "
        fi
    done <<< "$pids"

    [ -n "$still_running" ] || return 0
    sleep 1
    failed=""
    for pid in $still_running; do
        if kill -0 "$pid" 2>/dev/null; then
            failed="${failed}${pid} "
        fi
    done
    [ -z "$failed" ] || die "could not stop previous mitmdump capture: $failed"
}

start_proxy_and_open_codex() {
    info "[5/5] starting capture"
    info "      local spec: $MITM_LOCAL_SPEC"
    info "      config: $CONFIG_FILE"

    stop_existing_capture
    export MITM_REWRITE_CONFIG="$CONFIG_FILE"

    local mitmdump_args=(mitmdump)
    mitmdump_args+=(
        --mode "local:${MITM_LOCAL_SPEC}"
        -s "$REWRITE_SCRIPT"
        --flow-detail 0
        --set upstream_cert=false
        --set termlog_verbosity=error
    )

    "${mitmdump_args[@]}" &
    local mitm_pid=$!

    cleanup_capture() {
        kill "$mitm_pid" 2>/dev/null || true
        wait "$mitm_pid" 2>/dev/null || true
    }
    trap cleanup_capture INT TERM EXIT

    sleep 2
    if ! kill -0 "$mitm_pid" 2>/dev/null; then
        wait "$mitm_pid"
        trap - INT TERM EXIT
        exit 1
    fi

    info "      launching $TARGET_APP"
    (
        unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
        export NO_PROXY="$NO_PROXY_LIST"
        export no_proxy="$NO_PROXY_LIST"
        exec "$CODEX_EXECUTABLE" \
            --no-proxy-server \
            --proxy-bypass-list="$PROXY_BYPASS_LIST"
    ) &

    wait "$mitm_pid"
    trap - INT TERM EXIT
}

# ---------------------------------------------------------------------------
# Pre-flight: verify required files exist
# ---------------------------------------------------------------------------
if [ ! -f "$REWRITE_SCRIPT" ]; then
    echo "Error: rewrite script not found at $REWRITE_SCRIPT" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Warning: no rewrite config at $CONFIG_FILE - running pass-through." >&2
fi

# ---------------------------------------------------------------------------
# Run: resolve app -> ensure clean startup -> ensure mitmdump -> ensure CA -> ensure redirector -> start capture
# ---------------------------------------------------------------------------
resolve_codex_app
ensure_codex_not_running
ensure_mitmdump
ensure_ca
ensure_local_redirector_enabled
start_proxy_and_open_codex
