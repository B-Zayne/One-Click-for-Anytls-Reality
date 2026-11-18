#!/usr/bin/env bash

set -eo pipefail

# ------------------------------------------------------------------------------
# 全局变量与路径定义
# ------------------------------------------------------------------------------
readonly CONFIG_PATH="/etc/sing-box/config.json"
readonly INFO_PATH="/root/.sb_info.json"
readonly TLS_DIR="/root/AnyTLS/tls"
readonly SERVICE_NAME="sing-box"
readonly LOCAL_SCRIPT_PATH="/root/any.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ------------------------------------------------------------------------------
# 辅助 UI 与工具函数
# ------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

pause() {
    echo -e "\n${YELLOW}按任意键继续...${NC}"
    read -n 1 -s -r
}

check_root() {
    # 修复：使用更通用的 id -u，防止 Alpine 环境下 $EUID 变量缺失
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "本脚本需要 Root 权限运行，请使用 'sudo -i' 切换到 Root 用户后再试。"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 跨平台服务管理抽象层 (兼容 Systemd 与 OpenRC)
# ------------------------------------------------------------------------------
svc_cmd() {
    local action=$1
    if command -v systemctl >/dev/null 2>&1; then
        case "$action" in
            start) systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
            stop) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
            restart) systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
            enable) systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
            disable) systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
            status) systemctl status "$SERVICE_NAME" --no-pager || true ;;
            is-active) systemctl is-active --quiet "$SERVICE_NAME" ;;
            daemon-reload) systemctl daemon-reload >/dev/null 2>&1 || true ;;
            logs) journalctl -u "$SERVICE_NAME" -e -f -n 50 || true ;;
        esac
    elif command -v rc-service >/dev/null 2>&1; then
        case "$action" in
            start) rc-service "$SERVICE_NAME" start >/dev/null 2>&1 || true ;;
            stop) rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
            restart) rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || true ;;
            enable) rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true ;;
            disable) rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true ;;
            status) rc-service "$SERVICE_NAME" status || true ;;
            is-active) rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started" ;;
            daemon-reload) : ;; # OpenRC 不需要
            logs) 
                if [ -f /var/log/sing-box.log ]; then
                    tail -f -n 50 /var/log/sing-box.log
                else
                    echo -e "${YELLOW}在 Alpine 中未检测到物理日志文件，或服务未产生输出。${NC}"
                fi
                ;;
        esac
    fi
}

# ------------------------------------------------------------------------------
# 强制性全局注册函数
# ------------------------------------------------------------------------------
force_register_shortcut() {
    if [[ -s "$0" ]]; then
        cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi

    if [[ ! -s "$LOCAL_SCRIPT_PATH" ]]; then
        curl -fsSL https://raw.githubusercontent.com/xymn2023/AnyTLS/main/Any.sh -o "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi
    chmod +x "$LOCAL_SCRIPT_PATH" 2>/dev/null || true

    local target_paths=("/usr/local/bin/any" "/usr/bin/any")
    for path in "${target_paths[@]}"; do
        rm -rf "$path" 2>/dev/null || true
        cat << 'EOF' > "$path"
#!/usr/bin/env bash
if [[ -f /root/any.sh ]]; then
    bash /root/any.sh "$@"
else
    bash <(curl -fsSL https://raw.githubusercontent.com/xymn2023/AnyTLS/main/Any.sh) "$@"
fi
EOF
        chmod +x "$path" 2>/dev/null || true
    done
}

validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then return 0; else return 1; fi
}

check_and_print_port_status() {
    local port="$1"
    if command -v ss &>/dev/null && ss -tuln | grep -q ":${port} "; then
        log_warn "检测到端口 ${port} ${RED}已被占用${NC}！"; return 1
    elif command -v netstat &>/dev/null && netstat -tuln | grep -q ":${port} "; then
        log_warn "检测到端口 ${port} ${RED}已被占用${NC}！"; return 1
    elif command -v lsof &>/dev/null && lsof -i:"${port}" &>/dev/null; then
        log_warn "检测到端口 ${port} ${RED}已被占用${NC}！"; return 1
    fi
    log_success "检测到端口 ${port} ${GREEN}未被占用${NC}，可以使用。"
    return 0
}

get_public_ip() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    if [[ -z "$ip" ]]; then ip=$(curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || true); fi
    echo "${ip:-127.0.0.1}"
}

