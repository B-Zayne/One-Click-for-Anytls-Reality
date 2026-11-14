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

# 颜色与样式
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
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 Root 权限运行，请使用 'sudo -i' 切换到 Root 用户后再试。"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 全局快捷指令注册 ('any' 命令)
# ------------------------------------------------------------------------------
force_register_shortcut() {
    if [[ -s "$0" && "$0" != "/dev/fd/"* && "$0" != "/proc/"* && "$0" != "bash" && "$0" != "-bash" ]]; then
        if [[ "$(realpath "$0" 2>/dev/null)" != "$LOCAL_SCRIPT_PATH" ]]; then
            cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
        fi
    fi

    chmod +x "$LOCAL_SCRIPT_PATH" 2>/dev/null || true

    local target_paths=("/usr/local/bin/any" "/usr/bin/any")
    for path in "${target_paths[@]}"; do
        rm -rf "$path" 2>/dev/null || true
        cat << 'EOF' > "$path"
#!/usr/bin/env bash
if [[ -f /root/any.sh ]]; then
    exec bash /root/any.sh "$@"
else
    echo "未找到本地脚本 /root/any.sh，请重新运行安装命令。"
    exit 1
fi
EOF
        chmod +x "$path" 2>/dev/null || true
    done
}

# 校验端口格式
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 检测端口占用并实时在屏幕打印结果
check_and_print_port_status() {
    local port="$1"
    local is_busy=0

    if command -v ss &>/dev/null; then
        ss -tuln | grep -qE ":${port}([[:space:]]|$)" && is_busy=1
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -qE ":${port}([[:space:]]|$)" && is_busy=1
    elif command -v lsof &>/dev/null; then
        lsof -i:"${port}" &>/dev/null && is_busy=1
    fi

    if [[ $is_busy -eq 1 ]]; then
        log_warn "检测到端口 ${port} ${RED}已被占用${NC}！"
        return 1
    else
        log_success "检测到端口 ${port} ${GREEN}未被占用${NC}，可以使用。"
        return 0
    fi
}

# 双源检测本机是否具备有效公网 IPv4 出口 (防止 NAT 共享 IP 单源超时误判)
has_public_ipv4() {
    local ip4
    ip4=$(curl -s4 --connect-timeout 4 https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$ip4" || "$ip4" == *:* ]]; then
        ip4=$(curl -s4 --connect-timeout 4 https://4.ipw.cn 2>/dev/null || true)
    fi
    [[ -n "$ip4" && "$ip4" != *:* ]]
}

# 获取公网 IP (兼容纯 IPv4 / 双栈 / 纯 IPv6)
get_public_ip() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s4 --connect-timeout 5 https://4.ipw.cn 2>/dev/null || true)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 --connect-timeout 5 https://api64.ipify.org 2>/dev/null || true)
    fi
    echo "${ip:-127.0.0.1}"
}

# 自动放行防火墙端口
open_firewall_port() {
    local port="$1"
    log_info "正在为您自动放行防火墙端口 ${port}..."
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        log_success "UFW 防火墙端口 ${port} 放行成功！"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_success "Firewalld 防火墙端口 ${port} 放行成功！"
    fi
}

# 打印当前系统的安装与运行状态卡片
print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    if [[ -f "$CONFIG_PATH" && -f "$INFO_PATH" ]]; then
        local installed_proto=""
        if jq -e .reality "$INFO_PATH" >/dev/null 2>&1 && jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
            installed_proto="双协议 (AnyReality + AnyTLS)"
        elif jq -e .reality "$INFO_PATH" >/dev/null 2>&1; then
            installed_proto="AnyReality"
        elif jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
            installed_proto="AnyTLS"
        else
            installed_proto="未知配置"
        fi

        if systemctl is-active --quiet "$SERVICE_NAME"; then
            local pid
            pid=$(pgrep -f "sing-box" | head -n 1 || echo "未知")
            echo -e " 服务状态: ${GREEN}${BOLD}● 已安装并正常运行中${NC} (PID: ${pid})"
            echo -e " 已配置项: ${CYAN}${installed_proto}${NC}"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● 已安装但未运行 (已停止)${NC}"
            echo -e " 已配置项: ${CYAN}${installed_proto}${NC}"
        fi
    elif [[ -x /usr/bin/sing-box ]]; then
        local sb_ver
        sb_ver=$(/usr/bin/sing-box version 2>/dev/null | awk '/sing-box version/ {print $3}' || echo "已就绪")
        echo -e " 服务状态: ${YELLOW}${BOLD}○ 内核已安装 (${sb_ver}) / 节点未配置${NC}"
    else
        echo -e " 服务状态: ${RED}${BOLD}○ 未安装 / 未配置${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

# ------------------------------------------------------------------------------
# 依赖与环境准备
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "检查并安装必要依赖组件..."
    rm -f /etc/sing-box/client_info.json

    if command -v apt-get &>/dev/null; then
        apt-get update -y -qq
        apt-get install -y -qq curl jq net-tools openssl lsof
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl jq net-tools openssl lsof
    elif command -v yum &>/dev/null; then
        yum install -y -q curl jq net-tools openssl lsof
    fi

    if [[ -x /usr/bin/sing-box ]]; then
        log_success "检测到本地已存在 Sing-Box 内核，跳过重复安装。"
    else
        log_info "正在安装 Sing-Box (官方正式版内核)..."
        if curl -fsSL https://sing-box.app/install.sh | sh; then
            log_success "Sing-Box 核心组件安装完毕！"
        else
            log_error "Sing-Box 安装失败，请检查服务器网络。"
            pause
            return 1
        fi
    fi
}

