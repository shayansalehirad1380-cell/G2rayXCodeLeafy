#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/g2ray.sh"
GITIGNORE="$ROOT_DIR/.gitignore"
GITATTRIBUTES="$ROOT_DIR/.gitattributes"
README="$ROOT_DIR/README.md"
CONFIGS="$ROOT_DIR/configs.txt"
DOCKERFILE="$ROOT_DIR/.devcontainer/Dockerfile"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/static-tests.yml"
REOPEN_SCRIPT="$ROOT_DIR/scripts/reopen-codespace.ps1"

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
    grep_fixed 'BG_TASKS_LOCK_DIR=' "$SCRIPT" \
        || fail 'background supervisor startup is not protected by an atomic lock'
    grep_fixed 'BG_TASKS_TOKEN_FILE=' "$SCRIPT" \
        || fail 'background supervisor does not persist an ownership token'
    grep_fixed 'G2RAY_BG_TASK_TOKEN=' "$SCRIPT" \
        || fail 'background supervisor process is not tagged with an ownership token'
    grep_fixed 'export G2RAY_BG_TASK_TOKEN="$token"' "$SCRIPT" \
        || fail 'background supervisor ownership token is not exported into the child environment'
    grep_fixed '/proc/$p/environ' "$SCRIPT" \
        || fail 'background supervisor ownership is not verified against the live process environment'
    grep_fixed 'background_supervisor_recent_heartbeat()' "$SCRIPT" \
        || fail 'background supervisor diagnostics cannot recognize a fresh heartbeat'
    grep_fixed 'running="heartbeat"' "$SCRIPT" \
        || fail 'background supervisor diagnostics cannot distinguish a live heartbeat from a dead supervisor'
    if grep_fixed 'grep -Fq "g2ray.sh"' "$SCRIPT"; then
        fail 'background supervisor ownership still matches any process whose args contain g2ray.sh'
    fi
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
    for pattern in '/data/' '/logs/' '/configs-to-copy-for-mobile.txt' '/configs-subscription-base64.txt'; do
        grep_fixed "$pattern" "$GITIGNORE" || fail ".gitignore missing $pattern"
    done
    for pattern in '/configs-to-copy-for-mobile.txt.*' '/configs-subscription-base64.txt.*'; do
        grep_fixed "$pattern" "$GITIGNORE" || fail ".gitignore missing atomic temp pattern $pattern"
    done
    pass 'generated runtime files are ignored'
}

test_shell_files_are_lf_normalized() {
    [[ -f "$GITATTRIBUTES" ]] || fail '.gitattributes is missing'
    grep_fixed '*.sh text eol=lf' "$GITATTRIBUTES" \
        || fail '.gitattributes does not force shell scripts to LF'
    grep_fixed '*.ps1 text eol=lf' "$GITATTRIBUTES" \
        || fail '.gitattributes does not force PowerShell helper scripts to LF'
    grep_fixed 'tests/*.sh text eol=lf' "$GITATTRIBUTES" \
        || fail '.gitattributes does not force test shell scripts to LF'
    pass 'shell files are LF-normalized for Linux Bash'
}

test_panel_script_is_executable() {
    git -C "$ROOT_DIR" ls-files --stage -- g2ray.sh | grep -q '^100755 ' \
        || fail 'g2ray.sh is not tracked as executable, so ./g2ray.sh fails after git pull in Linux Codespaces'
    pass 'panel script is tracked executable'
}

test_xray_version_can_be_pinned() {
    grep_fixed 'ARG XRAY_VERSION=' "$DOCKERFILE" \
        || fail 'Dockerfile does not expose XRAY_VERSION for reproducible builds'
    if grep_fixed 'releases/latest/download' "$DOCKERFILE"; then
        fail 'Dockerfile still downloads Xray from latest'
    fi
    grep_fixed 'Xray-linux-64.zip.dgst' "$DOCKERFILE" \
        || fail 'Dockerfile does not download Xray digest metadata'
    grep_fixed 'sha256sum -c -' "$DOCKERFILE" \
        || fail 'Dockerfile does not verify Xray zip checksum before installing'
    pass 'Dockerfile supports pinned Xray version'
}