open_firewall_port() {
    local port="$1"
    log_info "尝试放行防火墙端口 ${port}..."
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    if [[ -f "$CONFIG_PATH" && -f "$INFO_PATH" ]]; then
        local installed_proto=""
        if jq -e .reality "$INFO_PATH" >/dev/null 2>&1 && jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
            installed_proto="双协议 (AnyReality + AnyTLS)"
        elif jq -e .reality "$INFO_PATH" >/dev/null 2>&1; then installed_proto="AnyReality"
        elif jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then installed_proto="AnyTLS"
        else installed_proto="空节点 (保留内核)"
        fi

        if svc_cmd is-active; then
            # 兼容 Alpine busybox pgrep
            local pid=$(pgrep -x "sing-box" | head -n 1 || echo "未知")
            echo -e " 服务状态: ${GREEN}${BOLD}● 已安装并正常运行中${NC} (PID: ${pid})"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● 已安装但未运行 (已停止)${NC}"
        fi
        echo -e " 节点配置: ${CYAN}${installed_proto}${NC}"
    else
        echo -e " 服务状态: ${RED}${BOLD}○ 未安装 / 未配置${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

# ------------------------------------------------------------------------------
# 依赖与环境准备 (100% 兼容 Alpine)
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "检查并安装必要依赖组件..."
    rm -f /etc/sing-box/client_info.json

    if command -v apk &>/dev/null; then
        apk update -q
        apk add -q --no-cache curl jq net-tools openssl lsof grep
    elif command -v apt-get &>/dev/null; then
        apt-get update -y -qq
        apt-get install -y -qq curl jq net-tools openssl lsof grep
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl jq net-tools openssl lsof grep
    elif command -v yum &>/dev/null; then
        yum install -y -q curl jq net-tools openssl lsof grep
    fi

    log_info "正在拉取 Sing-Box (Beta 官方内核)..."
    # 修复：容忍官方脚本在 Alpine 环境下因为没有 systemctl 报错中断
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --beta >/dev/null 2>&1 || true

    # 验证二进制文件是否真正落地
    if ! command -v sing-box &>/dev/null && [ ! -f /usr/local/bin/sing-box ]; then
        log_error "Sing-Box 二进制文件安装失败，请检查服务器网络。"
        pause; return 1
    fi
    log_success "Sing-Box 二进制内核就绪！"

    # 修复：如果是 Alpine(OpenRC)，官方脚本不提供守护进程，我们必须手动注入服务脚本
    if command -v rc-update &>/dev/null; then
        log_info "检测到 OpenRC 环境，正在注入并注册 Alpine 本地服务..."
        local sb_bin
        sb_bin=$(command -v sing-box || echo "/usr/local/bin/sing-box")
        cat << EOF > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="${sb_bin}"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/\${name}.pid"
output_log="/var/log/\${name}.log"
error_log="/var/log/\${name}.err"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
    fi
}

