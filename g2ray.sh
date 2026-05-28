#!/bin/bash

set -euo pipefail

readonly G2RAY_ID="G2ray Panel v1.4.3"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[1;32m'; WHITE='\033[1;37m'; RED='\033[1;31m'
YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'; B='\033[1m'

DATA_DIR="$BASE_DIR/data"
CONFIG_FILE="$DATA_DIR/config.json"
UUID_FILE="$DATA_DIR/uuid.txt"
BG_TASKS_PID="$DATA_DIR/bg_tasks.pid"
BG_TASKS_VERSION_FILE="$DATA_DIR/bg_tasks.version"
ROUTE_BAD_COUNT_FILE="$DATA_DIR/xhttp_route_bad_count"
XRAY_PID_FILE="$DATA_DIR/xray.pid"
SAVED_BYTES_FILE="$DATA_DIR/saved_bytes.json"
SESSION_BYTES_FILE="$DATA_DIR/session_bytes.json"
TOTAL_UPTIME_FILE="$DATA_DIR/total_uptime_sec.txt"
SESSION_START_FILE="$DATA_DIR/session_start.txt"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/g2ray.log"
MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
SUBSCRIPTION_FILE="$BASE_DIR/configs-subscription-base64.txt"
XRAY_BIN="/usr/local/bin/xray"
XRAY_PORT=443
DEFAULT_FALLBACK_IPS="${G2RAY_DEFAULT_FALLBACK_IPS:-20.85.77.48 20.207.70.99 20.120.56.11}"

mkdir -p "$DATA_DIR" "$LOG_DIR"
touch "$LOG_FILE" 2>/dev/null || true
[[ -f "$SAVED_BYTES_FILE"   ]] || printf '{"down":0,"up":0}\n' > "$SAVED_BYTES_FILE"
[[ -f "$SESSION_BYTES_FILE" ]] || printf '{"down":0,"up":0}\n' > "$SESSION_BYTES_FILE"
[[ -f "$TOTAL_UPTIME_FILE"  ]] || printf '0\n'                 > "$TOTAL_UPTIME_FILE"
[[ -f "$SESSION_START_FILE" ]] || date +%s                     > "$SESSION_START_FILE"

log_event() {
    local level="$1"; shift || true
    local ts msg
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    msg="$*"
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

fingerprint_secret() {
    local value="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$value" | sha256sum | awk '{print substr($1,1,12)}'
    else
        printf '%s' "$value" | md5sum | awk '{print substr($1,1,12)}'
    fi
}

_detect_codespace_name() {
    [[ -n "${CODESPACE_NAME:-}" ]] && { printf '%s' "$CODESPACE_NAME"; return; }
    if command -v gh >/dev/null 2>&1; then
        local n
        n=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
            gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [[ -n "$n" ]] && { printf '%s' "$n"; return; }
        sleep 2
        n=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
            gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [[ -n "$n" ]] && { printf '%s' "$n"; return; }
    fi
    local h; h=$(hostname 2>/dev/null || true)
    printf '%s' "${h:-unknown-codespace}"
}

CODESPACE_NAME=$(_detect_codespace_name)
PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"

xray_pid_matches() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ps -p "$p" -o args= 2>/dev/null | grep -Fq "$XRAY_BIN run -c $CONFIG_FILE"
}

xray_running() {
    local p
    if [[ -f "$XRAY_PID_FILE" ]]; then
        p=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
        if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
            return 0
        fi
        rm -f "$XRAY_PID_FILE" 2>/dev/null || true
    fi
    p=$(pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" | head -1 || true)
    [[ -n "$p" ]]
}

owned_xray_pids() {
    local p
    p=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
    if xray_pid_matches "$p"; then
        printf '%s\n' "$p"
    fi
    pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" 2>/dev/null || true
}

json_dns_ips() {
    local url="$1" header="${2:-}"
    if [[ -n "$header" ]]; then
        (curl -sf -m 4 -H "$header" "$url" 2>/dev/null \
            | grep -oE '"data":"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' \
            | sed -E 's/^"data":"//;s/"$//') || true
    else
        (curl -sf -m 4 "$url" 2>/dev/null \
            | grep -oE '"data":"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' \
            | sed -E 's/^"data":"//;s/"$//') || true
    fi
}

curl_remote_ip() {
    local domain="$1" ip
    ip=$(curl -sk -m 5 -o /dev/null -w '%{remote_ip}' "https://${domain}/" 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$ ]] && printf '%s\n' "$ip"
}

xhttp_config_path() {
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        jq -r '.inbounds[]? | select(.tag=="vless-in") | .streamSettings.xhttpSettings.path // "/"' "$CONFIG_FILE" 2>/dev/null \
            | awk 'NF {print; exit}'
        return 0
    fi
    printf '/'
}

xhttp_probe_status() {
    local target="${1:-external}" path code url
    path=$(xhttp_config_path)
    [[ "$path" == /* ]] || path="/${path}"
    case "$target" in
        local) url="http://127.0.0.1:${XRAY_PORT}${path}" ;;
        *)     url="https://${PORT_DOMAIN}${path}" ;;
    esac
    code=$(curl -sk -m 5 -X OPTIONS -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "0")
    [[ "$code" == "000" ]] && code=0
    printf '%s' "${code:-0}"
}

xhttp_status_usable() {
    local code="${1:-0}"
    [[ "$code" == "200" || "$code" == "400" ]]
}

increment_route_bad_count() {
    local count
    count=$(cat "$ROUTE_BAD_COUNT_FILE" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    printf '%s\n' "$count" > "$ROUTE_BAD_COUNT_FILE"
    printf '%s' "$count"
}

reset_route_bad_count() {
    rm -f "$ROUTE_BAD_COUNT_FILE" 2>/dev/null || true
}

resolve_domain_ips() {
    local domain="$1" candidates joined
    candidates=$({
        if [[ -n "${G2RAY_EXTRA_FALLBACK_IPS:-}" ]]; then
            printf '%s\n' "$G2RAY_EXTRA_FALLBACK_IPS" | tr ',; ' '\n'
        fi
        if command -v dig >/dev/null 2>&1; then
            dig +short "$domain" A 2>/dev/null || true
        fi
        getent hosts "$domain" 2>/dev/null | awk '{print $1}' || true
        json_dns_ips "https://dns.google/resolve?name=${domain}&type=A"
        json_dns_ips "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" "accept: application/dns-json"
        curl_remote_ip "$domain" || true
        printf '%s\n' "$DEFAULT_FALLBACK_IPS" | tr ',; ' '\n'
    } | awk '/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$/ && !seen[$0]++ {print}')
    if [[ -n "$candidates" ]]; then
        joined=$(printf '%s' "$candidates" | tr '\n' ',' | sed 's/,$//')
        log_event INFO "resolver domain=${domain} fallback_candidates=${joined}"
    else
        log_event WARN "resolver domain=${domain} no-ip-candidates"
    fi
    printf '%s\n' "$candidates"
}

resolve_domain_ip() {
    local domain="$1" ip=""
    ip=$(resolve_domain_ips "$domain" | head -1 || true)
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return; }
    printf '%s' "$domain"
}

_atomic_write() {
    local file="$1" content="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$file"
}

first_nonempty_line() {
    awk 'NF {print; exit}' <<< "${1:-}"
}

render_config_qr() {
    local link="$1"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -m 0 -t UTF8 "$link" | while IFS= read -r line; do
            printf '  %s\n' "$line"
        done
    else
        echo -e "  ${DIM}(qrencode not installed - QR unavailable)${NC}"
    fi
}

render_config_entry() {
    local index="$1" label="$2" link="$3"
    local show_qr="${4:-false}"
    echo -e "  ${RED}[${index}]${NC} ${WHITE}${B}${label}${NC}"
    if [[ "$show_qr" == true ]]; then
        echo -e "  ${DIM}QR:${NC}"
        render_config_qr "$link"
    else
        echo -e "  ${DIM}QR hidden in default view. Set G2RAY_QR_MODE=all to show every QR.${NC}"
    fi
    echo -e "  ${DIM}Copy-ready link:${NC}"
    printf '%s\n' "$link"
    echo ""
}

draw_logo() {
    echo -e "${RED}${B}"
    echo -e "    ██████╗ ██████╗ ██████╗  █████╗ ██╗   ██╗"
    echo -e "   ██╔════╝ ╚════██╗██╔══██╗██╔══██╗╚██╗ ██╔╝"
    echo -e "   ██║  ███╗█████╔╝██████╔╝███████║ ╚████╔╝ "
    echo -e "   ██║   ██║██╔═══╝ ██╔══██╗██╔══██║  ╚██╔╝  "
    echo -e "   ╚██████╔╝███████╗██║  ██║██║  ██║   ██║   "
    echo -e "    ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ${NC}"
    echo -e "       ${WHITE}${B}v1.4.3${NC} ${DIM}•${NC} ${WHITE}Made by CodeLeafy${NC} ${DIM}•${NC} ${WHITE}Customized${NC}\n"
}

refresh_screen() {
    stty sane 2>/dev/null || true
    clear
    draw_logo
}

check_for_updates() {
    [[ "${G2RAY_AUTO_UPDATE:-0}" == "1" ]] || return 0
    clear; draw_logo
    local tmp="/tmp/g2ray_remote.sh" staged
    curl -s -m 8 -L "https://raw.githubusercontent.com/Code-Leafy/G2rayXCodeLeafy/main/g2ray.sh" -o "$tmp" &
    local pid=$! frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏") i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %b%s%b %bChecking for latest updates...%b" "$GREEN" "${frames[i]}" "$NC" "$WHITE" "$NC"
        i=$(( (i+1) % 10 )); sleep 0.1
    done
    wait "$pid" || true
    if [[ -f "$tmp" ]] && grep -q "G2ray Panel" "$tmp" 2>/dev/null && bash -n "$tmp" 2>/dev/null; then
        if ! cmp -s "$0" "$tmp"; then
            printf "\r  %b✔%b %bUpdate found! Installing...              %b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            staged=$(mktemp "${0}.XXXXXX")
            cp "$tmp" "$staged"
            chmod +x "$staged"
            mv -f "$staged" "$0"
            printf "  %b✔%b %bUpdate applied! Restarting...%b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            sleep 1.5; exec bash "$0" "$@"
        else
            printf "\r  %b✔%b %bSystem is fully up to date.               %b\n" "$GREEN" "$NC" "$DIM" "$NC"
        fi
    else
        printf "\r  %b✖%b %bUpdate check failed (network or 404).     %b\n" "$RED" "$NC" "$DIM" "$NC"
    fi
    rm -f "$tmp" 2>/dev/null || true
    sleep 1
}

fetch_remote_message() {
    curl -s -m 4 "https://raw.githubusercontent.com/Code-Leafy/G2rayXCodeLeafy/main/assets/message.txt" \
        > /tmp/g2ray_msg_tmp.txt 2>/dev/null || true
    [[ -f /tmp/g2ray_msg_tmp.txt ]] && mv -f /tmp/g2ray_msg_tmp.txt /tmp/g2ray_message.txt 2>/dev/null || true
}

enable_anti_sleep() {
    tmux has-session -t g2ray_keepalive 2>/dev/null && return 0
    cat > "$DATA_DIR/keepalive.sh" << 'EOF'
#!/bin/bash
i=0
while true; do
    i=$(( i+1 ))
    printf "\r[G2ray] Keepalive tick: %d" "$i"
    (( i % 60 == 0 )) && curl -s -m 4 https://github.com >/dev/null 2>&1
    sleep 1
done
EOF
    chmod +x "$DATA_DIR/keepalive.sh"
    tmux new-session -d -s g2ray_keepalive "bash $DATA_DIR/keepalive.sh" 2>/dev/null || true
}

send_to_vless_forwarder() {
    local link="$1"
    local url="https://script.google.com/macros/s/AKfycbwtsJZhhaBjPILq0wY3saytWmWtQFD6aXXwmHnX_i_BX5OCMLiVrXPutCxM-ejPafVGsg/exec"
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "  ${RED}✖ jq unavailable — cannot donate config.${NC}"; return 1
    fi
    local payload; payload=$(jq -n --arg m "$link" '{message:$m}')
    echo -e "  ${YELLOW}Sending config to developer network...${NC}"
    if curl -sf -L --max-time 15 -H "Content-Type: application/json" \
            -d "$payload" "$url" </dev/null > /tmp/gas_resp.txt 2>&1; then
        if grep -q "Appended to GitHub" /tmp/gas_resp.txt; then
            echo -e "  ${GREEN}✔ Config donated successfully! Thank you.${NC}"
        else
            echo -e "  ${RED}✖ Donation endpoint rejected.${NC}"
        fi
    else
        echo -e "  ${RED}✖ Could not reach donation endpoint.${NC}"
    fi
}

is_port_open() {
    if command -v ss >/dev/null 2>&1; then
        sudo ss -tnl 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"
    else
        sudo netstat -tnl 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"
    fi
}

ensure_codespace_port_public() {
    command -v gh >/dev/null 2>&1 || return 1
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
        gh codespace ports visibility "${XRAY_PORT}:public" -c "$CODESPACE_NAME" \
        </dev/null >/dev/null 2>&1
}

repair_codespace_port_route() {
    command -v gh >/dev/null 2>&1 || return 1
    log_event WARN "route_repair begin port=${XRAY_PORT} domain=${PORT_DOMAIN}"
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
        gh codespace ports visibility "${XRAY_PORT}:private" -c "$CODESPACE_NAME" \
        </dev/null >/dev/null 2>&1 || true
    sleep 2
    if ensure_codespace_port_public; then
        log_event INFO "route_repair public_ok port=${XRAY_PORT}"
        return 0
    fi
    log_event ERROR "route_repair public_failed port=${XRAY_PORT}"
    return 1
}

save_xray_stats() {
    xray_running || return 0
    local stats sd su bd bu svd svu dd du
    stats=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null) || return 0
    [[ -z "$stats" ]] && return 0
    sd=$(printf '%s' "$stats" | grep -A1 'downlink' | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
    su=$(printf '%s' "$stats" | grep -A1 'uplink'   | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
    sd=${sd:-0}; su=${su:-0}
    bd=$(jq -r '.down//0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    bu=$(jq -r '.up//0'   "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    dd=$(awk -v s="$sd" -v b="$bd" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
    du=$(awk -v s="$su" -v b="$bu" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
    svd=$(jq -r '.down//0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    svu=$(jq -r '.up//0'   "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    _atomic_write "$SAVED_BYTES_FILE" \
        "$(printf '{"down":%s,"up":%s}' \
            "$(awk -v a="$svd" -v b="$dd" 'BEGIN{printf "%.0f",a+b}')" \
            "$(awk -v a="$svu" -v b="$du" 'BEGIN{printf "%.0f",a+b}')")"
    _atomic_write "$SESSION_BYTES_FILE" \
        "$(printf '{"down":%s,"up":%s}' "$sd" "$su")"
}

get_data_usage() {
    local svd svu sd=0 su=0 stats fd fu bd bu
    svd=$(jq -r '.down//0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    svu=$(jq -r '.up//0'   "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    if xray_running; then
        stats=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null) || true
        if [[ -n "$stats" ]]; then
            fd=$(printf '%s' "$stats" | grep -A1 'downlink' | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
            fu=$(printf '%s' "$stats" | grep -A1 'uplink'   | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
            bd=$(jq -r '.down//0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            bu=$(jq -r '.up//0'   "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            sd=$(awk -v s="${fd:-0}" -v b="$bd" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
            su=$(awk -v s="${fu:-0}" -v b="$bu" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
        fi
    fi
    printf '%s %s' \
        "$(awk -v a="$svd" -v b="$sd" 'BEGIN{printf "%.0f",a+b}')" \
        "$(awk -v a="$svu" -v b="$su" 'BEGIN{printf "%.0f",a+b}')"
}

reset_session_bytes_baseline() {
    _atomic_write "$SESSION_BYTES_FILE" '{"down":0,"up":0}'
}

save_session_uptime() {
    local ss now elapsed prev
    ss=$(cat "$SESSION_START_FILE" 2>/dev/null || date +%s)
    now=$(date +%s)
    elapsed=$(( now - ss ))
    (( elapsed < 0    )) && elapsed=0
    (( elapsed > 3600 )) && elapsed=3600
    prev=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    printf '%s\n' $(( prev + elapsed )) > "$TOTAL_UPTIME_FILE"
    printf '%s\n' "$now"               > "$SESSION_START_FILE"
}

stop_xray() {
    save_xray_stats 2>/dev/null || true
    local p owned_pids=()
    mapfile -t owned_pids < <(owned_xray_pids | awk 'NF && !seen[$0]++ {print}')
    if ((${#owned_pids[@]})); then
        for p in "${owned_pids[@]}"; do
            if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
                log_event INFO "stop_xray pid=${p}"
                sudo kill "$p" >/dev/null 2>&1 || true
                sleep 0.5
                if sudo kill -0 "$p" 2>/dev/null; then
                    sudo kill -9 "$p" >/dev/null 2>&1 || true
                    log_event WARN "stop_xray forced_kill pid=${p}"
                fi
            fi
        done
    else
        log_event INFO "stop_xray no-owned-process"
    fi
    if ((${#owned_pids[@]})); then
        for p in "${owned_pids[@]}"; do
            if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
                log_event ERROR "stop_xray still_alive pid=${p}"
                return 1
            fi
        done
    fi
    rm -f "$XRAY_PID_FILE" 2>/dev/null || true
    sleep 0.5
}

upgrade_config_dns() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        log_event WARN "config_dns jq_unavailable"
        return 0
    fi

    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.dns.XXXXXX") || return 0
    if jq '
      .dns = {
        "hosts": {
          "dns.google": ["8.8.8.8", "8.8.4.4"],
          "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"]
        },
        "servers": [
          { "address": "https+local://1.1.1.1/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
          { "address": "https+local://dns.google/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
          { "address": "1.0.0.1", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
          { "address": "8.8.4.4", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
          "localhost"
        ],
        "queryStrategy": "UseIPv4",
        "disableFallback": false,
        "disableFallbackIfMatch": false,
        "enableParallelQuery": true
      }
    ' "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
        if cmp -s "$CONFIG_FILE" "$tmp"; then
            rm -f "$tmp" 2>/dev/null || true
        else
            mv -f "$tmp" "$CONFIG_FILE"
            log_event INFO "config_dns refreshed"
        fi
    else
        rm -f "$tmp" 2>/dev/null || true
        log_event WARN "config_dns refresh_failed"
    fi
}

start_xray() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_event WARN "start_xray missing_config path=${CONFIG_FILE}"
        echo -e "  ${RED}✖ No config found. Generate one first (Option 2).${NC}"
        return 1
    fi
    local launch_cmd pid
    log_event INFO "start_xray requested port=${XRAY_PORT} config=${CONFIG_FILE}"
    launch_cmd=$(printf 'nohup %q run -c %q </dev/null >%q 2>&1 & printf "%%s\n" "$!"' \
        "$XRAY_BIN" "$CONFIG_FILE" "$LOG_DIR/xray.log")
    if ! stop_xray; then
        log_event ERROR "start_xray stop_previous_failed"
        echo -e "  ${RED}✖ Could not stop previous Xray process.${NC}"
        return 1
    fi
    upgrade_config_dns >/dev/null 2>&1 || true
    reset_session_bytes_baseline
    pid=$(sudo bash -c "$launch_cmd" 2>/dev/null || true)
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        log_event ERROR "start_xray launch_failed"
        echo -e "  ${RED}✖ Failed to start Xray.${NC}"
        return 1
    fi
    printf '%s\n' "$pid" > "$XRAY_PID_FILE"
    log_event INFO "xray launched pid=${pid} port=${XRAY_PORT}"
}

wait_for_port() {
    local i=0
    echo -ne "  ${GREEN}⠋${NC} ${DIM}Initializing engine...${NC} "
    while ! is_port_open && (( i < 15 )); do sleep 1; i=$((i + 1)); done
    echo ""
    if is_port_open; then
        log_event INFO "wait_for_port open port=${XRAY_PORT} seconds=${i}"
        return 0
    fi
    log_event ERROR "wait_for_port timeout port=${XRAY_PORT} seconds=${i}"
    return 1
}

health_probe() {
    local engine="stopped" listener="closed" code xcode xhttp_route_usable=false
    xray_running && engine="running"
    is_port_open && listener="open"
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://${PORT_DOMAIN}" 2>/dev/null || echo "0")
    xcode=$(xhttp_probe_status external)
    xhttp_status_usable "$xcode" && xhttp_route_usable=true
    log_event INFO "health engine=${engine} listener=${listener} external_code=${code:-0} xhttp_probe=${xcode:-0} xhttp_route_usable=${xhttp_route_usable} domain=${PORT_DOMAIN}"
}

self_heal_once() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local reason="" code xcode bad_count

    if ! ensure_codespace_port_public >/dev/null 2>&1; then
        log_event WARN "self_heal port_public_failed port=${XRAY_PORT}"
    fi

    if ! xray_running; then
        reason=xray_stopped
    elif ! is_port_open; then
        reason=listener_closed
    fi

    if [[ -n "$reason" ]]; then
        log_event WARN "self_heal restart reason=${reason}"
        if start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1; then
            log_event INFO "self_heal restart_ok reason=${reason}"
            ensure_codespace_port_public >/dev/null 2>&1 || true
        else
            log_event ERROR "self_heal restart_failed reason=${reason}"
            return 1
        fi
    fi

    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://${PORT_DOMAIN}" 2>/dev/null || echo "0")
    if [[ "$code" == "000" || "$code" == "0" ]]; then
        log_event WARN "self_heal edge_unreachable code=${code:-0} action=force_reconnect"
        force_reconnect --no-prompt >/dev/null 2>&1 \
            || log_event ERROR "self_heal force_reconnect_failed code=${code:-0}"
        return 0
    fi

    xcode=$(xhttp_probe_status external)
    if xhttp_status_usable "$xcode"; then
        reset_route_bad_count
    else
        bad_count=$(increment_route_bad_count)
        log_event WARN "self_heal route_unusable xhttp_probe=${xcode:-0} bad_count=${bad_count} action=observe"
        if (( bad_count >= 2 )); then
            log_event WARN "self_heal route_unusable action=repair port=${XRAY_PORT}"
            repair_codespace_port_route >/dev/null 2>&1 || true
            reset_route_bad_count
        fi
    fi
}

_background_tasks() {
    set +e
    local tick=0 health_tick=0 export_tick=0
    while true; do
        sleep 60
        if [[ "$PORT_DOMAIN" == unknown-codespace* ]]; then
            local n; n=$(_detect_codespace_name 2>/dev/null || true)
            if [[ -n "$n" && "$n" != "unknown-codespace" ]]; then
                CODESPACE_NAME="$n"
                PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
            fi
        fi
        [[ -f "$CONFIG_FILE" ]] || continue
        self_heal_once >/dev/null 2>&1 || true
        save_xray_stats    >/dev/null 2>&1 || true
        save_session_uptime >/dev/null 2>&1 || true
        (( ++health_tick >= 5 )) && { health_probe >/dev/null 2>&1; health_tick=0; }
        (( ++export_tick >= 5 )) && { refresh_config_exports >/dev/null 2>&1 || true; export_tick=0; }
        (( ++tick >= 3 )) && { fetch_remote_message; tick=0; }
    done
}

start_background_tasks() {
    if [[ -f "$BG_TASKS_PID" ]]; then
        local p; p=$(cat "$BG_TASKS_PID" 2>/dev/null || true)
        if bg_tasks_running "$p"; then
            if background_supervisor_version_matches; then
                return 0
            fi
            log_event WARN "background supervisor_stale pid=${p}"
            stop_background_tasks
        fi
    fi
    _background_tasks </dev/null >/dev/null 2>&1 &
    printf '%s\n' $! > "$BG_TASKS_PID"
    background_supervisor_version > "$BG_TASKS_VERSION_FILE" 2>/dev/null || true
    log_event INFO "background supervisor_started pid=$!"
    disown 2>/dev/null || true
}

background_supervisor_version() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$BASE_DIR/g2ray.sh" 2>/dev/null | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$BASE_DIR/g2ray.sh" 2>/dev/null | awk '{print $1}'
    elif command -v git >/dev/null 2>&1; then
        git -C "$BASE_DIR" rev-parse HEAD 2>/dev/null || true
    fi
}

background_supervisor_version_matches() {
    local expected current
    expected=$(cat "$BG_TASKS_VERSION_FILE" 2>/dev/null || true)
    current=$(background_supervisor_version)
    [[ -n "$expected" && -n "$current" && "$expected" == "$current" ]]
}

stop_background_tasks() {
    local p
    p=$(cat "$BG_TASKS_PID" 2>/dev/null || true)
    if bg_tasks_running "$p"; then
        kill "$p" >/dev/null 2>&1 || true
        sleep 1
        bg_tasks_running "$p" && kill -9 "$p" >/dev/null 2>&1 || true
    fi
    rm -f "$BG_TASKS_PID" "$BG_TASKS_VERSION_FILE" 2>/dev/null || true
}

bg_tasks_running() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    ps -p "$p" -o args= 2>/dev/null | grep -Fq "g2ray.sh"
}

format_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if      (b < 1048576)    printf "%.2f KB", b / 1024
        else if (b < 1073741824) printf "%.2f MB", b / 1048576
        else                     printf "%.2f GB", b / 1073741824
    }'
}

estimate_quota() {
    local prev ss now elapsed total rem h_used m_used h_left m_left dtime
    prev=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    ss=$(cat "$SESSION_START_FILE" 2>/dev/null || date +%s)
    now=$(date +%s); elapsed=$(( now - ss ))
    (( elapsed < 0    )) && elapsed=0
    (( elapsed > 3600 )) && elapsed=3600
    total=$(( prev + elapsed ))
    rem=$(( 216000 - total )); (( rem < 0 )) && rem=0
    h_used=$(( total / 3600 ));   m_used=$(( (total % 3600) / 60 ))
    h_left=$(( rem   / 3600 ));   m_left=$(( (rem   % 3600) / 60 ))
    dtime=$(date -d "+${rem} seconds" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "N/A")
    echo -e "  ${GREEN}● Codespace Quota${NC}"
    echo -e "  Total Used : ${WHITE}${h_used}h ${m_used}m${NC}"
    echo -e "  Remaining  : ${GREEN}${h_left}h ${m_left}m${NC} ${DIM}(of 60h tier)${NC}"
    echo -e "  Depletion  : ${DIM}${dtime}${NC}"
}

show_resource_stats() {
    refresh_screen
    echo -e "\n  ${GREEN}● Live Resource Stats${NC}"
    local xpid cpu mem_kb mem_mb
    xpid=$(pgrep -x "xray" | head -1 || pgrep -f "$XRAY_BIN run" | head -1 || true)
    if [[ -n "$xpid" ]]; then
        read -r cpu mem_kb <<< "$(ps -p "$xpid" -o %cpu,rss --no-headers 2>/dev/null || echo '0 0')"
        mem_mb=$(awk "BEGIN{printf \"%.1f\",${mem_kb:-0}/1024}")
        echo -e "  Engine : ${GREEN}Active${NC} (PID $xpid)"
        echo -e "  CPU    : ${WHITE}${cpu}%${NC}"
        echo -e "  Memory : ${WHITE}${mem_mb} MB${NC}"
    else
        echo -e "  Engine : ${RED}Offline${NC}"
    fi
    echo ""
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

check_port_visibility() {
    if ! is_port_open; then
        log_event WARN "check_port_visibility engine_not_running port=${XRAY_PORT}"
        refresh_screen
        echo -e "  ${RED}✖ Engine is not running!${NC}"
        echo -e "  ${DIM}Start the engine first (Option 3).${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
        return 1
    fi
    if ! ensure_codespace_port_public; then
        log_event WARN "check_port_visibility port_public_failed port=${XRAY_PORT}"
        refresh_screen
        echo -e "  ${YELLOW}⚠ Could not set Codespaces port ${XRAY_PORT} public.${NC}"
        echo -e "  ${DIM}Open the PORTS tab and set port ${XRAY_PORT} visibility to Public.${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
        return 1
    fi
}

generate_config() {
    uuidgen > "$UUID_FILE"
    local uuid; uuid=$(cat "$UUID_FILE")
    local uuid_hash; uuid_hash=$(fingerprint_secret "$uuid")
    log_event INFO "generate_config uuid_hash=${uuid_hash} port=${XRAY_PORT} domain=${PORT_DOMAIN}"
    cat > "$CONFIG_FILE" << JSONEOF
{
  "log": { "loglevel": "warning", "access": "none", "error": "${LOG_DIR}/xray-error.log" },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "system": { "statsInboundDownlink": true, "statsInboundUplink": true },
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true, "handshake": 3, "connIdle": 600, "uplinkOnly": 1, "downlinkOnly": 2, "bufferSize": 512 } }
  },
  "dns": {
    "hosts": {
      "dns.google": ["8.8.8.8", "8.8.4.4"],
      "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"]
    },
    "servers": [
      { "address": "https+local://1.1.1.1/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
      { "address": "https+local://dns.google/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
      { "address": "1.0.0.1", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
      { "address": "8.8.4.4", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableFallback": false,
    "disableFallbackIfMatch": false,
    "enableParallelQuery": true
  },
  "inbounds": [
    {
      "tag": "vless-in", "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}", "flow": "", "level": 0, "email": "user@G2rayXCodeLeafy" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp", "security": "none",
        "xhttpSettings": { "mode": "packet-up", "path": "/", "maxUploadSize": 2000000, "maxConcurrentUploads": 16 }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false }
    },
    { "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom",   "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole",  "settings": { "response": { "type": "http" } } }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "inboundTag": ["api"],                                   "outboundTag": "api",    "type": "field" },
      { "type": "field", "ip":       ["geoip:private"],          "outboundTag": "block"  },
      { "type": "field", "protocol": ["bittorrent"],             "outboundTag": "block"  },
      { "type": "field", "domain":   ["geosite:category-ads-all"], "outboundTag": "block" }
    ]
  }
}
JSONEOF
    if start_xray && wait_for_port >/dev/null 2>&1; then
        log_event INFO "generate_config engine_started port=${XRAY_PORT}"
        echo -e "  ${GREEN}✔ Engine started on port ${XRAY_PORT}.${NC}"
    else
        log_event WARN "generate_config engine_maybe_not_bound port=${XRAY_PORT}"
        echo -e "  ${YELLOW}⚠ Engine may not have bound to port ${XRAY_PORT}.${NC}"
    fi
    if ensure_codespace_port_public; then
        log_event INFO "generate_config port_public port=${XRAY_PORT}"
    else
        log_event WARN "generate_config port_public_failed port=${XRAY_PORT}"
        echo -e "  ${YELLOW}⚠ Could not set Codespaces port ${XRAY_PORT} public. Check the PORTS tab.${NC}"
    fi
}

generate_link_for_address() {
    local address="$1" label_suffix="${2:-}" uuid
    uuid=$(cat "$UUID_FILE" 2>/dev/null) || { printf ''; return 1; }
    [[ -z "$uuid" ]] && { printf ''; return 1; }
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2&insecure=1&allowInsecure=1&type=xhttp&host=%s&path=%%2F&mode=packet-up#G2rayXCodeLeafy|%s' \
        "$uuid" "$address" "$XRAY_PORT" "$PORT_DOMAIN" "$PORT_DOMAIN" "${GITHUB_USER:-User}${label_suffix}"
}

generate_domain_link() {
    generate_link_for_address "$PORT_DOMAIN"
}

generate_ip_link() {
    local address; address=$(resolve_domain_ips "$PORT_DOMAIN" | head -1 || true)
    [[ -n "$address" ]] || return 1
    generate_link_for_address "$address" "-ip1"
}

generate_ip_links() {
    local address index=1
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        generate_link_for_address "$address" "-ip${index}"
        printf '\n'
        index=$(( index + 1 ))
    done < <(resolve_domain_ips "$PORT_DOMAIN")
}

generate_ordered_links() {
    local domain_link ip_links
    ip_links=$(generate_ip_links || true)
    printf '%s\n' "$ip_links" | awk 'NF'
    domain_link=$(generate_domain_link || true)
    if [[ -n "$domain_link" ]] && ! printf '%s\n' "$ip_links" | grep -Fxq "$domain_link"; then
        printf '%s\n' "$domain_link"
    fi
}

write_config_exports_from_links() {
    local links encoded count hash
    links=$(printf '%s\n' "$@" | awk 'NF')
    [[ -n "$links" ]] || return 1
    _atomic_write "$MOBILE_CONFIG_FILE" "$links"
    if command -v base64 >/dev/null 2>&1; then
        encoded=$(printf '%s\n' "$links" | base64 | tr -d '\n')
        _atomic_write "$SUBSCRIPTION_FILE" "$encoded"
    fi
    count=$(printf '%s\n' "$links" | awk 'NF {c++} END {print c+0}')
    hash=$(fingerprint_secret "$links")
    log_event INFO "config_exports refreshed count=${count} hash=${hash}"
}

refresh_config_exports() {
    [[ -f "$UUID_FILE" ]] || return 0
    local link_array=()
    mapfile -t link_array < <(generate_ordered_links | awk 'NF' || true)
    ((${#link_array[@]})) || return 1
    write_config_exports_from_links "${link_array[@]}"
}

generate_link() {
    generate_domain_link
}

generate_links_for_display() {
    local uuid; uuid=$(cat "$UUID_FILE" 2>/dev/null) || { printf ''; return 1; }
    [[ -z "$uuid" ]] && { printf ''; return 1; }
    printf '%s\n' "$(generate_domain_link)"
    generate_ip_links
}

do_donate_config() {
    check_port_visibility || return 0
    local vless; vless=$(generate_link)
    if [[ -z "$vless" ]]; then
        echo -e "  ${RED}✖ No config found. Generate one first (Option 2).${NC}"
        sleep 2; return 0
    fi
    refresh_screen
    echo -e "\n  ${GREEN}● Donate Configuration${NC}"
    echo -e "  ${WHITE}Help others connect securely for free.${NC}"
    echo -e "  ${DIM}• No speed or quota penalty.\n  • IP is already public; no extra risk.${NC}\n"
    echo -ne "  ${GREEN}╰─❯${NC} Confirm donation? (y/n): "
    read -r d
    if [[ "$d" =~ ^[Yy]$ ]]; then
        send_to_vless_forwarder "$vless"
        touch "$DATA_DIR/.prompted_$(printf '%s' "$vless" | md5sum | awk '{print $1}')"
    fi
    sleep 2
}

show_diagnostics() {
    refresh_screen
    log_event INFO "diagnostics opened"
    echo -e "\n  ${RED}● Diagnostics${NC}\n"
    echo -e "  Identity : ${WHITE}${CODESPACE_NAME}${NC}"
    echo -e "  Domain   : ${WHITE}${PORT_DOMAIN}${NC}"
    echo -e "  Port     : ${WHITE}${XRAY_PORT}${NC}"
    if command -v git >/dev/null 2>&1; then
        echo -e "  Git      : ${DIM}$(git -C "$BASE_DIR" log --oneline -1 2>/dev/null || echo unknown)${NC}"
    fi
    if xray_running; then
        local xpid; xpid=$(cat "$XRAY_PID_FILE" 2>/dev/null || pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" | head -1 || true)
        echo -e "  Engine   : ${GREEN}Running${NC} ${DIM}(PID ${xpid:-unknown})${NC}"
    else
        echo -e "  Engine   : ${RED}Stopped${NC}"
    fi
    is_port_open \
        && echo -e "  Listener : ${GREEN}Port ${XRAY_PORT} open${NC}" \
        || echo -e "  Listener : ${RED}Port ${XRAY_PORT} closed${NC}"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        local cfg_line cfg_network cfg_security cfg_path cfg_mode cfg_uuid
        cfg_line=$(jq -r '.inbounds[]? | select(.tag=="vless-in") |
            [.streamSettings.network // "-", .streamSettings.security // "-",
             .streamSettings.xhttpSettings.path // "-", .streamSettings.xhttpSettings.mode // "-",
             .settings.clients[0].id // ""] | @tsv' "$CONFIG_FILE" 2>/dev/null | head -1)
        if [[ -n "$cfg_line" ]]; then
            IFS=$'\t' read -r cfg_network cfg_security cfg_path cfg_mode cfg_uuid <<< "$cfg_line"
            echo -e "  Config    : ${WHITE}${cfg_network}/${cfg_security}${NC} ${DIM}path=${cfg_path} mode=${cfg_mode} uuid_hash=$(fingerprint_secret "$cfg_uuid")${NC}"
        fi
    fi

    echo -e "\n  ${WHITE}${B}Codespaces Ports${NC}"
    if command -v gh >/dev/null 2>&1; then
        GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GH_FORCE_TTY=0 \
            gh codespace ports -c "$CODESPACE_NAME" 2>/dev/null | sed 's/^/  /' \
            || echo -e "  ${YELLOW}Could not query gh codespace ports.${NC}"
    else
        echo -e "  ${DIM}gh CLI unavailable.${NC}"
    fi

    echo -e "\n  ${WHITE}${B}XHTTP Probes${NC}"
    local local_probe edge_probe local_usable=false edge_usable=false
    local_probe=$(xhttp_probe_status local)
    edge_probe=$(xhttp_probe_status external)
    xhttp_status_usable "$local_probe" && local_usable=true
    xhttp_status_usable "$edge_probe" && edge_usable=true
    echo -e "  Local OPTIONS : ${WHITE}HTTP ${local_probe}${NC} ${DIM}(usable=${local_usable})${NC}"
    echo -e "  Edge OPTIONS  : ${WHITE}HTTP ${edge_probe}${NC} ${DIM}(usable=${edge_usable})${NC}"
    echo -e "  ${DIM}HTTP 404 here means the Codespaces edge has not routed this Host/path to Xray yet.${NC}"

    echo -e "\n  ${WHITE}${B}Fallback IP Candidates${NC}"
    echo -e "  ${DIM}(includes resolved, manual, and built-in fallbacks)${NC}"
    local ips; ips=$(resolve_domain_ips "$PORT_DOMAIN" || true)
    if [[ -n "$ips" ]]; then
        printf '%s\n' "$ips" | sed 's/^/  /'
    else
        echo -e "  ${YELLOW}No IP candidates resolved from this environment.${NC}"
    fi

    echo -e "\n  ${WHITE}${B}Recent G2ray Events${NC}"
    if [[ -s "$LOG_FILE" ]]; then
        tail -n 18 "$LOG_FILE" | sed 's/^/  /'
    else
        echo -e "  ${DIM}No G2ray app events yet.${NC}"
    fi

    echo -e "\n  ${WHITE}${B}Recent Xray Errors${NC}"
    if [[ -s "$LOG_DIR/xray-error.log" ]]; then
        tail -n 10 "$LOG_DIR/xray-error.log" | sed 's/^/  /'
    else
        echo -e "  ${DIM}No Xray errors logged.${NC}"
    fi
    echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

force_reconnect() {
    local no_prompt="${1:-}" failed=0
    log_event INFO "force_reconnect begin no_prompt=${no_prompt:-false}"
    echo -e "\n  ${GREEN}⠋${NC} ${WHITE}Running Clean Hard Restart & Reconnect Sequence...${NC}\n"

    echo -ne "  ${DIM}├─${NC} Detect Identity   : "
    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
    log_event INFO "force_reconnect identity codespace=${CODESPACE_NAME} domain=${PORT_DOMAIN}"
    [[ "$CODESPACE_NAME" == "unknown-codespace" ]] \
        && echo -e "${RED}Failed${NC}" \
        || echo -e "${GREEN}${CODESPACE_NAME}${NC}"

    echo -ne "  ${DIM}├─${NC} Force Kill Engine : "
    if stop_xray >/dev/null 2>&1; then
        log_event INFO "force_reconnect stopped_previous_engine"
        echo -e "${GREEN}Done${NC}"
    else
        failed=1
        log_event ERROR "force_reconnect stop_engine failed"
        echo -e "${RED}Failed${NC}"
    fi

    echo -ne "  ${DIM}├─${NC} Start Engine      : "
    if start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1; then
        log_event INFO "force_reconnect start_engine ok port=${XRAY_PORT}"
        echo -e "${GREEN}OK${NC}"
    else
        failed=1
        log_event ERROR "force_reconnect start_engine failed port=${XRAY_PORT}"
        echo -e "${RED}Failed${NC}"
    fi

    echo -ne "  ${DIM}├─${NC} Expose Tunnel     : "
    if ensure_codespace_port_public >/dev/null 2>&1; then
        log_event INFO "force_reconnect expose_tunnel ok port=${XRAY_PORT}"
        echo -e "${GREEN}Done${NC}"
    else
        failed=1
        log_event WARN "force_reconnect expose_tunnel failed port=${XRAY_PORT}"
        echo -e "${YELLOW}Needs PORTS tab${NC}"
    fi

    echo -ne "  ${DIM}╰─${NC} Verify External   : "
    local edge_reachable=false xhttp_route_usable=false code xcode
    for _i in 1 2 3 4; do
        code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://${PORT_DOMAIN}" 2>/dev/null || echo "0")
        [[ "$code" != "000" && "$code" != "0" ]] && edge_reachable=true
        xcode=$(xhttp_probe_status external)
        if xhttp_status_usable "$xcode"; then
            xhttp_route_usable=true
            break
        fi
        sleep 2
    done
    if [[ "$edge_reachable" == true && "$xhttp_route_usable" != true ]]; then
        repair_codespace_port_route >/dev/null 2>&1 || true
        sleep 3
        xcode=$(xhttp_probe_status external)
        xhttp_status_usable "$xcode" && xhttp_route_usable=true
    fi
    log_event INFO "force_reconnect verify_external edge_reachable=${edge_reachable} code=${code:-none} xhttp_probe=${xcode:-none} xhttp_route_usable=${xhttp_route_usable} domain=${PORT_DOMAIN}"
    [[ "$edge_reachable" == true && "$xhttp_route_usable" == true ]] || failed=1
    if [[ "$xhttp_route_usable" == true ]]; then
        reset_route_bad_count
        echo -e "${GREEN}XHTTP route usable (HTTP ${xcode})${NC}\n"
    elif [[ "$edge_reachable" == true ]]; then
        echo -e "${YELLOW}Edge reachable but route settling (HTTP ${xcode:-0})${NC}\n"
    else
        echo -e "${YELLOW}Pending / delayed (HTTP ${code:-0})${NC}\n"
    fi

    [[ "$no_prompt" == "--no-prompt" ]] && { sleep 1; return "$failed"; }
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
    return 0
}

if [[ "${1:-}" == "--silent-start" ]]; then
    stop_xray >/dev/null 2>&1
    if [[ -f "$CONFIG_FILE" ]] && start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1; then
        ensure_codespace_port_public >/dev/null 2>&1 || true
    fi
    start_background_tasks
    exit 0
fi

cleanup() {
    local code=$?
    save_xray_stats 2>/dev/null || true
    save_session_uptime 2>/dev/null || true
    echo -e "\n  ${DIM}Goodbye.${NC}"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_for_updates "$@"
start_background_tasks
fetch_remote_message
enable_anti_sleep

if [[ ! -f "$CONFIG_FILE" ]]; then
    refresh_screen
    echo -e "  ${GREEN}● Welcome to G2ray${NC}"
    echo -e "  ${WHITE}No configuration found. First run setup.${NC}\n"
    echo -e "  ${RED}1)${NC} Generate Config & Start"
    echo -e "  ${DIM}2)${NC} Exit\n"
    echo -ne "  ${RED}╰─❯${NC} "
    read -r setup
    if [[ "$setup" == "1" ]]; then
        generate_config
        echo -e "\n  ${GREEN}✔ Setup complete!${NC}"
        sleep 1
    else
        exit 0
    fi
else
    refresh_screen
    force_reconnect --no-prompt || true
fi

while true; do
    ( fetch_remote_message >/dev/null 2>&1 & )
    refresh_screen

    if xray_running; then
        _STATUS="${GREEN}▶ RUNNING${NC}"
    else
        _STATUS="${RED}■ STOPPED${NC}"
    fi

    if tmux has-session -t g2ray_keepalive 2>/dev/null; then
        _KA="${GREEN}Enabled${NC}"
    else
        _KA="${DIM}Disabled${NC}"
    fi

    echo -e "  ${WHITE}${B}Engine Status  :${NC} $(echo -e "$_STATUS")"
    echo -e "  ${WHITE}${B}Anti-Sleep Mode:${NC} $(echo -e "$_KA")\n"
    echo -e "  ${WHITE}${B}● CORE CONTROLS${NC}"
    echo -e "   ${RED}1)${NC} View Config & QR Code       ${RED}4)${NC} Stop Engine"
    echo -e "   ${RED}2)${NC} Generate New Config         ${RED}5)${NC} Restart Engine"
    echo -e "   ${RED}3)${NC} Start Engine                ${RED}6)${NC} Force Reconnect"
    echo ""
    echo -e "  ${WHITE}${B}● SYSTEM CONFIGURATION${NC}"
    echo -e "   ${RED}7)${NC} Toggle Anti-Sleep Mode"
    echo -e "   ${RED}8)${NC} Donate Config"
    echo ""
    echo -e "  ${WHITE}${B}● ANALYTICS & TOOLS${NC}"
    echo -e "   ${RED}9)${NC} Data Usage                 ${RED}12)${NC} Server Location"
    echo -e "  ${RED}10)${NC} Resource Stats             ${RED}13)${NC} View Engine Logs"
    echo -e "  ${RED}14) Diagnostics${NC}"
    echo -e "  ${RED}11)${NC} Quota & Uptime"
    echo ""
    echo -e "   ${RED}0)${NC} Exit Panel"
    echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"

    if [[ -s "/tmp/g2ray_message.txt" ]]; then
        local_msg=$(sed 's/\r//g' /tmp/g2ray_message.txt 2>/dev/null)
        if [[ "$local_msg" != *"404"* && -n "$(printf '%s' "$local_msg" | tr -d ' \n\t')" ]]; then
            echo -e "  ${YELLOW}📢 Dev Note: ${WHITE}${local_msg}${NC}"
            echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"
        fi
    fi

    echo -ne "  ${RED}╰─❯${NC} "
    read -r _choice

    case $_choice in
        1)
            check_port_visibility || continue
            _VLESS_DOMAIN=$(generate_domain_link) || _VLESS_DOMAIN=""
            _VLESS_IPS=$(generate_ip_links) || _VLESS_IPS=""
            mapfile -t _VLESS_IP_ARRAY < <(printf '%s\n' "$_VLESS_IPS" | awk 'NF')
            _CONFIG_LINKS=()
            _CONFIG_LABELS=()
            _DOMAIN_ALREADY=false
            for _LINK in "${_VLESS_IP_ARRAY[@]}"; do
                [[ -n "$_LINK" ]] || continue
                if ((${#_CONFIG_LINKS[@]} == 0)); then
                    _CONFIG_LABELS+=("Recommended IP link (try this first)")
                else
                    _CONFIG_LABELS+=("IP fallback link $((${#_CONFIG_LINKS[@]} + 1))")
                fi
                _CONFIG_LINKS+=("$_LINK")
                [[ "$_LINK" == "$_VLESS_DOMAIN" ]] && _DOMAIN_ALREADY=true
            done
            if [[ -n "$_VLESS_DOMAIN" && "$_DOMAIN_ALREADY" != true ]]; then
                if ((${#_CONFIG_LINKS[@]} == 0)); then
                    _CONFIG_LABELS+=("Recommended domain link")
                else
                    _CONFIG_LABELS+=("Domain link (try only if app.github.dev is allowed)")
                fi
                _CONFIG_LINKS+=("$_VLESS_DOMAIN")
            fi
            _VLESS_PRIMARY="${_CONFIG_LINKS[0]:-}"
            [[ -z "$_VLESS_PRIMARY" ]] && { echo -e "  ${RED}✖ Error generating link.${NC}"; sleep 2; continue; }
            write_config_exports_from_links "${_CONFIG_LINKS[@]}" >/dev/null 2>&1 || true
            _VHASH=$(printf '%s' "$_VLESS_PRIMARY" | md5sum | awk '{print $1}')
            _PFLAG="$DATA_DIR/.prompted_${_VHASH}"
            if [[ ! -f "$_PFLAG" ]]; then
                refresh_screen
                echo -e "  ${GREEN}🎉 Node is Ready!${NC}\n"
                echo -e "  ${WHITE}Donate this config to help others connect freely?${NC}"
                echo -e "  ${DIM}(No impact on your speed, quota, or security)${NC}\n"
                echo -ne "  ${GREEN}╰─❯${NC} Donate? (y/n): "
                read -r _share
                [[ "$_share" =~ ^[Yy]$ ]] && { send_to_vless_forwarder "$_VLESS_PRIMARY"; sleep 1; }
                touch "$_PFLAG"
            fi
            refresh_screen
            echo -e "  ${RED}● Configs & Compact QR Codes${NC}"
            echo -e "  ${DIM}Raw links are printed without color codes and saved to:${NC}"
            echo -e "  ${DIM}Base64 subscription export:${NC} ${WHITE}${SUBSCRIPTION_FILE}${NC}"
            echo -e "  ${WHITE}${MOBILE_CONFIG_FILE}${NC}\n"
            _INDEX=1
            _QR_MODE="${G2RAY_QR_MODE:-recommended}"
            for _LINK in "${_CONFIG_LINKS[@]}"; do
                _SHOW_QR=false
                [[ "$_QR_MODE" == "all" || ( "$_QR_MODE" != "none" && $_INDEX -eq 1 ) ]] && _SHOW_QR=true
                render_config_entry "$_INDEX" "${_CONFIG_LABELS[$((_INDEX - 1))]}" "$_LINK" "$_SHOW_QR"
                _INDEX=$((_INDEX + 1))
            done
            echo -e "  ${DIM}IP links keep ${PORT_DOMAIN} as SNI/Host for Codespaces routing.${NC}\n"
            _COUNTRY=$(curl -s --max-time 3 https://ipinfo.io/country </dev/null 2>/dev/null || echo "Unknown")
            if [[ "$_COUNTRY" != "DE" && "$_COUNTRY" != "NL" && "$_COUNTRY" != "Unknown" ]]; then
                echo -e "  ${RED}WARNING: Codespace is NOT in Germany (${_COUNTRY})!${NC}"
                echo -e "  ${DIM}Set region to 'Europe West' in GitHub for optimal speeds.${NC}\n"
            fi
            echo -e "  ${DIM}Not working? Visit:${NC} ${GREEN}https://code-leafy.github.io/NetLeafy${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        2)
            echo -e "\n  ${YELLOW}⚠ Overwrite current config and restart engine?${NC}"
            echo -ne "  ${GREEN}╰─❯${NC} Proceed (y/n): "
            read -r _confirm
            [[ "$_confirm" =~ ^[Yy]$ ]] && { generate_config; sleep 1; }
            ;;
        3)
            if xray_running; then
                echo -e "\n  ${WHITE}Engine is already running.${NC}"
            else
                if start_xray && wait_for_port; then
                    ensure_codespace_port_public \
                        || echo -e "  ${YELLOW}⚠ Could not set port public. Use the PORTS tab.${NC}"
                fi
            fi
            sleep 1
            ;;
        4)
            stop_xray
            echo -e "\n  ${RED}■ Engine stopped.${NC}"
            sleep 1
            ;;
        5)
            if start_xray && wait_for_port; then
                ensure_codespace_port_public \
                    || echo -e "  ${YELLOW}⚠ Could not set port public. Use the PORTS tab.${NC}"
            fi
            sleep 1
            ;;
        6) force_reconnect ;;
        7)
            if tmux has-session -t g2ray_keepalive 2>/dev/null; then
                tmux kill-session -t g2ray_keepalive
                echo -e "\n  ${RED}■ Anti-Sleep disabled.${NC}"
            else
                enable_anti_sleep
                echo -e "\n  ${GREEN}▶ Anti-Sleep enabled.${NC}"
            fi
            sleep 2
            ;;
        8) do_donate_config ;;
        9)
            refresh_screen
            read -r _TD _TU <<< "$(get_data_usage)"
            _TD=${_TD:-0}; _TU=${_TU:-0}
            if (( _TD == 0 && _TU == 0 )); then
                echo -e "\n  ${DIM}No traffic data recorded yet. Connect and browse first.${NC}\n"
            else
                _TT=$(( _TD + _TU ))
                echo -e "\n  ${GREEN}● Data Usage (All Sessions)${NC}"
                echo -e "  Download (RX) : ${WHITE}$(format_bytes "$_TD")${NC}"
                echo -e "  Upload   (TX) : ${WHITE}$(format_bytes "$_TU")${NC}"
                echo -e "  Total Traffic : ${GREEN}$(format_bytes "$_TT")${NC}\n"
            fi
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        10) show_resource_stats ;;
        11)
            refresh_screen; echo ""
            estimate_quota
            echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        12)
            refresh_screen
            echo -e "\n  ${DIM}Fetching server details...${NC}\n"
            if command -v jq >/dev/null 2>&1; then
                _RES=$(curl -sf -m 5 https://ipinfo.io/json 2>/dev/null || echo "{}")
                _IP=$(printf '%s' "$_RES" | jq -r '.ip // empty' 2>/dev/null || true)
                if [[ -z "$_IP" ]]; then
                    echo -e "  ${RED}✖ Could not fetch location.${NC}"
                else
                    echo -e "  ${GREEN}● Server Location${NC}"
                    echo -e "  IP       : ${GREEN}$(printf '%s' "$_RES" | jq -r '.ip')${NC}"
                    echo -e "  Location : ${WHITE}$(printf '%s' "$_RES" | jq -r '.city'), $(printf '%s' "$_RES" | jq -r '.country')${NC}"
                    echo -e "  ISP/Host : ${WHITE}$(printf '%s' "$_RES" | jq -r '.org')${NC}"
                fi
            else
                echo -e "  ${RED}✖ jq not installed.${NC}"
            fi
            echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        13)
            refresh_screen
            echo -e "\n  ${GREEN}● Live Engine Logs${NC}"
            if [[ -s "$LOG_DIR/xray.log" ]]; then
                tail -n 15 "$LOG_DIR/xray.log" | sed 's/^/  /'
            else
                echo -e "  ${DIM}Log file empty or missing.${NC}"
            fi
            echo -e "\n  ${DIM}(Log level: warning — empty log means no errors)${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        14) show_diagnostics ;;
        0) echo -e "\n  ${GREEN}Exiting G2ray Panel...${NC}"; exit 0 ;;
        *) echo -e "  ${RED}✖ Invalid option.${NC}"; sleep 1 ;;
    esac
done