test_generated_config_uses_resilient_dns_fallback() {
    grep_fixed '"enableParallelQuery": true' "$SCRIPT" \
        || fail 'generated Xray DNS config does not race equivalent fallback resolvers'
    grep_fixed '"disableFallback": false' "$SCRIPT" \
        || fail 'generated Xray DNS config does not explicitly keep fallback enabled'
    grep_fixed '"disableFallbackIfMatch": false' "$SCRIPT" \
        || fail 'generated Xray DNS config could stop fallback after a matched resolver times out'
    grep_fixed '"https+local://1.1.1.1/dns-query"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not use local-mode Cloudflare DoH'
    grep_fixed '"https+local://dns.google/dns-query"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not include Google DoH fallback'
    grep_fixed '"address": "1.0.0.1"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not include Cloudflare UDP fallback'
    grep_fixed '"address": "8.8.4.4"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not include Google UDP fallback'
    grep_fixed '"timeoutMs": 2500' "$SCRIPT" \
        || fail 'generated Xray DNS config does not bound DoH resolver wait time'
    grep_fixed 'upgrade_config_dns()' "$SCRIPT" \
        || fail 'script does not provide an in-place DNS migration for existing configs'
    grep_fixed '.dns = {' "$SCRIPT" \
        || fail 'existing config DNS migration does not replace the dns object'
    grep_fixed 'upgrade_config_dns >/dev/null 2>&1 || true' "$SCRIPT" \
        || fail 'start path does not apply DNS migration before launching Xray'
    grep_fixed 'config_dns refreshed' "$SCRIPT" \
        || fail 'DNS migration does not log when it refreshes an existing config'
    if grep_fixed '"domains": ["geosite:geolocation-!cn"]' "$SCRIPT"; then
        fail 'generated Xray DNS config still pins most lookups to a single domain-matched resolver before fallback'
    fi
    pass 'generated Xray config uses resilient DNS fallback'
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
    grep_fixed '"$uuid" "$address" "$CODESPACES_EDGE_PORT" "$PORT_DOMAIN" "$PORT_DOMAIN"' "$SCRIPT" \
        || fail 'IP fallback link must preserve PORT_DOMAIN as SNI and host'
    grep_fixed 'generate_link_for_address "$PORT_DOMAIN"' "$SCRIPT" \
        || fail 'domain link must use PORT_DOMAIN as address, SNI, and host'
    grep_fixed '_VLESS_IPS=$(generate_ip_links)' "$SCRIPT" \
        || fail 'display/copy paths do not use multi-IP fallback generation'
    grep_fixed 'render_config_entry()' "$SCRIPT" \
        || fail 'display does not render each config as a separate copy-safe entry'
    grep_fixed 'render_config_qr()' "$SCRIPT" \
        || fail 'display does not render a QR code for each config entry'
    grep_fixed 'G2RAY_QR_MODE' "$SCRIPT" \
        || fail 'QR display mode is not configurable'
    grep_fixed 'local show_qr="${4:-false}"' "$SCRIPT" \
        || fail 'config entry renderer cannot hide non-primary QR codes'
    grep_fixed '[[ "$show_qr" == true ]]' "$SCRIPT" \
        || fail 'config entry renderer does not conditionally show QR codes'
    grep_fixed '_QR_MODE="${G2RAY_QR_MODE:-recommended}"' "$SCRIPT" \
        || fail 'config display does not default to recommended-only QR mode'
    grep_fixed '[[ "$_QR_MODE" == "all" || ( "$_QR_MODE" != "none" && $_INDEX -eq 1 ) ]]' "$SCRIPT" \
        || fail 'config display does not limit default QR rendering to the first recommended config'
    grep_fixed 'qrencode -m 0 -t UTF8 "$link"' "$SCRIPT" \
        || fail 'QR renderer does not use compact terminal QR output'
    grep_fixed 'printf '\''%s\n'\'' "$link"' "$SCRIPT" \
        || fail 'config links are not printed as raw copy-ready lines'
    grep_fixed 'write_config_exports_from_links()' "$SCRIPT" \
        || fail 'script does not provide an export writer for an existing displayed link list'
    grep_fixed 'write_config_exports_from_links "${_CONFIG_LINKS[@]}"' "$SCRIPT" \
        || fail 'display path does not export the exact links it shows'
    if grep_fixed 'printf '\''%s\n'\'' "${_CONFIG_LINKS[@]}" > "$MOBILE_CONFIG_FILE"' "$SCRIPT"; then
        fail 'display path still writes mobile config directly before recomputing exports'
    fi
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
    grep_fixed 'local no_prompt="${1:-}" failed=0' "$SCRIPT" \
        || fail 'force reconnect does not track failure state'
    grep_fixed 'if stop_xray >/dev/null 2>&1; then' "$SCRIPT" \
        || fail 'force reconnect does not handle stop_xray failure explicitly'
    grep_fixed 'return "$failed"' "$SCRIPT" \
        || fail 'force reconnect does not return failure to the watchdog'
    if grep_fixed 'verify_external reachable=' "$SCRIPT"; then
        fail 'external reconnect verification still uses ambiguous reachable logging'
    fi
    grep_fixed 'fallback_candidates=' "$SCRIPT" \
        || fail 'resolver does not log mixed fallback IP candidates clearly'
    grep_fixed 'Fallback IP Candidates' "$SCRIPT" \
        || fail 'diagnostics still labels mixed fallback candidates as purely resolved IPs'
    grep_fixed 'includes resolved, manual, and built-in fallbacks' "$SCRIPT" \
        || fail 'diagnostics does not disclose that fallback IPs may include built-in candidates'
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
    grep_fixed 'refresh_config_exports()' "$SCRIPT" \
        || fail 'script does not define a config export refresher'
    grep_fixed 'SUBSCRIPTION_FILE=' "$SCRIPT" \
        || fail 'script does not define a base64 subscription export file'
    grep_fixed 'generate_ordered_links()' "$SCRIPT" \
        || fail 'script does not generate a stable ordered failover config list'
    grep_fixed 'base64 | tr -d' "$SCRIPT" \
        || fail 'script does not generate a single-line base64 subscription export'
    grep_fixed 'refresh_config_exports >/dev/null 2>&1' "$SCRIPT" \
        || fail 'background supervisor does not refresh exported fallback configs'
    grep_fixed 'self_heal_once()' "$SCRIPT" \
        || fail 'script does not define a self-healing watchdog pass'
    grep_fixed 'self_heal_once >/dev/null 2>&1' "$SCRIPT" \
        || fail 'background supervisor does not run the self-healing watchdog'
    grep_fixed 'reason=listener_closed' "$SCRIPT" \
        || fail 'watchdog does not restart when the listener is closed'
    grep_fixed 'reason=xray_stopped' "$SCRIPT" \
        || fail 'watchdog does not restart when Xray is stopped'
    grep_fixed 'edge_unreachable' "$SCRIPT" \
        || fail 'watchdog does not detect an unreachable Codespaces edge'
    grep_fixed 'force_reconnect --no-prompt' "$SCRIPT" \
        || fail 'watchdog does not force reconnect when the Codespaces edge is unreachable'
    grep_fixed 'show_diagnostics()' "$SCRIPT" \
        || fail 'script does not provide a diagnostics view'
    grep_fixed '14) Diagnostics' "$SCRIPT" \
        || fail 'menu does not expose the diagnostics view'
    grep_fixed '14) show_diagnostics' "$SCRIPT" \
        || fail 'case statement does not route to diagnostics view'
    pass 'runtime diagnostics logging is present'
}