generate_cert() {
    local sni="$1"
    mkdir -p "$TLS_DIR"
    log_info "正在为域名 [ ${sni} ] 生成自签名 ECC 证书..."
    # 修复：移除 Bash 专属进程替换 <()，改用原生标准 -pkeyopt 以完全适配 Alpine 底层 OpenSSL
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" \
        -subj "/CN=${sni}" -days 3650 >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# 安装与节点配置
# ------------------------------------------------------------------------------
install_node() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}             配置 Sing-Box 节点协议                 ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e " 1. 单独部署 ${BOLD}AnyReality${NC}"
    echo -e " 2. 单独部署 ${BOLD}AnyTLS${NC}"
    echo -e " 3. 双协议同时部署 (${BOLD}AnyReality + AnyTLS${NC})"
    echo -e " 0. 返回主菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    local mode
    read -rp " 请选择运行模式 [0-3]: " mode
    case "$mode" in
        1|2|3) ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac

    install_dependencies || return

    local inbounds_json="[]"
    local info_json="{}"
    local sb_bin=$(command -v sing-box || echo "/usr/local/bin/sing-box")

    if [[ "$mode" == "1" || "$mode" == "3" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 AnyReality <<<<${NC}"
        local r_port r_pwd r_sni
        while :; do
            read -rp " 请输入端口 [默认: 1443]: " r_port
            r_port=${r_port:-1443}
            if ! validate_port "$r_port"; then log_warn "端口号不合法"; continue; fi
            if ! check_and_print_port_status "$r_port"; then continue; fi
            break
        done
        read -rp " 请输入密码 [默认: 自动生成]: " r_pwd
        r_pwd=${r_pwd:-$(openssl rand -hex 16)}
        read -rp " 请输入 Reality 伪装域名 [默认: genshin.hoyoverse.com]: " r_sni
        r_sni=${r_sni:-genshin.hoyoverse.com}

        log_info "正在生成 REALITY 密钥对..."
        local keypair priv_key pub_key short_id
        keypair=$("$sb_bin" generate reality-keypair)
        priv_key=$(echo "$keypair" | grep -i Private | awk '{print $2}')
        pub_key=$(echo "$keypair" | grep -i Public | awk '{print $2}')
        short_id=$(openssl rand -hex 8)

        local r_inbound
        r_inbound=$(jq -n \
            --arg p "$r_port" --arg w "$r_pwd" --arg s "$r_sni" --arg k "$priv_key" --arg id "$short_id" \
            '{type: "anytls", listen: "::", listen_port: ($p|tonumber), users: [{name: "user", password: $w}], padding_scheme: ["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"], tls: {enabled: true, server_name: $s, reality: {enabled: true, handshake: {server: $s, server_port: 443}, private_key: $k, short_id: [$id]}}}')
        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$r_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$r_port" --arg w "$r_pwd" --arg s "$r_sni" --arg pk "$pub_key" --arg id "$short_id" '. + {reality: {port: $p, pwd: $w, sni: $s, pk: $pk, id: $id}}')
        open_firewall_port "$r_port"
    fi

    if [[ "$mode" == "2" || "$mode" == "3" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 AnyTLS <<<<${NC}"
        local t_port t_pwd t_sni
        while :; do
            read -rp " 请输入端口 [默认: 2026]: " t_port
            t_port=${t_port:-2026}
            if ! validate_port "$t_port"; then log_warn "端口号不合法"; continue; fi
            if [[ "$mode" == "3" && "$t_port" == "$r_port" ]]; then log_warn "端口不能重复！"; continue; fi
            if ! check_and_print_port_status "$t_port"; then continue; fi
            break
        done
        read -rp " 请输入密码 [默认: 自动生成]: " t_pwd
        t_pwd=${t_pwd:-$(openssl rand -hex 16)}
        read -rp " 请输入 TLS 伪装域名 [默认: genshin.hoyoverse.com]: " t_sni
        t_sni=${t_sni:-genshin.hoyoverse.com}

        generate_cert "$t_sni"

        local t_inbound
        t_inbound=$(jq -n \
            --arg p "$t_port" --arg w "$t_pwd" \
            '{type: "anytls", listen: "::", listen_port: ($p|tonumber), users: [{password: $w}], padding_scheme: ["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"], tls: {enabled: true, certificate_path: "/root/AnyTLS/tls/server.crt", key_path: "/root/AnyTLS/tls/server.key"}}')
        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$t_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$t_port" --arg w "$t_pwd" --arg s "$t_sni" '. + {anytls: {port: $p, pwd: $w, sni: $s}}')
        open_firewall_port "$t_port"
    fi

    echo "$info_json" > "$INFO_PATH"
    mkdir -p "$(dirname "$CONFIG_PATH")"
    jq -n --argjson ib "$inbounds_json" '{log: {level: "info", timestamp: true}, inbounds: $ib}' > "$CONFIG_PATH"

    log_info "正在启动与重载 Sing-Box 服务..."
    svc_cmd daemon-reload
    svc_cmd enable
    svc_cmd restart

    log_success "部署完全成功！"
    pause
    show_links
}

# ------------------------------------------------------------------------------
# 节点删除与清理 (保留内核)
# ------------------------------------------------------------------------------
delete_nodes() {
    clear
    echo -e "${RED}=====================================================${NC}"
    echo -e "${BOLD}               清空所有节点并保留内核               ${NC}"
    echo -e "${RED}=====================================================${NC}"
    read -rp " 此操作将删除所有协议配置，但保留 Sing-box 服务以便后续一键部署。继续吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "{}" > "$INFO_PATH"
        mkdir -p "$(dirname "$CONFIG_PATH")"
        jq -n '{log: {level: "info", timestamp: true}, inbounds: []}' > "$CONFIG_PATH"
        svc_cmd restart
        log_success "配置已清空，节点已移除。Sing-box 此时处于空载运行状态。"
    else
        log_info "已取消删除操作。"
    fi
    pause
}

# ------------------------------------------------------------------------------
# UI 与状态展示模块
# ------------------------------------------------------------------------------
show_links() {
    clear
    if [[ ! -f "$INFO_PATH" ]]; then
        log_warn "未找到节点配置元数据，请先进行部署。"
        pause; return
    fi
    local ip=$(get_public_ip)
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}               已生成的节点连接信息                ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"

    if jq -e .reality "$INFO_PATH" >/dev/null 2>&1; then
        local p=$(jq -r .reality.port "$INFO_PATH") w=$(jq -r .reality.pwd "$INFO_PATH") s=$(jq -r .reality.sni "$INFO_PATH") k=$(jq -r .reality.pk "$INFO_PATH") d=$(jq -r .reality.id "$INFO_PATH")
        echo -e "${GREEN}[ AnyReality 节点 ]: ${NC}"
        echo -e "${YELLOW}anytls://${w}@${ip}:${p}/?sni=${s}&fp=chrome&pbk=${k}&sid=${d}#AnyReality_${ip}${NC}\n"
    fi

    if jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
        local p=$(jq -r .anytls.port "$INFO_PATH") w=$(jq -r .anytls.pwd "$INFO_PATH") s=$(jq -r .anytls.sni "$INFO_PATH")
        echo -e "${GREEN}[ AnyTLS 节点 ]: ${NC}"
        echo -e "${YELLOW}anytls://${w}@${ip}:${p}/?sni=${s}&insecure=1#AnyTLS_${ip}${NC}\n"
    fi
    echo -e "${CYAN}=====================================================${NC}"
    pause
}

manage_service() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e " 1. 启动服务\n 2. 停止服务\n 3. 重启服务\n 0. 返回上一菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    read -rp " 请选择操作 [0-3]: " act
    case "$act" in
        1) svc_cmd start && log_success "服务启动成功！" ;;
        2) svc_cmd stop && log_success "服务已停止！" ;;
        3) svc_cmd restart && log_success "服务重启成功！" ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac
    pause
}