update_singbox_core() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}              更新 Sing-Box 官方内核                ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    log_info "正在从官方源更新 Sing-Box 内核..."
    if curl -fsSL https://sing-box.app/install.sh | sh; then
        systemctl daemon-reload
        [[ -f "$CONFIG_PATH" ]] && systemctl restart "$SERVICE_NAME"
        log_success "Sing-Box 内核更新完毕！"
    else
        log_error "Sing-Box 内核更新失败，请检查服务器网络。"
    fi
    pause
}

# ------------------------------------------------------------------------------
# 证书生成模块
# ------------------------------------------------------------------------------
generate_cert() {
    local sni="$1"
    mkdir -p "$TLS_DIR"
    log_info "正在为域名 [ ${sni} ] 生成自签名 ECC 证书..."

    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$TLS_DIR/server.key" \
        -out "$TLS_DIR/server.crt" \
        -subj "/CN=${sni}" -days 3650 >/dev/null 2>&1

    if [[ -f "$TLS_DIR/server.key" && -f "$TLS_DIR/server.crt" ]]; then
        log_success "TLS 证书及私钥生成成功！"
    else
        log_error "证书生成失败！"
        pause
        exit 1
    fi
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
        *) log_error "无效选项，请输入 0-3 中的数字。"; sleep 1; return ;;
    esac

    clear
    install_dependencies || return

    local inbounds_json="[]"
    local info_json="{}"
    local r_port="" r_ext_port="" t_port="" t_ext_port=""

    # 1) 配置 AnyReality
    if [[ "$mode" == "1" || "$mode" == "3" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 AnyReality <<<<${NC}"

        while :; do
            read -rp " 请输入本机监听端口 [默认: 1443]: " r_port
            r_port=${r_port:-1443}
            if ! validate_port "$r_port"; then
                log_warn "端口号不合法，请输入 1-65535 之间的整数。"
                continue
            fi
            if ! check_and_print_port_status "$r_port"; then
                continue
            fi
            break
        done

        while :; do
            read -rp " 请输入外部连接端口 (NAT 机器若内外端口不同请填写，独立 VPS 直接回车) [默认: ${r_port}]: " r_ext_port
            r_ext_port=${r_ext_port:-$r_port}
            if ! validate_port "$r_ext_port"; then
                log_warn "外部端口号不合法，请输入 1-65535 之间的整数。"
                continue
            fi
            break
        done

        local r_pwd r_sni
        read -rp " 请输入密码 [默认: 自动生成]: " r_pwd
        r_pwd=${r_pwd:-$(openssl rand -hex 16)}

        read -rp " 请输入 Reality 伪装域名 [默认: genshin.hoyoverse.com]: " r_sni
        r_sni=${r_sni:-genshin.hoyoverse.com}

        log_info "正在生成 REALITY 密钥对..."
        local keypair
        keypair=$(/usr/bin/sing-box generate reality-keypair)
        local priv_key pub_key short_id
        priv_key=$(echo "$keypair" | grep -i Private | awk '{print $2}')
        pub_key=$(echo "$keypair" | grep -i Public | awk '{print $2}')
        short_id=$(openssl rand -hex 8)

        local r_inbound
        r_inbound=$(jq -n \
            --arg p "$r_port" \
            --arg w "$r_pwd" \
            --arg s "$r_sni" \
            --arg k "$priv_key" \
            --arg id "$short_id" \
            '{
                type: "anytls",
                listen: "::",
                listen_port: ($p | tonumber),
                users: [{ name: "user", password: $w }],
                padding_scheme: ["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
                tls: {
                    enabled: true,
                    server_name: $s,
                    reality: {
                        enabled: true,
                        handshake: { server: $s, server_port: 443 },
                        private_key: $k,
                        short_id: [$id]
                    }
                }
            }')

        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$r_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$r_port" --arg ep "$r_ext_port" --arg w "$r_pwd" --arg s "$r_sni" --arg pk "$pub_key" --arg id "$short_id" \
            '. + {reality: {port: $p, ext_port: $ep, pwd: $w, sni: $s, pk: $pk, id: $id}}')

        open_firewall_port "$r_port"
        log_success "AnyReality 参数配置完成！"
    fi

    # 2) 配置 AnyTLS
    if [[ "$mode" == "2" || "$mode" == "3" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 AnyTLS <<<<${NC}"

        while :; do
            read -rp " 请输入本机监听端口 [默认: 2026]: " t_port
            t_port=${t_port:-2026}
            if ! validate_port "$t_port"; then
                log_warn "端口号不合法，请输入 1-65535 之间的整数。"
                continue
            fi
            if [[ "$mode" == "3" && "$t_port" == "$r_port" ]]; then
                log_warn "端口不能与 AnyReality 端口重复！"
                continue
            fi
            if ! check_and_print_port_status "$t_port"; then
                continue
            fi
            break
        done

        while :; do
            read -rp " 请输入外部映射端口 (NAT 机器若内外端口不同请填写，独立 VPS 直接回车) [默认: ${t_port}]: " t_ext_port
            t_ext_port=${t_ext_port:-$t_port}
            if ! validate_port "$t_ext_port"; then
                log_warn "外部端口号不合法，请输入 1-65535 之间的整数。"
                continue
            fi
            break
        done

        local t_pwd t_sni
        read -rp " 请输入密码 [默认: 自动生成]: " t_pwd
        t_pwd=${t_pwd:-$(openssl rand -hex 16)}

        read -rp " 请输入 TLS 伪装域名 [默认: genshin.hoyoverse.com]: " t_sni
        t_sni=${t_sni:-genshin.hoyoverse.com}

        generate_cert "$t_sni"

        local t_inbound
        t_inbound=$(jq -n \
            --arg p "$t_port" \
            --arg w "$t_pwd" \
            '{
                type: "anytls",
                listen: "::",
                listen_port: ($p | tonumber),
                users: [{ password: $w }],
                padding_scheme: ["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
                tls: {
                    enabled: true,
                    certificate_path: "/root/AnyTLS/tls/server.crt",
                    key_path: "/root/AnyTLS/tls/server.key"
                }
            }')

        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$t_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$t_port" --arg ep "$t_ext_port" --arg w "$t_pwd" --arg s "$t_sni" \
            '. + {anytls: {port: $p, ext_port: $ep, pwd: $w, sni: $s}}')

        open_firewall_port "$t_port"
        log_success "AnyTLS 参数配置完成！"
    fi

    # 保存配置：阻断机房 IPv6 出口（DNS ipv4_only + 路由直接拦截 ::/0），避免 YouTube 播放加长无法跳过广告
    echo "$info_json" > "$INFO_PATH"
    mkdir -p "$(dirname "$CONFIG_PATH")"

    if has_public_ipv4; then
        log_info "检测到本机具备公网 IPv4 出口，已启用纯 IPv4 出口与 IPv6 阻断策略..."
        jq -n --argjson ib "$inbounds_json" '{
            log: {level: "info", timestamp: true},
            dns: {
                servers: [
                    {type: "local", tag: "local"}
                ]
            },
            inbounds: $ib,
            outbounds: [
                {type: "direct", tag: "direct"}
            ],
            route: {
                rules: [
                    {ip_cidr: ["::/0"], action: "reject"}
                ],
                default_domain_resolver: {
                    server: "local",
                    strategy: "ipv4_only"
                }
            }
        }' > "$CONFIG_PATH"
    else
        log_info "检测到纯 IPv6 环境，已配置 IPv6 兼容出站策略..."
        jq -n --argjson ib "$inbounds_json" '{
            log: {level: "info", timestamp: true},
            inbounds: $ib,
            outbounds: [{type: "direct", tag: "direct"}]
        }' > "$CONFIG_PATH"
    fi

    log_info "正在启动与重载 Sing-Box 服务..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    log_success "恭喜！Sing-Box 节点配置与部署完全成功！"
    pause
    show_links
}

# ------------------------------------------------------------------------------
# 节点链接展示
# ------------------------------------------------------------------------------
show_links() {
    clear
    if [[ ! -f "$INFO_PATH" ]]; then
        log_warn "未找到节点配置元数据，请先进行部署。"
        pause
        return
    fi

    local ip host
    ip=$(get_public_ip)
    host="$ip"
    [[ "$ip" == *:* ]] && host="[$ip]"

    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}               已生成的节点连接信息                ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"

    if jq -e .reality "$INFO_PATH" >/dev/null 2>&1; then
        local p ep w s k d
        p=$(jq -r .reality.port "$INFO_PATH")
        ep=$(jq -r '.reality.ext_port // .reality.port' "$INFO_PATH")
        w=$(jq -r .reality.pwd "$INFO_PATH")
        s=$(jq -r .reality.sni "$INFO_PATH")
        k=$(jq -r .reality.pk "$INFO_PATH")
        d=$(jq -r .reality.id "$INFO_PATH")

        if [[ "$p" != "$ep" ]]; then
            echo -e "${BLUE}[提示] 内网监听端口: ${p} -> 外部连接端口: ${ep}${NC}"
        fi
        echo -e "${GREEN}[ AnyReality 节点链接 ]: ${NC}"
        echo -e "${YELLOW}anytls://${w}@${host}:${ep}/?sni=${s}&fp=chrome&pbk=${k}&sid=${d}#AnyReality_${ip}${NC}\n"

        echo -e "${GREEN}[ Sing-Box 客户端 outbound JSON ]: ${NC}"
        jq -n --arg server "$ip" --argjson port "$ep" --arg password "$w" --arg sni "$s" --arg pk "$k" --arg sid "$d" '{
            type: "anytls",
            tag: "anytls-reality-out",
            server: $server,
            server_port: $port,
            password: $password,
            tls: {
                enabled: true,
                server_name: $sni,
                utls: { enabled: true, fingerprint: "chrome" },
                reality: { enabled: true, public_key: $pk, short_id: $sid }
            }
        }'
        echo
    fi

    if jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
        local p ep w s
        p=$(jq -r .anytls.port "$INFO_PATH")
        ep=$(jq -r '.anytls.ext_port // .anytls.port' "$INFO_PATH")
        w=$(jq -r .anytls.pwd "$INFO_PATH")
        s=$(jq -r .anytls.sni "$INFO_PATH")

        if [[ "$p" != "$ep" ]]; then
            echo -e "${BLUE}[提示] 内网监听端口: ${p} -> 外部连接端口: ${ep}${NC}"
        fi
        echo -e "${GREEN}[ AnyTLS 节点链接 ]: ${NC}"
        echo -e "${YELLOW}anytls://${w}@${host}:${ep}/?sni=${s}&insecure=1#AnyTLS_${ip}${NC}\n"
    fi
    echo -e "${CYAN}=====================================================${NC}"
    pause
}

# ------------------------------------------------------------------------------
# 服务管理与状态模块
# ------------------------------------------------------------------------------
manage_service() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                   服务控制面板                     ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e " 1. 启动服务"
    echo -e " 2. 停止服务"
    echo -e " 3. 重启服务"
    echo -e " 4. 更新 Sing-Box 内核"
    echo -e " 0. 返回上一菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    read -rp " 请选择操作 [0-4]: " act
    case "$act" in
        1) systemctl start "$SERVICE_NAME" && log_success "Sing-Box 服务启动成功！" ;;
        2) systemctl stop "$SERVICE_NAME" && log_success "Sing-Box 服务已停止！" ;;
        3) systemctl restart "$SERVICE_NAME" && log_success "Sing-Box 服务重启成功！" ;;
        4) update_singbox_core; return ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac
    pause
}