test_runtime_control_paths_are_hardened() {
    grep_fixed 'XRAY_PORT="${XRAY_PORT:-443}"' "$SCRIPT" \
        || fail 'XRAY_PORT documentation says it is configurable, but script still hard-codes 443'
    grep_fixed 'valid_codespace_name()' "$SCRIPT" \
        || fail 'codespace detection does not validate candidate names'
    grep_fixed '[[ "$name" != "null" ]]' "$SCRIPT" \
        || fail 'codespace detection can accept literal null as a real name'
    grep_fixed 'xray_listener_ready()' "$SCRIPT" \
        || fail 'engine readiness does not verify the Xray/XHTTP listener, only an open port'
    grep_fixed 'while ! xray_listener_ready && (( i < 15 )); do' "$SCRIPT" \
        || fail 'wait_for_port still succeeds on any listener bound to the port'
    grep_fixed 'ensure_runtime_ready "silent_start" >/dev/null 2>&1 || true' "$SCRIPT" \
        || fail '--silent-start does not use the non-fatal health-gated startup path'
    grep_fixed 'if stop_xray; then' "$SCRIPT" \
        || fail 'interactive Stop Engine path does not handle stop_xray failure'
    pass 'runtime control paths are hardened'
}

test_startup_does_not_reconnect_healthy_runtime() {
    grep_fixed 'ensure_runtime_ready()' "$SCRIPT" \
        || fail 'script does not provide a health-gated startup path'
    grep_fixed 'runtime_ready reason=${reason} engine=running' "$SCRIPT" \
        || fail 'startup readiness path does not log when it reuses a healthy engine'
    grep_fixed 'action=skip_reconnect' "$SCRIPT" \
        || fail 'startup readiness path does not explicitly skip reconnects when healthy'
    if awk '
        /if \[\[ "\$\{1:-\}" == "--silent-start" \]\]; then/ { in_block=1 }
        in_block && /^[[:space:]]*fi[[:space:]]*$/ { exit }
        in_block && /stop_xray/ { bad=1; exit }
        END { exit bad ? 0 : 1 }
    ' "$SCRIPT"; then
        fail '--silent-start still stops Xray unconditionally'
    fi
    grep_fixed 'ensure_runtime_ready "interactive_attach" >/dev/null 2>&1 || true' "$SCRIPT" \
        || fail 'interactive attach does not use health-gated startup'
    if grep_fixed 'force_reconnect --no-prompt || true' "$SCRIPT"; then
        fail 'interactive attach still force-reconnects existing configs'
    fi
    pass 'startup paths do not reconnect a healthy runtime'
}