uninstall_all() {
    clear
    read -rp " 确定要彻底卸载 Sing-Box 及其所有配置文件吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        svc_cmd stop
        svc_cmd disable
        if command -v systemctl >/dev/null 2>&1; then
            rm -f /etc/systemd/system/"$SERVICE_NAME".service; systemctl daemon-reload >/dev/null 2>&1 || true
        elif command -v rc-update >/dev/null 2>&1; then
            rm -f /etc/init.d/"$SERVICE_NAME"
        fi
        rm -f /usr/bin/"$SERVICE_NAME" /usr/local/bin/"$SERVICE_NAME" /usr/local/bin/any /usr/bin/any "$LOCAL_SCRIPT_PATH"
        rm -rf /etc/"$SERVICE_NAME" "$INFO_PATH" /root/AnyTLS
        log_success "彻底清理卸载完成！"
    fi
    pause
}

# ------------------------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------------------------
main_menu() {
    check_root
    force_register_shortcut

    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}       Sing-Box (AnyTLS / AnyReality) 管理脚本       ${NC}"
        print_system_status
        echo -e " ${GREEN}1.${NC} 安装 / 重构节点"
        echo -e " ${GREEN}2.${NC} 服务管理 (启动/停止/重启)"
        echo -e " ${GREEN}3.${NC} 查看节点链接"
        echo -e " ${GREEN}4.${NC} 查看运行状态"
        echo -e " ${GREEN}5.${NC} 查看实时日志"
        echo -e " ${RED}6.${NC} 彻底卸载核心系统"
        echo -e " ${RED}7.${NC} 清空并删除节点 ${YELLOW}(保留内核)${NC}"
        echo -e " ${YELLOW}0.${NC} 退出脚本"
        echo -e "${CYAN}=====================================================${NC}"

        read -rp " 请输入选项 [0-7]: " opt
        case "$opt" in
            1) install_node ;;
            2) manage_service ;;
            3) show_links ;;
            4) clear; svc_cmd status; pause ;;
            5) clear; svc_cmd logs; pause ;;
            6) uninstall_all ;;
            7) delete_nodes ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

main_menu
