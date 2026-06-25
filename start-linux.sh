#!/usr/bin/env bash
# start-linux.sh - Single-run mitmdump local capture helper for Codex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWRITE_SCRIPT="$SCRIPT_DIR/rewrite.py"
CONFIG_FILE="$SCRIPT_DIR/config.json"

TARGET_APP="Codex"
CODEX_APP_PATH=""
CODEX_EXECUTABLE=""
MITMDUMP_CMD=""
MITM_LOCAL_SPEC="Codex,codex"
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

if [ $# -gt 0 ]; then
    echo "Error: this script accepts no arguments." >&2
    echo "Usage: $(basename "$0")" >&2
    echo "Use $CONFIG_FILE for local settings." >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    die "do not run this script with sudo; run it as the desktop user"
fi

with_install_proxy() {
    if [ -z "${http_proxy:-}" ] && [ -z "${HTTP_PROXY:-}" ]; then
        env http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 "$@"
    else
        "$@"
    fi
}

config_value() {
    local key="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); value=data.get(sys.argv[2], ""); print(value if isinstance(value, str) else "")' "$CONFIG_FILE" "$key" 2>/dev/null || true
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg key "$key" '.[$key] // empty' "$CONFIG_FILE" 2>/dev/null || true
    fi
}

expand_path() {
    local path="$1"
    if [[ "$path" == "~/"* ]]; then
        path="${HOME}/${path#~/}"
    fi
    printf '%s\n' "$path"
}

resolve_codex_app() {
    local configured candidate
    configured="$(config_value codex_app_path)"
    if [ -n "$configured" ]; then
        candidate="$(expand_path "$configured")"
        if [ -x "$candidate" ]; then
            CODEX_EXECUTABLE="$candidate"
            CODEX_APP_PATH="$candidate"
            TARGET_APP="$(basename "$candidate")"
            return 0
        fi
        die "configured codex_app_path is not executable: $configured"
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if [ -x "$candidate" ]; then
            CODEX_EXECUTABLE="$candidate"
            CODEX_APP_PATH="$candidate"
            TARGET_APP="$(basename "$candidate")"
            return 0
        fi
    done < <(
        {
            printf '%s\n' \
                "/opt/Codex/codex" \
                "/opt/Codex/Codex" \
                "/usr/local/bin/codex-desktop" \
                "/usr/bin/codex-desktop" \
                "$HOME/.local/bin/codex-desktop"
            find "$HOME/Applications" "$HOME/Downloads" /opt -maxdepth 3 \
                \( -iname 'Codex*.AppImage' -o -path '*/Codex/codex' -o -path '*/Codex/Codex' \) \
                -type f -perm -111 -print 2>/dev/null || true
        } | awk '!seen[$0]++'
    )

    die "could not find Codex desktop app. Set codex_app_path in $CONFIG_FILE"
}

ensure_codex_not_running() {
    info "[1/5] Codex app: $CODEX_APP_PATH"

    local process_lines
    process_lines="$(
        ps axww -o pid=,args= | awk -v expected="$CODEX_EXECUTABLE" '
            index($0, expected) {
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
    fi

    info "      not running"
}

find_mitmdump() {
    if command -v mitmdump >/dev/null 2>&1; then
        command -v mitmdump
        return 0
    fi
    if [ -x "$HOME/.local/bin/mitmdump" ]; then
        printf '%s\n' "$HOME/.local/bin/mitmdump"
        return 0
    fi
    return 1
}

ensure_mitmdump() {
    if MITMDUMP_CMD="$(find_mitmdump)"; then
        info "[2/5] mitmdump: $MITMDUMP_CMD"
        return 0
    fi

    info "[2/5] mitmdump: installing mitmproxy"

    local installed=false
    if command -v brew >/dev/null 2>&1; then
        info "      using brew"
        with_install_proxy brew install mitmproxy
        installed=true
    elif command -v uv >/dev/null 2>&1; then
        info "      using uv"
        with_install_proxy uv tool install mitmproxy
        installed=true
    elif command -v pipx >/dev/null 2>&1; then
        info "      using pipx"
        with_install_proxy pipx install mitmproxy
        installed=true
    elif command -v python3 >/dev/null 2>&1; then
        info "      using python3 -m pip"
        with_install_proxy python3 -m pip install --user mitmproxy
        installed=true
    fi

    if ! $installed; then
        die "could not install mitmproxy. Install brew, uv, pipx, or python3+pip first."
    fi

    if MITMDUMP_CMD="$(find_mitmdump)"; then
        info "      installed: $MITMDUMP_CMD"
        return 0
    fi

    die "mitmdump still not found after installation. Check PATH."
}

generate_ca_if_needed() {
    if [ -f "$CA_CERT" ]; then
        info "      exists: $CA_CERT"
        return 0
    fi

    info "      generating CA"
    "$MITMDUMP_CMD" --listen-port 22339 --set block_global=false --flow-detail 0 --set termlog_verbosity=error >/dev/null 2>&1 &
    local mitm_pid=$!

    local waited=0
    while [ ! -f "$CA_CERT" ] && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    kill "$mitm_pid" 2>/dev/null || true
    wait "$mitm_pid" 2>/dev/null || true

    [ -f "$CA_CERT" ] || die "CA generation timed out: $CA_CERT"
    info "      generated: $CA_CERT"
}

system_ca_is_trusted() {
    command -v openssl >/dev/null 2>&1 || return 1
    openssl verify -CApath /etc/ssl/certs "$CA_CERT" >/dev/null 2>&1
}

trust_system_ca() {
    if system_ca_is_trusted; then
        info "      system trust: ok"
        return 0
    fi

    command -v sudo >/dev/null 2>&1 || die "sudo is required to trust the mitmproxy CA on Linux"

    if command -v update-ca-certificates >/dev/null 2>&1 && [ -d /usr/local/share/ca-certificates ]; then
        info "      system trust: update-ca-certificates"
        sudo install -m 0644 "$CA_CERT" /usr/local/share/ca-certificates/mitmproxy-ca-cert.crt
        sudo update-ca-certificates >/dev/null
        return 0
    fi

    if command -v update-ca-trust >/dev/null 2>&1 && [ -d /etc/pki/ca-trust/source/anchors ]; then
        info "      system trust: update-ca-trust"
        sudo install -m 0644 "$CA_CERT" /etc/pki/ca-trust/source/anchors/mitmproxy-ca-cert.pem
        sudo update-ca-trust extract >/dev/null
        return 0
    fi

    if command -v trust >/dev/null 2>&1; then
        info "      system trust: p11-kit trust"
        sudo trust anchor --store "$CA_CERT" >/dev/null
        return 0
    fi

    die "no supported Linux CA trust tool found"
}

trust_nss_ca_if_possible() {
    if ! command -v certutil >/dev/null 2>&1; then
        info "      nss trust: skipped (certutil not found)"
        return 0
    fi

    local nssdb="$HOME/.pki/nssdb"
    mkdir -p "$nssdb"
    if [ ! -f "$nssdb/cert9.db" ]; then
        certutil -N -d "sql:$nssdb" --empty-password >/dev/null 2>&1 || true
    fi

    if certutil -L -d "sql:$nssdb" -n "mitmproxy" >/dev/null 2>&1; then
        info "      nss trust: ok"
        return 0
    fi

    certutil -A -d "sql:$nssdb" -n "mitmproxy" -t "C,," -i "$CA_CERT"
    info "      nss trust: added"
}

ensure_ca() {
    info "[3/5] mitmproxy CA"
    generate_ca_if_needed
    trust_system_ca
    trust_nss_ca_if_possible
}

ensure_local_redirector_ready() {
    info "[4/5] local redirector"

    if ! command -v timeout >/dev/null 2>&1; then
        info "      probe skipped: timeout not found"
        return 0
    fi

    local log_file
    log_file="$(mktemp)"
    set +e
    timeout 5 "$MITMDUMP_CMD" --mode "local:codex-local-probe-never-match" --flow-detail 0 --set termlog_verbosity=error >"$log_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 124 ]; then
        rm -f "$log_file"
        info "      ready"
        return 0
    fi

    echo "Error: mitmproxy local redirector probe failed." >&2
    sed 's/^/      /' "$log_file" >&2
    rm -f "$log_file"
    exit 1
}

ensure_no_existing_capture() {
    local existing_capture
    existing_capture="$(
        ps axww -o pid=,args= | awk -v script="$REWRITE_SCRIPT" '
            /mitmdump/ && index($0, script) {
                print
            }
        '
    )"
    if [ -n "$existing_capture" ]; then
        echo "Error: another mitmdump Codex capture is already running." >&2
        echo "$existing_capture" | sed 's/^/      /' >&2
        exit 1
    fi
}

start_proxy_and_open_codex() {
    info "[5/5] starting capture"
    info "      local spec: $MITM_LOCAL_SPEC"
    info "      config: $CONFIG_FILE"

    ensure_no_existing_capture
    export MITM_REWRITE_CONFIG="$CONFIG_FILE"

    "$MITMDUMP_CMD" \
        --mode "local:${MITM_LOCAL_SPEC}" \
        -s "$REWRITE_SCRIPT" \
        --flow-detail 0 \
        --set upstream_cert=false \
        --set termlog_verbosity=error &
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

[ -f "$REWRITE_SCRIPT" ] || die "rewrite script not found at $REWRITE_SCRIPT"
[ -f "$CONFIG_FILE" ] || info "Warning: no rewrite config at $CONFIG_FILE - running pass-through."

resolve_codex_app
ensure_codex_not_running
ensure_mitmdump
ensure_ca
ensure_local_redirector_ready
start_proxy_and_open_codex