test_self_heal_uses_reconnect_backoff() {
    grep_fixed 'EDGE_BAD_COUNT_FILE=' "$SCRIPT" \
        || fail 'self-heal does not persist edge failure streaks'
    grep_fixed 'EDGE_RECONNECT_STAMP_FILE=' "$SCRIPT" \
        || fail 'self-heal does not persist reconnect cooldown timestamps'
    grep_fixed 'SELF_HEAL_RECONNECT_COOLDOWN_SEC=' "$SCRIPT" \
        || fail 'self-heal reconnect cooldown is not configurable'
    grep_fixed 'edge_unreachable code=${code:-0} bad_count=${bad_count} action=observe' "$SCRIPT" \
        || fail 'self-heal does not observe transient edge failures before reconnecting'
    grep_fixed 'edge_unreachable code=${code:-0} bad_count=${bad_count} action=force_reconnect' "$SCRIPT" \
        || fail 'self-heal does not log thresholded force reconnects'
    if grep_fixed 'edge_unreachable code=${code:-0} action=force_reconnect' "$SCRIPT"; then
        fail 'self-heal still force-reconnects on a single edge failure'
    fi
    pass 'self-heal reconnects are thresholded and cooled down'
}

test_probe_and_gh_commands_are_bounded() {
    grep_fixed 'curl_http_code()' "$SCRIPT" \
        || fail 'script has no helper to normalize curl transport failures'
    grep_fixed 'printf '\''0'\''' "$SCRIPT" \
        || fail 'curl_http_code does not normalize failed transports to a single 0'
    if grep_fixed 'w "%{http_code}" "https://${PORT_DOMAIN}" 2>/dev/null || echo "0"' "$SCRIPT"; then
        fail 'raw curl http_code probes can still emit 0000 on transport failure'
    fi
    grep_fixed 'run_gh()' "$SCRIPT" \
        || fail 'script has no bounded gh helper'
    grep_fixed 'timeout "${G2RAY_GH_TIMEOUT_SEC:-10}" gh' "$SCRIPT" \
        || fail 'gh helper does not bound GitHub CLI calls with timeout'
    grep_fixed 'run_gh codespace list --limit 1 --json name --jq' "$SCRIPT" \
        || fail 'codespace name detection still bypasses the bounded gh helper'
    grep_fixed 'run_gh codespace ports visibility "${XRAY_PORT}:public" -c "$CODESPACE_NAME"' "$SCRIPT" \
        || fail 'port visibility still bypasses the bounded gh helper'
    grep_fixed 'run_gh codespace ports -c "$CODESPACE_NAME"' "$SCRIPT" \
        || fail 'diagnostics port query still bypasses the bounded gh helper'
    pass 'curl probes and gh calls are bounded'
}

test_diagnostics_show_latency_and_supervisor_state() {
    grep_fixed 'xhttp_probe_metrics()' "$SCRIPT" \
        || fail 'diagnostics cannot measure XHTTP probe latency'
    grep_fixed 'CODESPACES_EDGE_PORT="${G2RAY_CODESPACES_EDGE_PORT:-443}"' "$SCRIPT" \
        || fail 'script does not define the external Codespaces HTTPS edge port separately from the internal Xray port'
    grep_fixed 'url="https://${PORT_DOMAIN}:${CODESPACES_EDGE_PORT}${path}"' "$SCRIPT" \
        || fail 'external XHTTP probes do not include the Codespaces edge port in the URL, so fallback IP probes can test the wrong route'
    grep_fixed '--resolve "${PORT_DOMAIN}:${CODESPACES_EDGE_PORT}:${address}"' "$SCRIPT" \
        || fail 'fallback XHTTP probes do not bind --resolve to the same edge port used by the URL'
    grep_fixed 'xhttp_probe_ms=' "$SCRIPT" \
        || fail 'health/reconnect logs do not include XHTTP probe latency'
    grep_fixed 'BG_TASKS_HEARTBEAT_FILE=' "$SCRIPT" \
        || fail 'background supervisor heartbeat file is missing'
    grep_fixed 'background_supervisor_status()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize background supervisor state'
    grep_fixed 'Background Supervisor' "$SCRIPT" \
        || fail 'diagnostics do not show background supervisor state'
    grep_fixed 'Fallback Route Probes' "$SCRIPT" \
        || fail 'diagnostics do not probe fallback route latency'
    grep_fixed 'ms' "$SCRIPT" \
        || fail 'diagnostics do not display latency in milliseconds'
    pass 'diagnostics show probe latency and supervisor state'
}

test_diagnostics_show_self_heal_state() {
    grep_fixed 'self_heal_state_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize self-heal counters'
    grep_fixed 'Self-Heal State' "$SCRIPT" \
        || fail 'diagnostics do not show self-heal state'
    grep_fixed 'route_bad=' "$SCRIPT" \
        || fail 'self-heal summary omits route failure streak'
    grep_fixed 'edge_bad=' "$SCRIPT" \
        || fail 'self-heal summary omits edge failure streak'
    grep_fixed 'cooldown_remaining=' "$SCRIPT" \
        || fail 'self-heal summary omits reconnect cooldown'
    pass 'diagnostics show self-heal state'
}

