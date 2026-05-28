#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/g2ray.sh"
GITIGNORE="$ROOT_DIR/.gitignore"
DOCKERFILE="$ROOT_DIR/.devcontainer/Dockerfile"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

grep_fixed() {
    local pattern="$1" file="$2"
    grep -Fq -- "$pattern" "$file"
}

grep_regex() {
    local pattern="$1" file="$2"
    grep -Eq -- "$pattern" "$file"
}

test_wait_for_port_increment_is_set_e_safe() {
    if grep_fixed '(( i++ ))' "$SCRIPT"; then
        fail 'wait_for_port still uses post-increment, which exits under set -e when i is 0'
    fi
    grep_regex 'i=\$\(\(i \+ 1\)\)|\(\( \+\+i \)\)' "$SCRIPT" \
        || fail 'wait_for_port does not contain a set -e safe increment'
    pass 'wait_for_port increment is set -e safe'
}

test_process_management_uses_pid_file() {
    grep_fixed 'XRAY_PID_FILE=' "$SCRIPT" \
        || fail 'script does not define an Xray PID file'
    grep_fixed 'xray_pid_matches()' "$SCRIPT" \
        || fail 'script does not validate that a PID belongs to this Xray config'
    grep_fixed 'xray_pid_matches "$p"' "$SCRIPT" \
        || fail 'stop/status paths do not validate PID ownership before trusting the PID file'
    grep_fixed 'owned_xray_pids()' "$SCRIPT" \
        || fail 'script does not enumerate all owned Xray processes'
    grep_fixed 'mapfile -t owned_pids' "$SCRIPT" \
        || fail 'stop_xray does not collect every owned Xray PID before stopping'
    grep_fixed 'for p in "${owned_pids[@]}"' "$SCRIPT" \
        || fail 'stop_xray does not stop every owned Xray PID'
    grep_fixed 'if ! stop_xray; then' "$SCRIPT" \
        || fail 'start_xray does not abort when the old owned listener cannot be stopped'
    grep_fixed '> "$XRAY_PID_FILE"' "$SCRIPT" \
        || fail 'start_xray does not store the launched Xray PID'
    if grep_fixed 'pkill -x "xray"' "$SCRIPT" || grep_fixed 'pkill -9 -x "xray"' "$SCRIPT"; then
        fail 'script still kills every process named xray'
    fi
    pass 'process management is scoped through a PID file'
}

test_background_tasks_uses_owned_pid_file() {
    grep_fixed 'bg_tasks_running()' "$SCRIPT" \
        || fail 'script does not validate that the background PID belongs to a live g2ray process'
    grep_fixed 'bg_tasks_running "$p"' "$SCRIPT" \
        || fail 'start_background_tasks does not validate background PID ownership'
    pass 'background supervisor validates PID ownership'
}

test_background_tasks_require_config() {
    grep_fixed '[[ -f "$CONFIG_FILE" ]] || continue' "$SCRIPT" \
        || fail 'background loop can still start Xray before config exists'
    if grep_fixed 'start_xray; wait_for_port' "$SCRIPT"; then
        fail 'menu paths still run start_xray without handling a failed start'
    fi
    grep_fixed 'start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1' "$SCRIPT" \
        || fail 'force reconnect does not handle start_xray failure explicitly'
    pass 'background tasks skip Xray start until config exists'
}

test_port_visibility_failures_are_handled() {
    if grep -Eq '^[[:space:]]*ensure_codespace_port_public[[:space:]]*>/dev/null 2>&1[[:space:]]*$' "$SCRIPT"; then
        fail 'bare ensure_codespace_port_public call can exit under set -e without a user-facing message'
    fi
    grep_fixed 'Could not set Codespaces port' "$SCRIPT" \
        || fail 'port-public failure does not produce an actionable user-facing warning'
    pass 'port visibility failures are handled explicitly'
}

test_self_update_is_opt_in() {
    grep_fixed 'G2RAY_AUTO_UPDATE' "$SCRIPT" \
        || fail 'self-update is not controlled by an opt-in environment variable'
    grep_fixed 'bash -n "$tmp"' "$SCRIPT" \
        || fail 'self-update does not syntax-check the downloaded script before replacing itself'
    if grep_fixed 'cat "$tmp" > "$0"' "$SCRIPT"; then
        fail 'self-update still writes directly over the running script'
    fi
    pass 'self-update is opt-in'
}

test_exit_trap_preserves_failures() {
    grep_fixed 'cleanup()' "$SCRIPT" \
        || fail 'script does not define an explicit cleanup trap'
    grep_fixed 'local code=$?' "$SCRIPT" \
        || fail 'cleanup trap does not preserve the triggering exit status'
    if grep_fixed "exit 0' EXIT INT TERM" "$SCRIPT"; then
        fail 'global trap still masks failures as successful exits'
    fi
    pass 'exit trap preserves failure status'
}