show_status() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}               Sing-Box 服务运行状态                ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    systemctl status "$SERVICE_NAME" --no-pager || true
    echo -e "\n${CYAN}=====================================================${NC}"
    pause
}

show_logs() {
    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}      正在查看实时日志 (退出日志预览按 Ctrl+C)      ${NC}"
        echo -e "${CYAN}=====================================================${NC}\n"

        trap - INT
        journalctl -u "$SERVICE_NAME" -e -f -n 50 || true

        trap 'echo -e "\n${RED}[!] 操作被用户中断${NC}"; exit 1' INT TERM

        echo -e "\n${CYAN}-----------------------------------------------------${NC}"
        echo -e " 1. 刷新重新查看日志"
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"

        read -rp " 请选择 [0-1]: " log_opt
        case "$log_opt" in
            1) continue ;;
            0) break ;;
            *) break ;;
        esac
    done
}

# 仅删除节点配置与自签证书，保留 Sing-Box 内核与脚本
clear_config_only() {
    clear
    echo -e "${YELLOW}=====================================================${NC}"
    echo -e "${BOLD}          删除节点配置 (保留 Sing-Box 内核)          ${NC}"
    echo -e "${YELLOW}=====================================================${NC}"
    read -rp " 确定要删除当前节点配置、密钥与自签证书（保留内核与脚本）吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在停止服务并清理节点配置文件..."
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

        rm -rf /etc/"$SERVICE_NAME" "$INFO_PATH" /root/AnyTLS

        log_success "节点配置、密钥与自签证书已全部删除！Sing-Box 内核已保留，随时可选 1 重新配置。"
    else
        log_info "已取消操作。"
    fi
    pause
}