test_diagnostics_show_last_known_state() {
    grep_fixed 'last_known_state_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize the last known failure/repair/export state'
    grep_fixed 'Last Known State' "$SCRIPT" \
        || fail 'diagnostics do not show the last known state section'
    grep_fixed 'Last failure :' "$SCRIPT" \
        || fail 'last known state omits the last failure line'
    grep_fixed 'Last repair  :' "$SCRIPT" \
        || fail 'last known state omits the last repair line'
    grep_fixed 'Last export  :' "$SCRIPT" \
        || fail 'last known state omits the last export line'
    grep_fixed 'route_unusable|edge_unreachable|engine_not_ready|started_route_unusable|started_route_still_unusable|port_public_failed|launch_failed|timeout|failed' "$SCRIPT" \
        || fail 'last known failure summary does not include known failure markers'
    pass 'diagnostics show last known state'
}

test_diagnostics_show_resume_gap_state() {
    grep_fixed 'RESUME_GAP_FILE=' "$SCRIPT" \
        || fail 'script does not persist detected Codespaces resume gaps'
    grep_fixed 'record_resume_gap()' "$SCRIPT" \
        || fail 'script cannot record a supervisor heartbeat gap on startup'
    grep_fixed 'resume_gap_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize the last resume gap'
    grep_fixed 'Resume Gap' "$SCRIPT" \
        || fail 'diagnostics do not show resume gap state'
    grep_fixed 'resume_gap reason=${reason}' "$SCRIPT" \
        || fail 'resume gap detection does not log the startup reason'
    grep_fixed 'record_resume_gap "$reason"' "$SCRIPT" \
        || fail 'runtime readiness does not record resume gaps before healing'
    grep_fixed 'record_resume_gap "interactive_attach"' "$SCRIPT" \
        || fail 'interactive attach can refresh the heartbeat before recording resume gaps'
    pass 'diagnostics show resume gap state'
}

test_local_reopen_helper_is_documented() {
    [[ -f "$REOPEN_SCRIPT" ]] || fail 'local Codespace reopen helper is missing'
    grep_fixed '--method POST "/user/codespaces/$Name/start"' "$REOPEN_SCRIPT" \
        || fail 'reopen helper does not use the official Codespaces start API'
    grep_fixed 'HTTP 402' "$REOPEN_SCRIPT" \
        || fail 'reopen helper does not explain quota/payment blocked starts'
    grep_fixed 'gh codespace code -c $Name' "$REOPEN_SCRIPT" \
        || fail 'reopen helper does not open the restarted Codespace in VS Code'
    grep_fixed 'scripts/reopen-codespace.ps1' "$README" \
        || fail 'README does not document the local reopen helper'
    grep_fixed 'Default idle timeout' "$README" \
        || fail 'README does not document setting the Codespaces idle timeout'
    grep_fixed '240 minutes' "$README" \
        || fail 'README does not recommend the maximum supported idle timeout'
    pass 'local reopen helper is documented'
}

test_background_supervisor_ownership_is_strict() {
    grep_fixed 'background_supervisor_token_current()' "$SCRIPT" \
        || fail 'background supervisor loop does not verify its token remains current'
    grep_fixed 'write_background_supervisor_heartbeat()' "$SCRIPT" \
        || fail 'background supervisor heartbeat does not carry ownership data'
    grep_fixed 'background_supervisor_heartbeat_matches()' "$SCRIPT" \
        || fail 'fresh heartbeat cannot prove supervisor ownership when proc env is unavailable'
    grep_fixed 'printf '\''%s %s %s\n'\'' "${BASHPID:-$$}" "${G2RAY_BG_TASK_TOKEN:-}" "$now"' "$SCRIPT" \
        || fail 'heartbeat does not persist pid token and timestamp together'
    awk '
        /background_supervisor_status\(\)/ { in_fn=1 }
        in_fn && /background_supervisor_heartbeat_timestamp/ { saw_timestamp=1 }
        in_fn && /^}/ { exit }
        END { exit saw_timestamp ? 0 : 1 }
    ' "$SCRIPT" \
        || fail 'background supervisor status still cannot read structured heartbeat timestamps'
    grep_fixed 'supervisor_superseded' "$SCRIPT" \
        || fail 'superseded background supervisors do not self-exit'
    if grep_fixed 'legacy_bg_tasks_running "$p" || background_supervisor_heartbeat_running "$p"' "$SCRIPT"; then
        fail 'supervisor lifecycle still trusts legacy/heartbeat ownership for reuse or kill decisions'
    fi
    pass 'background supervisor ownership is strict'
}