test_generated_files_are_ignored() {
    [[ -f "$GITIGNORE" ]] || fail '.gitignore is missing'
    for pattern in '/data/' '/logs/' '/configs-to-copy-for-mobile.txt'; do
        grep_fixed "$pattern" "$GITIGNORE" || fail ".gitignore missing $pattern"
    done
    pass 'generated runtime files are ignored'
}

test_xray_version_can_be_pinned() {
    grep_fixed 'ARG XRAY_VERSION=' "$DOCKERFILE" \
        || fail 'Dockerfile does not expose XRAY_VERSION for reproducible builds'
    if grep_fixed 'releases/latest/download' "$DOCKERFILE"; then
        fail 'Dockerfile still downloads Xray from latest'
    fi
    pass 'Dockerfile supports pinned Xray version'
}

test_generated_links_include_domain_and_ip_variants() {
    grep_fixed 'resolve_domain_ip()' "$SCRIPT" \
        || fail 'script does not provide a resolver for the Codespaces app domain'
    grep_fixed 'resolve_domain_ips()' "$SCRIPT" \
        || fail 'script does not provide a multi-IP resolver for the Codespaces app domain'
    grep_fixed 'G2RAY_EXTRA_FALLBACK_IPS' "$SCRIPT" \
        || fail 'script does not allow manually supplied fallback IPs'
    grep_fixed 'DEFAULT_FALLBACK_IPS=' "$SCRIPT" \
        || fail 'script does not provide built-in fallback IPs for DNS-blocked networks'
    grep_fixed '20.85.77.48 20.207.70.99 20.120.56.11' "$SCRIPT" \
        || fail 'built-in fallback IPs do not prefer the current East US tunnel edges before the historical fallback'
    grep_fixed '20.120.56.11' "$SCRIPT" \
        || fail 'script does not include the historically working East US tunnel IP'
    grep_fixed 'dns.google/resolve' "$SCRIPT" \
        || fail 'script does not query Google DNS-over-HTTPS for fallback IPs'
    grep_fixed 'cloudflare-dns.com/dns-query' "$SCRIPT" \
        || fail 'script does not query Cloudflare DNS-over-HTTPS for fallback IPs'
    grep_fixed 'seen[$0]++' "$SCRIPT" \
        || fail 'script does not deduplicate fallback IP candidates'
    if grep_fixed '(\.[0-9]+){3}' "$SCRIPT"; then
        fail 'script still uses interval IPv4 regexes that can drop fallback IPs on non-GNU tools'
    fi
    grep_fixed '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' "$SCRIPT" \
        || fail 'script does not use a portable IPv4 filter for fallback IP candidates'
    grep_fixed 'generate_domain_link()' "$SCRIPT" \
        || fail 'script does not generate a domain-address link'
    grep_fixed 'generate_ip_link()' "$SCRIPT" \
        || fail 'script does not generate a resolved-IP fallback link'
    grep_fixed 'generate_ip_links()' "$SCRIPT" \
        || fail 'script does not generate multiple resolved-IP fallback links'
    grep_fixed '"$uuid" "$address" "$XRAY_PORT" "$PORT_DOMAIN" "$PORT_DOMAIN"' "$SCRIPT" \
        || fail 'IP fallback link must preserve PORT_DOMAIN as SNI and host'
    grep_fixed 'generate_link_for_address "$PORT_DOMAIN"' "$SCRIPT" \
        || fail 'domain link must use PORT_DOMAIN as address, SNI, and host'
    grep_fixed '_VLESS_IPS=$(generate_ip_links)' "$SCRIPT" \
        || fail 'display/copy paths do not use multi-IP fallback generation'
    grep_fixed 'render_config_entry()' "$SCRIPT" \
        || fail 'display does not render each config as a separate copy-safe entry'
    grep_fixed 'render_config_qr()' "$SCRIPT" \
        || fail 'display does not render a QR code for each config entry'
    grep_fixed 'qrencode -m 0 -t UTF8 "$link"' "$SCRIPT" \
        || fail 'QR renderer does not use compact terminal QR output'
    grep_fixed 'printf '\''%s\n'\'' "$link"' "$SCRIPT" \
        || fail 'config links are not printed as raw copy-ready lines'
    grep_fixed 'printf '\''%s\n'\'' "${_CONFIG_LINKS[@]}" > "$MOBILE_CONFIG_FILE"' "$SCRIPT" \
        || fail 'mobile config file is not written from the full ordered config list'
    grep_fixed 'Recommended IP link' "$SCRIPT" \
        || fail 'display does not label the primary IP config clearly'
    grep_fixed 'Domain link' "$SCRIPT" \
        || fail 'display does not label the domain config clearly'
    if grep_fixed 'qrencode -m 2 -t ANSIUTF8 "$_VLESS_PRIMARY"' "$SCRIPT"; then
        fail 'display still renders only one large QR code'
    fi
    if grep_fixed 'sed "s/^/  ${WHITE}/;s/$/${NC}/"' "$SCRIPT"; then
        fail 'display still pipes colored links through sed, which corrupts copied configs'
    fi
    if grep_fixed '"$_VLESS_IP"' "$SCRIPT"; then
        fail 'display/copy paths still reference the old singular fallback variable'
    fi
    if grep_fixed 'address=$(resolve_domain_ip "$PORT_DOMAIN")' "$SCRIPT"; then
        fail 'IP fallback still falls back to the domain when no IP resolves'
    fi
    pass 'generated links include domain and multiple IP variants'
}