uninstall_all() {
    clear
    echo -e "${RED}=====================================================${NC}"
    echo -e "${BOLD}                 彻底卸载 Sing-Box                  ${NC}"
    echo -e "${RED}=====================================================${NC}"
    read -rp " 确定要彻底卸载 Sing-Box 及其所有配置文件吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理并卸载..."
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

        rm -f /etc/systemd/system/"$SERVICE_NAME".service
        rm -f /usr/bin/"$SERVICE_NAME" /usr/local/bin/"$SERVICE_NAME" /usr/local/bin/any /usr/bin/any "$LOCAL_SCRIPT_PATH"
        rm -rf /etc/"$SERVICE_NAME" "$INFO_PATH" /root/AnyTLS

        systemctl daemon-reload
        log_success "Sing-Box 及脚本组件已彻底清理卸载完成！"
    else
        log_info "已取消卸载。"
    fi
    pause
}

# ------------------------------------------------------------------------------
# 主菜单循环
# ------------------------------------------------------------------------------
main_menu() {
    check_root
    force_register_shortcut

    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}       Sing-Box (AnyTLS / AnyReality) 管理脚本       ${NC}"
        echo -e "         快捷指令: 在终端输入 ${YELLOW}${BOLD}any${NC} 即可快速打开"

        print_system_status

        echo -e " ${GREEN}1.${NC} 安装 / 重构节点"
        echo -e " ${GREEN}2.${NC} 服务管理 (启动/停止/重启/更新内核)"
        echo -e " ${GREEN}3.${NC} 查看节点链接"
        echo -e " ${GREEN}4.${NC} 查看运行状态"
        echo -e " ${GREEN}5.${NC} 查看实时日志"
        echo -e " ${YELLOW}6.${NC} 删除节点配置 (保留 Sing-Box 内核)"
        echo -e " ${RED}7.${NC} 彻底卸载 Sing-Box"
        echo -e " ${YELLOW}0.${NC} 退出脚本"
        echo -e "${CYAN}=====================================================${NC}"

        read -rp " 请输入选项 [0-7]: " opt
        case "$opt" in
            1) install_node ;;
            2) manage_service ;;
            3) show_links ;;
            4) show_status ;;
            5) show_logs ;;
            6) clear_config_only ;;
            7) uninstall_all ;;
            0)
                clear
                echo -e "${GREEN}感谢使用！随时输入 'any' 唤醒本脚本。${NC}"
                exit 0
                ;;
            *)
                log_error "请输入正确的选项 [0-7]"
                sleep 1
                ;;
        esac
    done
}

main_menu