test_exports_filter_unusable_fallback_routes() {
    grep_fixed 'usable_fallback_ips()' "$SCRIPT" \
        || fail 'fallback exports cannot filter unusable route IPs'
    grep_fixed 'xhttp_probe_metrics external "$ip"' "$SCRIPT" \
        || fail 'fallback export filtering does not probe each IP route'
    grep_fixed 'xhttp_status_usable "$ip_probe"' "$SCRIPT" \
        || fail 'fallback export filtering does not require usable XHTTP status'
    grep_fixed 'done < <(usable_fallback_ips)' "$SCRIPT" \
        || fail 'generate_ip_links still exports raw fallback candidates'
    grep_fixed 'address=$(usable_fallback_ips | head -1 || true)' "$SCRIPT" \
        || fail 'recommended IP link does not prefer a usable fallback route'
    pass 'fallback exports filter unusable route IPs'
}

test_runtime_ready_rejects_started_but_unusable_route() {
    awk '
        /ensure_runtime_ready\(\)/ { in_fn=1 }
        in_fn && /started_route_unusable/ { saw_started_unusable=1 }
        saw_started_unusable && /started_route_ready/ { saw_ready=1 }
        saw_started_unusable && /started_route_still_unusable/ { saw_still_bad=1 }
        saw_started_unusable && /return 1/ { saw_failure=1 }
        in_fn && /^}/ { exit }
        END { exit (saw_started_unusable && saw_ready && saw_still_bad && saw_failure) ? 0 : 1 }
    ' "$SCRIPT" \
        || fail 'ensure_runtime_ready can still return success after a newly-started engine has an unusable XHTTP route'
    pass 'runtime readiness rejects newly-started unusable XHTTP routes'
}

test_runtime_files_are_private_and_tempfiles_are_unique() {
    grep_fixed 'umask 077' "$SCRIPT" \
        || fail 'runtime files are not created with a private umask'
    grep_fixed 'chmod 600 "$UUID_FILE" "$CONFIG_FILE"' "$SCRIPT" \
        || fail 'generated UUID/config files are not explicitly chmod 600'
    if grep_fixed 'local tmp="/tmp/g2ray_remote.sh"' "$SCRIPT"; then
        fail 'self-update still uses a predictable /tmp path'
    fi
    if grep_fixed '> /tmp/g2ray_msg_tmp.txt' "$SCRIPT"; then
        fail 'remote message fetch still uses a predictable /tmp path'
    fi
    if grep_fixed '> /tmp/gas_resp.txt' "$SCRIPT"; then
        fail 'donation response still uses a predictable /tmp path'
    fi
    grep_fixed 'mktemp "${TMPDIR:-/tmp}/g2ray_remote.XXXXXX"' "$SCRIPT" \
        || fail 'self-update does not stage downloads through mktemp'
    grep_fixed 'mktemp "${TMPDIR:-/tmp}/g2ray_msg.XXXXXX"' "$SCRIPT" \
        || fail 'remote message fetch does not stage through mktemp'
    grep_fixed 'mktemp "${TMPDIR:-/tmp}/g2ray_donate.XXXXXX"' "$SCRIPT" \
        || fail 'donation response does not stage through mktemp'
    pass 'runtime files are private and tempfiles are unique'
}

test_logs_are_bounded_and_quota_is_cycle_aware() {
    grep_fixed 'rotate_log_file()' "$SCRIPT" \
        || fail 'script has no log rotation helper'
    grep_fixed 'G2RAY_LOG_MAX_BYTES' "$SCRIPT" \
        || fail 'app log cap is not configurable'
    grep_fixed 'rotate_log_file "$LOG_FILE"' "$SCRIPT" \
        || fail 'g2ray app log is not capped'
    grep_fixed 'rotate_log_file "$LOG_DIR/xray-error.log"' "$SCRIPT" \
        || fail 'xray error log is not capped'
    grep_fixed 'QUOTA_CYCLE_FILE=' "$SCRIPT" \
        || fail 'quota estimate has no persisted billing cycle marker'
    grep_fixed 'reset_monthly_quota_if_needed()' "$SCRIPT" \
        || fail 'quota estimate is not monthly-cycle aware'
    grep_fixed 'G2RAY_QUOTA_SECONDS' "$SCRIPT" \
        || fail 'quota seconds are not configurable'
    grep_fixed 'Local 2-core quota estimate' "$SCRIPT" \
        || fail 'quota panel does not label itself as a local estimate'
    grep_fixed 'storage quota, not traffic quota' "$README" \
        || fail 'README does not distinguish GitHub storage quota from VPN traffic'
    pass 'logs are bounded and quota estimate is cycle aware'
}