test_terminal_branding_is_customized_red() {
    grep_fixed 'echo -e "${RED}${B}"' "$SCRIPT" \
        || fail 'logo banner is not rendered in red'
    grep_fixed 'Made by CodeLeafy' "$SCRIPT" \
        || fail 'logo banner no longer credits CodeLeafy'
    grep_fixed 'Customized' "$SCRIPT" \
        || fail 'logo banner does not show customized branding'
    pass 'terminal branding is red and customized'
}

test_runtime_diagnostics_logging() {
    grep_fixed 'LOG_FILE=' "$SCRIPT" \
        || fail 'script does not define an application log file'
    grep_fixed 'log_event()' "$SCRIPT" \
        || fail 'script does not define structured runtime logging'
    grep_fixed 'fingerprint_secret()' "$SCRIPT" \
        || fail 'script does not define a helper for secret-safe fingerprints'
    grep_fixed 'fingerprint_secret "$uuid"' "$SCRIPT" \
        || fail 'config generation does not log a secret-safe UUID fingerprint'
    grep_fixed 'log_event INFO "xray launched' "$SCRIPT" \
        || fail 'start_xray does not log successful launches'
    grep_fixed 'log_event INFO "force_reconnect begin' "$SCRIPT" \
        || fail 'force reconnect does not log start of reconnect flow'
    grep_fixed '[[ "$code" != "000" && "$code" != "0" ]]' "$SCRIPT" \
        || fail 'external reconnect verification does not distinguish reachable HTTP edge responses from connection failure'
    grep_fixed 'verify_external edge_reachable=' "$SCRIPT" \
        || fail 'external reconnect verification does not log whether the Codespaces edge is reachable'
    if grep_fixed 'verify_external reachable=' "$SCRIPT"; then
        fail 'external reconnect verification still uses ambiguous reachable logging'
    fi
    grep_fixed 'log_event INFO "resolver domain=' "$SCRIPT" \
        || fail 'resolver does not log resolved fallback IP candidates'
    grep_fixed 'curl_remote_ip()' "$SCRIPT" \
        || fail 'script does not use curl remote_ip as a resolver fallback'
    grep_fixed 'curl_remote_ip "$domain"' "$SCRIPT" \
        || fail 'multi-IP resolver does not include curl remote_ip fallback'
    grep_fixed 'curl_remote_ip "$domain" || true' "$SCRIPT" \
        || fail 'curl remote_ip fallback can abort resolver when no remote IP is found'
    grep_fixed 'health_probe()' "$SCRIPT" \
        || fail 'script does not define a periodic health probe'
    grep_fixed 'log_event INFO "health engine=' "$SCRIPT" \
        || fail 'health probe does not log engine/listener/public endpoint state'
    grep_fixed 'health_probe >/dev/null 2>&1' "$SCRIPT" \
        || fail 'background supervisor does not run periodic health probes'
    grep_fixed 'show_diagnostics()' "$SCRIPT" \
        || fail 'script does not provide a diagnostics view'
    grep_fixed '14) Diagnostics' "$SCRIPT" \
        || fail 'menu does not expose the diagnostics view'
    grep_fixed '14) show_diagnostics' "$SCRIPT" \
        || fail 'case statement does not route to diagnostics view'
    pass 'runtime diagnostics logging is present'
}

test_wait_for_port_increment_is_set_e_safe
test_process_management_uses_pid_file
test_background_tasks_uses_owned_pid_file
test_background_tasks_require_config
test_port_visibility_failures_are_handled
test_self_update_is_opt_in
test_exit_trap_preserves_failures
test_generated_files_are_ignored
test_xray_version_can_be_pinned
test_generated_links_include_domain_and_ip_variants
test_terminal_branding_is_customized_red
test_runtime_diagnostics_logging