test_fallback_link_count_is_capped() {
    grep_fixed 'MAX_FALLBACK_LINKS=' "$SCRIPT" \
        || fail 'fallback link cap is not configurable'
    grep_fixed '(( index > max_links )) && break' "$SCRIPT" \
        || fail 'fallback link generation does not cap weak extra routes'
    grep_fixed 'G2RAY_MAX_FALLBACK_LINKS' "$README" \
        || fail 'README does not document the fallback link cap'
    pass 'fallback link count is capped and documented'
}

test_ci_runs_static_regressions() {
    [[ -f "$CI_WORKFLOW" ]] || fail 'static test GitHub Actions workflow is missing'
    grep_fixed 'bash -n ./g2ray.sh' "$CI_WORKFLOW" \
        || fail 'CI workflow does not syntax-check g2ray.sh'
    grep_fixed 'bash ./tests/g2ray_static_tests.sh' "$CI_WORKFLOW" \
        || fail 'CI workflow does not run the static regression suite'
    pass 'CI runs shell syntax and static regression checks'
}

test_xhttp_route_settling_is_observable() {
    grep_fixed 'BG_TASKS_VERSION_FILE=' "$SCRIPT" \
        || fail 'background supervisor does not record a script version marker'
    grep_fixed 'background_supervisor_version()' "$SCRIPT" \
        || fail 'script cannot fingerprint the active background supervisor version'
    grep_fixed 'stop_background_tasks()' "$SCRIPT" \
        || fail 'script cannot stop stale background supervisors after updates'
    grep_fixed 'background_supervisor_version_matches' "$SCRIPT" \
        || fail 'start_background_tasks reuses stale supervisors after script updates'
    grep_fixed 'xhttp_probe_status()' "$SCRIPT" \
        || fail 'script does not provide a dedicated XHTTP edge probe'
    grep_fixed 'xhttp_status_usable()' "$SCRIPT" \
        || fail 'script does not classify XHTTP probe status codes'
    grep_fixed '[[ "$code" == "200" || "$code" == "400" ]]' "$SCRIPT" \
        || fail 'HTTP 404 is still treated as a usable XHTTP route'
    grep_fixed 'xhttp_route_usable=' "$SCRIPT" \
        || fail 'health/reconnect logs do not expose XHTTP route usability'
    grep_fixed 'repair_codespace_port_route()' "$SCRIPT" \
        || fail 'script has no repair path for stale Codespaces port routing'
    grep_fixed 'route_unusable' "$SCRIPT" \
        || fail 'watchdog does not distinguish unusable XHTTP routing from a dead edge'
    grep_fixed 'XHTTP Probes' "$SCRIPT" \
        || fail 'diagnostics do not show local/external XHTTP probe results'
    grep_fixed 'Config    :' "$SCRIPT" \
        || fail 'diagnostics do not show XHTTP config path/mode/network summary'
    pass 'XHTTP route settling is observable and stale supervisors are replaced'
}

test_docs_and_public_configs_are_consistent() {
    grep_fixed '1-to-14' "$README" \
        || fail 'README menu count is stale'
    if grep_fixed 'did now get shown' "$README"; then
        fail 'README still contains the "did now" typo'
    fi
    grep_fixed 'G2RAY_QR_MODE' "$README" \
        || fail 'README does not document G2RAY_QR_MODE'
    grep_fixed 'G2RAY_EXTRA_FALLBACK_IPS' "$README" \
        || fail 'README does not document G2RAY_EXTRA_FALLBACK_IPS'
    grep_fixed '<details><summary><kbd>🔗</kbd> Community Donated Configs (SUB)</summary>' "$README" \
        || fail 'README community subscription summary is not wrapped in a details block'
    if grep_fixed 'without impacting your own speed or exposing personal data' "$README"; then
        fail 'README still claims donated live configs expose no personal data'
    fi
    if grep_fixed 'No impact on your speed, quota, or security' "$SCRIPT" || grep_fixed 'no extra risk' "$SCRIPT"; then
        fail 'CLI donation prompt still understates the live-config sharing tradeoff'
    fi
    grep_fixed 'shares the live VLESS link' "$README" \
        || fail 'README does not disclose what donation shares'
    grep_fixed 'This shares your live VLESS link publicly.' "$SCRIPT" \
        || fail 'CLI donation prompt does not disclose that it shares the live VLESS link'
    grep_fixed 'allowInsecure=1' "$README" \
        || fail 'README does not disclose the TLS verification tradeoff in exported links'
    awk 'NF && seen[$0]++ { dup=1 } END { exit dup ? 1 : 0 }' "$CONFIGS" \
        || fail 'configs.txt contains duplicate non-empty VLESS entries'
    pass 'docs and public configs are consistent'
}

test_devcontainer_tooling_is_not_duplicated() {
    grep_fixed 'dnsutils' "$ROOT_DIR/.devcontainer/Dockerfile" \
        || fail 'Dockerfile does not install dnsutils for dig-based DNS resolution'
    if grep_fixed 'vnstat' "$ROOT_DIR/.devcontainer/Dockerfile"; then
        fail 'Dockerfile still installs unused vnstat'
    fi
    if grep_fixed 'cli.github.com/packages' "$ROOT_DIR/.devcontainer/Dockerfile"; then
        fail 'Dockerfile still installs gh manually despite the devcontainer feature'
    fi
    grep_fixed 'ghcr.io/devcontainers/features/github-cli:1' "$ROOT_DIR/.devcontainer/devcontainer.json" \
        || fail 'devcontainer no longer installs gh through the github-cli feature'
    grep_fixed '.devcontainer/Dockerfile text eol=lf' "$ROOT_DIR/.gitattributes" \
        || fail 'Dockerfile line endings are not pinned to LF'
    grep_fixed 'assets/message.txt text eol=lf' "$ROOT_DIR/.gitattributes" \
        || fail 'message.txt line endings are not pinned to LF'
    pass 'devcontainer tooling and LF policy are clean'
}

test_menu_loop_and_link_output_are_tidy() {
    if grep_fixed '( fetch_remote_message >/dev/null 2>&1 & )' "$SCRIPT"; then
        fail 'menu loop still starts a redundant remote-message fetch every render'
    fi
    if awk '
        /generate_ip_links\(\)/ { in_fn=1 }
        in_fn && /generate_ordered_links\(\)/ { exit }
        in_fn && /generate_link_for_address "\$address" "-ip\$\{index\}"/ { saw_link=1; next }
        in_fn && saw_link && /printf '\''\\n'\''/ { bad=1; exit }
        in_fn && saw_link && /printed=true/ { saw_link=0 }
        END { exit bad ? 0 : 1 }
    ' "$SCRIPT"; then
        fail 'generate_ip_links still appends an unconditional blank line after each link'
    fi
    grep_fixed 'frames=("-" "\\" "|" "/")' "$SCRIPT" \
        || fail 'wait_for_port does not provide animated progress frames'
    grep_fixed 'Initializing engine... (${i}s)' "$SCRIPT" \
        || fail 'wait_for_port does not show elapsed initialization time'
    pass 'menu loop and link output are tidy'
}

test_donation_failures_are_not_suppressed() {
    grep_fixed 'return 0' "$SCRIPT" \
        || fail 'donation sender does not return success explicitly'
    grep_fixed 'return 1' "$SCRIPT" \
        || fail 'donation sender does not return failure explicitly'
    grep_fixed 'send_to_vless_forwarder "$vless" && touch' "$SCRIPT" \
        || fail 'manual donation marks config as prompted even when sending fails'
    grep_fixed 'send_to_vless_forwarder "$_VLESS_PRIMARY" && touch "$_PFLAG"' "$SCRIPT" \
        || fail 'first-view donation prompt is suppressed even when sending fails'
    if grep_fixed 'send_to_vless_forwarder "$_VLESS_PRIMARY"; sleep 1; }' "$SCRIPT"; then
        fail 'first-view donation still ignores send_to_vless_forwarder failure'
    fi
    pass 'donation failures are not suppressed'
}

test_wait_for_port_increment_is_set_e_safe
test_process_management_uses_pid_file
test_background_tasks_uses_owned_pid_file
test_background_tasks_require_config
test_port_visibility_failures_are_handled
test_self_update_is_opt_in
test_exit_trap_preserves_failures
test_generated_files_are_ignored
test_shell_files_are_lf_normalized
test_panel_script_is_executable
test_xray_version_can_be_pinned
test_generated_config_uses_resilient_dns_fallback
test_generated_links_include_domain_and_ip_variants
test_terminal_branding_is_customized_red
test_runtime_diagnostics_logging
test_xhttp_route_settling_is_observable
test_runtime_control_paths_are_hardened
test_startup_does_not_reconnect_healthy_runtime
test_self_heal_uses_reconnect_backoff
test_probe_and_gh_commands_are_bounded
test_diagnostics_show_latency_and_supervisor_state
test_diagnostics_show_self_heal_state
test_diagnostics_show_last_known_state
test_diagnostics_show_resume_gap_state
test_local_reopen_helper_is_documented
test_background_supervisor_ownership_is_strict
test_exports_filter_unusable_fallback_routes
test_runtime_ready_rejects_started_but_unusable_route
test_runtime_files_are_private_and_tempfiles_are_unique
test_logs_are_bounded_and_quota_is_cycle_aware
test_fallback_link_count_is_capped
test_ci_runs_static_regressions
test_docs_and_public_configs_are_consistent
test_devcontainer_tooling_is_not_duplicated
test_menu_loop_and_link_output_are_tidy
test_donation_failures_are_not_suppressed
