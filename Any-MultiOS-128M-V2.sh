#!/bin/sh
# ==============================================================================
# Sing-Box (AnyTLS / AnyReality) 管理脚本
#   - 兼容 Debian / Ubuntu / CentOS / Alpine (systemd 与 OpenRC)
#   - 针对 128MB 小内存 VPS 做了专项优化
#   - 支持「仅删除节点、保留内核」
# ==============================================================================

# ------------------------------------------------------------------------------
# 引导段 (POSIX sh)：Alpine 默认没有 bash，先自动安装并切换到 bash 重新执行
# ------------------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            echo "[INFO] 未检测到 bash，正在通过 apk 安装..."
            apk add --no-cache bash >/dev/null 2>&1 || { echo "[ERROR] bash 安装失败，请检查网络/软件源。"; exit 1; }
        else
            echo "[ERROR] 本脚本需要 bash，请先安装 bash。"
            exit 1
        fi
    fi
    if [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    # 通过管道运行 (curl ... | sh) 时 $0 不是文件，先落盘再执行
    _boot_tmp="/tmp/.any_boot.sh"
    _boot_url="https://raw.githubusercontent.com/xymn2023/AnyTLS/main/Any.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_boot_url" -o "$_boot_tmp" || exit 1
    else
        wget -qO "$_boot_tmp" "$_boot_url" || exit 1
    fi
    exec bash "$_boot_tmp" "$@"
fi

# ------------------------------------------------------------------------------
# 以下均为 bash
# ------------------------------------------------------------------------------
set -eo pipefail

# ------------------------------------------------------------------------------
# 全局变量与路径定义
# ------------------------------------------------------------------------------
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_PATH="/etc/sing-box/config.json"
readonly INFO_PATH="/root/.sb_info.json"
readonly TLS_DIR="/root/AnyTLS/tls"
readonly SERVICE_NAME="sing-box"
readonly LOCAL_SCRIPT_PATH="/root/any.sh"
readonly SCRIPT_URL="https://raw.githubusercontent.com/xymn2023/AnyTLS/main/Any.sh"
readonly SB_LOG_FILE="/var/log/sing-box.log"          # 仅 OpenRC 使用
readonly OPENRC_SCRIPT="/etc/init.d/sing-box"
readonly SYSTEMD_DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly LOW_MEM_THRESHOLD_MB=256                      # ≤ 此值视为小内存机器

# 运行期环境信息 (由 detect_env 填充)
IS_ALPINE=0
OS_NAME="linux"
INIT_SYSTEM="none"       # systemd / openrc / none
MEM_TOTAL_MB=0
LOW_MEM=0
SB_BIN=""

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

print_header() {
    local title="$1" color="${2:-$CYAN}"
    echo -e "${color}=====================================================${NC}"
    echo -e "${BOLD}  ${title}${NC}"
    echo -e "${color}=====================================================${NC}"
}

pause() {
    echo -e "\n${YELLOW}按任意键继续...${NC}"
    read -n 1 -s -r || true
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 Root 权限运行，请使用 'sudo -i' 切换到 Root 用户后再试。"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 环境检测：发行版 / 初始化系统 / 内存
# ------------------------------------------------------------------------------
detect_env() {
    if [[ -f /etc/alpine-release ]]; then
        IS_ALPINE=1
    fi

    OS_NAME=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)
    OS_NAME=${OS_NAME:-linux}

    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    fi

    local kb
    kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)
    MEM_TOTAL_MB=$(( ${kb:-0} / 1024 ))
    if [[ $MEM_TOTAL_MB -gt 0 && $MEM_TOTAL_MB -le $LOW_MEM_THRESHOLD_MB ]]; then
        LOW_MEM=1
    fi

    SB_BIN=$(command -v sing-box 2>/dev/null || true)
}

# Go 运行时内存上限 (MiB)：约为物理内存的 55%，最低 40
calc_go_mem_limit() {
    local lim=$(( MEM_TOTAL_MB * 55 / 100 ))
    if [[ $lim -lt 40 ]]; then lim=40; fi
    echo "$lim"
}

# ------------------------------------------------------------------------------
# 服务管理抽象层 (systemd / OpenRC)
# ------------------------------------------------------------------------------
svc_enable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl daemon-reload; systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 ;;
    esac
}

svc_disable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)  rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 ;;
    esac
}

svc_start() {
    case "$INIT_SYSTEM" in
        systemd) systemctl start "$SERVICE_NAME" ;;
        openrc)  rc-service "$SERVICE_NAME" start ;;
        *)       return 1 ;;
    esac
}

svc_stop() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "$SERVICE_NAME" ;;
        openrc)  rc-service "$SERVICE_NAME" stop ;;
        *)       return 1 ;;
    esac
}

svc_restart() {
    case "$INIT_SYSTEM" in
        systemd) systemctl restart "$SERVICE_NAME" ;;
        openrc)  rc-service "$SERVICE_NAME" restart ;;
        *)       return 1 ;;
    esac
}

svc_is_active() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$SERVICE_NAME" ;;
        openrc)  rc-service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

svc_status() {
    case "$INIT_SYSTEM" in
        systemd) systemctl status "$SERVICE_NAME" --no-pager || true ;;
        openrc)  rc-service "$SERVICE_NAME" status || true ;;
        *)       log_warn "未检测到 systemd 或 OpenRC。" ;;
    esac
}

# ------------------------------------------------------------------------------
# 强制性全局注册函数 ('any' 命令)
# ------------------------------------------------------------------------------
force_register_shortcut() {
    # 仅当 $0 是真实文件时才复制 (避免 bash <(curl ...) 的管道被读空)
    if [[ -f "$0" && -s "$0" && "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$LOCAL_SCRIPT_PATH" ]]; then
        cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi

    if [[ ! -s "$LOCAL_SCRIPT_PATH" ]]; then
        curl -fsSL "$SCRIPT_URL" -o "$LOCAL_SCRIPT_PATH" 2>/dev/null || \
        wget -qO "$LOCAL_SCRIPT_PATH" "$SCRIPT_URL" 2>/dev/null || true
    fi
    chmod +x "$LOCAL_SCRIPT_PATH" 2>/dev/null || true

    local path
    for path in /usr/local/bin/any /usr/bin/any; do
        [[ -d "$(dirname "$path")" ]] || continue
        rm -rf "$path" 2>/dev/null || true
        cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ -f ${LOCAL_SCRIPT_PATH} ]]; then
    exec bash ${LOCAL_SCRIPT_PATH} "\$@"
else
    exec bash <(curl -fsSL ${SCRIPT_URL}) "\$@"
fi
EOF
        chmod +x "$path" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------------------
# 网络 / 端口 / 防火墙
# ------------------------------------------------------------------------------
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]]
}

# 检测端口占用并打印结果 (返回 0 = 可用, 1 = 被占用)
check_and_print_port_status() {
    local port="$1" out="" is_busy=0

    if command -v ss &>/dev/null; then
        out=$(ss -tuln 2>/dev/null || true)
    elif command -v netstat &>/dev/null; then
        out=$(netstat -tuln 2>/dev/null || true)
    elif command -v lsof &>/dev/null; then
        lsof -i:"${port}" &>/dev/null && is_busy=1
    fi

    if [[ -n "$out" ]] && grep -Eq "[:.]${port}[[:space:]]" <<<"$out"; then
        is_busy=1
    fi

    if [[ $is_busy -eq 1 ]]; then
        log_warn "检测到端口 ${port} ${RED}已被占用${NC}！"
        return 1
    fi
    log_success "检测到端口 ${port} ${GREEN}未被占用${NC}，可以使用。"
    return 0
}

# 获取公网 IP (多源 + 校验)
get_public_ip() {
    local ip="" flag svc
    for flag in -4 -6; do
        for svc in ifconfig.me api64.ipify.org icanhazip.com; do
            ip=$(curl -s "$flag" --connect-timeout 4 --max-time 8 "https://${svc}" 2>/dev/null | tr -d '[:space:]' || true)
            if [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
                echo "$ip"
                return 0
            fi
        done
    done
    echo "127.0.0.1"
}

_ufw_active()      { command -v ufw &>/dev/null && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; }
_firewalld_active() { command -v firewall-cmd &>/dev/null && [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl is-active --quiet firewalld; }

open_firewall_port() {
    local port="$1"
    log_info "正在为您自动放行防火墙端口 ${port}..."
    if _ufw_active; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        log_success "UFW 防火墙端口 ${port} 放行成功！"
    elif _firewalld_active; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_success "Firewalld 防火墙端口 ${port} 放行成功！"
    fi
}

close_firewall_port() {
    local port="$1"
    if _ufw_active; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    elif _firewalld_active; then
        firewall-cmd --zone=public --remove-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# 按 INFO 文件里记录的端口回收防火墙规则
cleanup_firewall_rules() {
    [[ -f "$INFO_PATH" ]] || return 0
    local ports p
    ports=$(jq -r '[.reality.port?, .anytls.port?] | map(select(. != null)) | .[]' "$INFO_PATH" 2>/dev/null || true)
    for p in $ports; do
        close_firewall_port "$p"
    done
}

# ------------------------------------------------------------------------------
# 状态卡片
# ------------------------------------------------------------------------------
core_version() {
    [[ -n "$SB_BIN" ]] || return 0
    "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}' || true
}

print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    local env_line=" 环境: ${OS_NAME} / ${INIT_SYSTEM} / 内存 ${MEM_TOTAL_MB}MB"
    if [[ $LOW_MEM -eq 1 ]]; then
        env_line+=" ${GREEN}[低内存优化已启用]${NC}"
    fi
    echo -e "$env_line"

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

        if svc_is_active; then
            local pid
            pid=$(pidof sing-box 2>/dev/null | awk '{print $1}' || true)
            echo -e " 服务状态: ${GREEN}${BOLD}● 已安装并正常运行中${NC} (PID: ${pid:-未知})"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● 已安装但未运行 (已停止)${NC}"
        fi
        echo -e " 已配置项: ${CYAN}${installed_proto}${NC}"
    elif [[ -n "$SB_BIN" ]]; then
        echo -e " 服务状态: ${YELLOW}${BOLD}○ 仅保留内核，未配置节点${NC} (内核: $(core_version))"
    else
        echo -e " 服务状态: ${RED}${BOLD}○ 未安装 / 未配置${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

# ------------------------------------------------------------------------------
# 依赖安装 (仅安装缺失项，节省时间/内存)
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "检查并安装必要依赖组件..."

    local need=() c
    for c in curl jq openssl; do
        command -v "$c" &>/dev/null || need+=("$c")
    done

    # 端口检测工具：busybox (Alpine) 自带 netstat；其它系统缺失时补 iproute2
    local need_ss=0
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null && ! command -v lsof &>/dev/null; then
        need_ss=1
    fi

    if [[ ${#need[@]} -eq 0 && $need_ss -eq 0 ]]; then
        log_success "依赖已满足，跳过安装。"
        return 0
    fi

    if command -v apk &>/dev/null; then
        apk add --no-cache "${need[@]}" ca-certificates >/dev/null
    elif command -v apt-get &>/dev/null; then
        [[ $need_ss -eq 1 ]] && need+=("iproute2")
        apt-get update -y -qq
        apt-get install -y -qq "${need[@]}" ca-certificates
    elif command -v dnf &>/dev/null; then
        [[ $need_ss -eq 1 ]] && need+=("iproute")
        dnf install -y -q "${need[@]}" ca-certificates
    elif command -v yum &>/dev/null; then
        [[ $need_ss -eq 1 ]] && need+=("iproute")
        yum install -y -q "${need[@]}" ca-certificates
    else
        log_error "未识别的包管理器，请手动安装: ${need[*]}"
        return 1
    fi
    log_success "依赖安装完成。"
}

# ------------------------------------------------------------------------------
# Swap (小内存保护)
# ------------------------------------------------------------------------------
setup_swap_if_needed() {
    [[ $LOW_MEM -eq 1 ]] || return 0

    local swap_kb
    swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)
    [[ "${swap_kb:-0}" -eq 0 ]] || return 0

    # 根分区若是内存文件系统 (Alpine diskless 模式)，建 Swap 无意义
    local root_fs
    root_fs=$(awk '$2=="/"{t=$3} END{print t}' /proc/mounts 2>/dev/null || true)
    if [[ "$root_fs" == "tmpfs" || "$root_fs" == "ramfs" || "$root_fs" == "rootfs" ]]; then
        log_warn "根分区位于内存中 (${root_fs})，跳过 Swap 创建。建议将系统安装到磁盘 (setup-alpine -> sys 模式)。"
        return 0
    fi

    log_warn "检测到物理内存仅 ${MEM_TOTAL_MB}MB 且未启用 Swap，可能在安装/运行时被 OOM。"
    local ans
    read -rp " 是否创建 256MB Swap 文件? [Y/n]: " ans
    [[ "$ans" =~ ^[Nn]$ ]] && return 0

    local f="/swapfile"
    if [[ -e "$f" ]]; then
        log_warn "${f} 已存在，跳过。"
        return 0
    fi

    if dd if=/dev/zero of="$f" bs=1M count=256 2>/dev/null \
        && chmod 600 "$f" && mkswap "$f" >/dev/null 2>&1 && swapon "$f" 2>/dev/null; then
        grep -q "^${f} " /etc/fstab 2>/dev/null || echo "${f} none swap sw 0 0" >> /etc/fstab
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-update add swap boot >/dev/null 2>&1 || true
        fi
        log_success "已创建并启用 256MB Swap。"
    else
        swapoff "$f" 2>/dev/null || true
        rm -f "$f"
        log_warn "Swap 创建失败 (容器/OpenVZ 常见限制)，已跳过。"
    fi
}

# ------------------------------------------------------------------------------
# Sing-Box 内核安装
# ------------------------------------------------------------------------------
# AnyTLS 入站需要 sing-box >= 1.12
core_supports_anytls() {
    local v major rest minor
    v=$(core_version)
    v=${v#v}
    [[ -n "$v" ]] || return 1
    major=${v%%.*}
    rest=${v#*.}
    minor=${rest%%.*}
    major=${major//[!0-9]/}
    minor=${minor//[!0-9]/}
    [[ -n "$major" && -n "$minor" ]] || return 1
    [[ "$major" -gt 1 || ( "$major" -eq 1 && "$minor" -ge 12 ) ]]
}

# 从 GitHub Release 下载 musl 构建 (适用于 Alpine)
install_core_github_musl() {
    local arch
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*)        arch="armv7" ;;
        i386|i686)     arch="386" ;;
        *) log_error "不支持的 CPU 架构: $(uname -m)"; return 1 ;;
    esac

    local final tag ver tmp file
    final=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest) || {
        log_error "无法获取最新版本号，请检查网络。"; return 1; }
    tag=${final##*/}
    ver=${tag#v}
    file="sing-box-${ver}-linux-${arch}-musl.tar.gz"

    tmp=$(mktemp -d)
    log_info "正在下载 ${file} ..."
    if ! curl -fSL --connect-timeout 15 -o "${tmp}/sb.tgz" \
        "https://github.com/SagerNet/sing-box/releases/download/${tag}/${file}"; then
        rm -rf "$tmp"
        log_error "下载失败。"
        return 1
    fi
    tar -xzf "${tmp}/sb.tgz" -C "$tmp"
    cp -f "${tmp}"/sing-box-*/sing-box /usr/local/bin/sing-box
    chmod 755 /usr/local/bin/sing-box
    rm -rf "$tmp"
}

install_core_alpine() {
    log_info "Alpine 系统：优先通过 apk 安装 sing-box ..."
    apk add --no-cache sing-box >/dev/null 2>&1 || true
    hash -r
    SB_BIN=$(command -v sing-box 2>/dev/null || true)

    if [[ -n "$SB_BIN" ]] && core_supports_anytls; then
        return 0
    fi

    log_warn "apk 源中的 sing-box 不可用或版本过旧 (AnyTLS 需 ≥ 1.12)，改为下载 GitHub musl 版本..."
    apk del sing-box >/dev/null 2>&1 || true
    hash -r
    install_core_github_musl
}

install_core() {
    if [[ $IS_ALPINE -eq 1 ]]; then
        install_core_alpine
    else
        log_info "正在安装/更新 Sing-Box (Beta 官方内核)..."
        curl -fsSL https://sing-box.app/install.sh | sh -s -- --beta
    fi
}

# 确保内核可用：已存在则默认沿用，避免重复下载
ensure_core() {
    hash -r
    SB_BIN=$(command -v sing-box 2>/dev/null || true)

    if [[ -n "$SB_BIN" ]]; then
        log_info "检测到已安装内核: $(core_version)"
        local ans=""
        read -rp " 是否更新内核? [y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            if core_supports_anytls; then
                log_success "沿用现有内核。"
                return 0
            fi
            log_warn "现有内核版本过旧，不支持 AnyTLS，将自动更新。"
        fi
    fi

    if install_core; then
        hash -r
        SB_BIN=$(command -v sing-box 2>/dev/null || true)
        if [[ -z "$SB_BIN" ]]; then
            log_error "未找到 sing-box 可执行文件。"
            pause
            return 1
        fi
        log_success "Sing-Box 核心组件安装/更新完毕！(${SB_BIN})"
    else
        log_error "Sing-Box 安装失败，请检查服务器网络。"
        pause
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 服务定义与低内存调优
# ------------------------------------------------------------------------------
write_openrc_service() {
    local env_lines=""
    if [[ $LOW_MEM -eq 1 ]]; then
        env_lines="export GOGC=50
export GOMEMLIMIT=$(calc_go_mem_limit)MiB"
    fi

    cat > "$OPENRC_SCRIPT" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service (AnyTLS / AnyReality)"
command="${SB_BIN}"
command_args="run -c ${CONFIG_PATH}"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="${SB_LOG_FILE}"
error_log="${SB_LOG_FILE}"
rc_ulimit="-n 65535"
${env_lines}

depend() {
    need net
    after firewall
}

start_pre() {
    # 日志超过 5MB 自动清空，防止撑满小硬盘/内存盘
    if [ -f "${SB_LOG_FILE}" ] && [ "\$(wc -c < "${SB_LOG_FILE}")" -gt 5242880 ]; then
        : > "${SB_LOG_FILE}"
    fi
    "${SB_BIN}" check -c "${CONFIG_PATH}"
}
EOF
    chmod +x "$OPENRC_SCRIPT"
}

apply_systemd_tuning() {
    if [[ $LOW_MEM -eq 1 ]]; then
        mkdir -p "$SYSTEMD_DROPIN_DIR"
        cat > "${SYSTEMD_DROPIN_DIR}/lowmem.conf" <<EOF
[Service]
Environment="GOGC=50"
Environment="GOMEMLIMIT=$(calc_go_mem_limit)MiB"
EOF
    else
        rm -f "${SYSTEMD_DROPIN_DIR}/lowmem.conf" 2>/dev/null || true
    fi
    systemctl daemon-reload
}

setup_service() {
    case "$INIT_SYSTEM" in
        systemd) apply_systemd_tuning ;;
        openrc)  write_openrc_service ;;
        *)
            log_error "未检测到 systemd 或 OpenRC，无法托管服务。"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 证书生成模块
# ------------------------------------------------------------------------------
generate_cert() {
    local sni="$1"
    mkdir -p "$TLS_DIR"
    log_info "正在为域名 [ ${sni} ] 生成自签名 ECC 证书..."

    if openssl ecparam -name prime256v1 -genkey -noout -out "$TLS_DIR/server.key" >/dev/null 2>&1 \
        && openssl req -new -x509 -key "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" \
            -subj "/CN=${sni}" -days 3650 >/dev/null 2>&1; then
        chmod 600 "$TLS_DIR/server.key"
        log_success "TLS 证书及私钥生成成功！"
    else
        log_error "证书生成失败！"
        pause
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 安装与节点配置
# ------------------------------------------------------------------------------
install_node() {
    clear
    print_header "配置 Sing-Box 节点协议"
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
    if [[ "$INIT_SYSTEM" == "none" ]]; then
        log_error "未检测到 systemd 或 OpenRC，无法继续。"
        pause
        return
    fi
    install_dependencies || { pause; return; }
    setup_swap_if_needed
    ensure_core || return

    local inbounds_json="[]"
    local info_json="{}"
    local log_level="info"
    [[ $LOW_MEM -eq 1 ]] && log_level="warn"

    # 1) 配置 AnyReality
    if [[ "$mode" == "1" || "$mode" == "3" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 AnyReality <<<<${NC}"

        local r_port r_pwd r_sni
        while :; do
            read -rp " 请输入端口 [默认: 1443]: " r_port
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

        read -rp " 请输入密码 [默认: 自动生成]: " r_pwd
        r_pwd=${r_pwd:-$(openssl rand -hex 16)}

        read -rp " 请输入 Reality 伪装域名 [默认: genshin.hoyoverse.com]: " r_sni
        r_sni=${r_sni:-genshin.hoyoverse.com}

        log_info "正在生成 REALITY 密钥对..."
        local keypair priv_key pub_key short_id
        keypair=$("$SB_BIN" generate reality-keypair)
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
        info_json=$(echo "$info_json" | jq --arg p "$r_port" --arg w "$r_pwd" --arg s "$r_sni" --arg pk "$pub_key" --arg id "$short_id" \
            '. + {reality: {port: $p, pwd: $w, sni: $s, pk: $pk, id: $id}}')

        open_firewall_port "$r_port"
        log_success "AnyReality 参数配置完成！"
    fi

    # 2) 配置 AnyTLS
    if [[ "$mode" == "2" || "$mode" == "3" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 AnyTLS <<<<${NC}"

        local t_port t_pwd t_sni
        while :; do
            read -rp " 请输入端口 [默认: 2026]: " t_port
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

        read -rp " 请输入密码 [默认: 自动生成]: " t_pwd
        t_pwd=${t_pwd:-$(openssl rand -hex 16)}

        read -rp " 请输入 TLS 伪装域名 [默认: genshin.hoyoverse.com]: " t_sni
        t_sni=${t_sni:-genshin.hoyoverse.com}

        generate_cert "$t_sni" || return

        local t_inbound
        t_inbound=$(jq -n \
            --arg p "$t_port" \
            --arg w "$t_pwd" \
            --arg crt "$TLS_DIR/server.crt" \
            --arg key "$TLS_DIR/server.key" \
            '{
                type: "anytls",
                listen: "::",
                listen_port: ($p | tonumber),
                users: [{ password: $w }],
                padding_scheme: ["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
                tls: {
                    enabled: true,
                    certificate_path: $crt,
                    key_path: $key
                }
            }')

        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$t_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$t_port" --arg w "$t_pwd" --arg s "$t_sni" \
            '. + {anytls: {port: $p, pwd: $w, sni: $s}}')

        open_firewall_port "$t_port"
        log_success "AnyTLS 参数配置完成！"
    fi

    # 保存配置
    echo "$info_json" > "$INFO_PATH"
    chmod 600 "$INFO_PATH"
    mkdir -p "$CONFIG_DIR"
    jq -n --argjson ib "$inbounds_json" --arg lv "$log_level" \
        '{log: {level: $lv, timestamp: true}, inbounds: $ib}' > "$CONFIG_PATH"

    log_info "正在校验配置文件..."
    if ! "$SB_BIN" check -c "$CONFIG_PATH"; then
        log_error "配置校验未通过，请检查上方报错 (常见原因：内核版本不支持 AnyTLS)。"
        pause
        return
    fi

    log_info "正在启动与重载 Sing-Box 服务..."
    setup_service || { pause; return; }
    svc_enable || true
    if svc_restart; then
        sleep 1
        if svc_is_active; then
            log_success "恭喜！Sing-Box 节点配置与部署完全成功！"
        else
            log_warn "服务已下发启动指令但未在运行，请通过「查看实时日志」排查。"
        fi
    else
        log_error "服务启动失败，请通过「查看实时日志」排查。"
    fi
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
    [[ "$ip" == *:* ]] && host="[${ip}]"      # IPv6 地址需要加方括号

    print_header "已生成的节点连接信息"
    echo

    if jq -e .reality "$INFO_PATH" >/dev/null 2>&1; then
        local p w s k d
        p=$(jq -r .reality.port "$INFO_PATH")
        w=$(jq -r .reality.pwd "$INFO_PATH")
        s=$(jq -r .reality.sni "$INFO_PATH")
        k=$(jq -r .reality.pk "$INFO_PATH")
        d=$(jq -r .reality.id "$INFO_PATH")

        echo -e "${GREEN}[ AnyReality 节点 ]: ${NC}"
        echo -e "${YELLOW}anytls://${w}@${host}:${p}/?sni=${s}&fp=chrome&pbk=${k}&sid=${d}#AnyReality_${ip}${NC}\n"
    fi

    if jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
        local p w s
        p=$(jq -r .anytls.port "$INFO_PATH")
        w=$(jq -r .anytls.pwd "$INFO_PATH")
        s=$(jq -r .anytls.sni "$INFO_PATH")

        echo -e "${GREEN}[ AnyTLS 节点 ]: ${NC}"
        echo -e "${YELLOW}anytls://${w}@${host}:${p}/?sni=${s}&insecure=1#AnyTLS_${ip}${NC}\n"
    fi
    echo -e "${CYAN}=====================================================${NC}"
    pause
}

# ------------------------------------------------------------------------------
# 服务管理与状态模块
# ------------------------------------------------------------------------------
manage_service() {
    clear
    print_header "服务控制面板"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        log_warn "当前未配置节点，请先通过选项 1 部署节点。"
        pause
        return
    fi
    echo -e " 1. 启动服务"
    echo -e " 2. 停止服务"
    echo -e " 3. 重启服务"
    echo -e " 0. 返回上一菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    local act
    read -rp " 请选择操作 [0-3]: " act
    case "$act" in
        1) if svc_start;   then log_success "Sing-Box 服务启动成功！"; else log_error "启动失败，请查看日志。"; fi ;;
        2) if svc_stop;    then log_success "Sing-Box 服务已停止！";   else log_error "停止失败。"; fi ;;
        3) if svc_restart; then log_success "Sing-Box 服务重启成功！"; else log_error "重启失败，请查看日志。"; fi ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac
    pause
}

show_status() {
    clear
    print_header "Sing-Box 服务运行状态"
    echo
    svc_status

    local pid rss avail
    pid=$(pidof sing-box 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$pid" ]]; then
        rss=$(awk '/^VmRSS:/{printf "%.1f", $2/1024}' "/proc/${pid}/status" 2>/dev/null || true)
        echo -e "\n 进程内存占用: ${GREEN}${rss:-?} MB${NC}"
    fi
    avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || true)
    echo -e " 系统内存: 共 ${MEM_TOTAL_MB} MB，可用 ${avail:-?} MB"
    echo -e "\n${CYAN}=====================================================${NC}"
    pause
}

show_logs() {
    while :; do
        clear
        print_header "正在查看实时日志 (退出日志预览按 Ctrl+C)"
        echo

        # 日志查看期间让 Ctrl+C 只终止 tail/journalctl，不退出整个脚本
        trap ':' INT
        if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl &>/dev/null; then
            journalctl -u "$SERVICE_NAME" -e -f -n 50 || true
        elif [[ -f "$SB_LOG_FILE" ]]; then
            tail -n 50 -f "$SB_LOG_FILE" || true
        else
            log_warn "暂无日志可查看 (服务尚未运行过?)。"
        fi
        trap 'echo -e "\n${RED}[!] 操作被用户中断${NC}"; exit 1' INT TERM

        echo -e "\n${CYAN}-----------------------------------------------------${NC}"
        echo -e " 1. 刷新重新查看日志"
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"

        local log_opt
        read -rp " 请选择 [0-1]: " log_opt
        case "$log_opt" in
            1) continue ;;
            *) break ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 卸载模块
# ------------------------------------------------------------------------------
# 仅删除节点：保留内核、服务定义、快捷命令与本脚本
remove_node_keep_core() {
    clear
    print_header "仅删除节点 (保留内核)" "$YELLOW"
    echo -e " 将执行以下操作："
    echo -e "   ${RED}✗${NC} 停止并禁用 Sing-Box 服务"
    echo -e "   ${RED}✗${NC} 删除节点配置、证书、节点信息，并回收已放行的防火墙端口"
    echo -e "   ${GREEN}✓${NC} 保留 Sing-Box 内核、服务定义、本脚本与 any 快捷命令"
    echo
    if [[ ! -f "$CONFIG_PATH" && ! -f "$INFO_PATH" ]]; then
        log_warn "未发现任何节点配置，无需删除。"
        pause
        return
    fi

    local confirm
    read -rp " 确定要仅删除节点配置吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理节点..."
        svc_stop >/dev/null 2>&1 || true
        svc_disable || true

        cleanup_firewall_rules
        rm -f "$CONFIG_PATH" "${CONFIG_DIR}/client_info.json" "$INFO_PATH" "$SB_LOG_FILE"
        rm -rf /root/AnyTLS

        log_success "节点已删除，内核 ${SB_BIN:+(${SB_BIN}) }已保留。再次选择「安装 / 重构节点」即可快速重新部署。"
    else
        log_info "已取消操作。"
    fi
    pause
}

remove_core_packages() {
    if command -v apk &>/dev/null && apk info -e sing-box &>/dev/null; then
        apk del sing-box >/dev/null 2>&1 || true
    elif command -v dpkg &>/dev/null && dpkg -s sing-box &>/dev/null; then
        apt-get purge -y -qq sing-box >/dev/null 2>&1 || true
    elif command -v rpm &>/dev/null && rpm -q sing-box &>/dev/null; then
        { dnf remove -y -q sing-box || yum remove -y -q sing-box; } >/dev/null 2>&1 || true
    fi
}

uninstall_all() {
    clear
    print_header "彻底卸载 Sing-Box" "$RED"
    local confirm
    read -rp " 确定要彻底卸载 Sing-Box 内核、节点及脚本吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理并卸载..."
        svc_stop >/dev/null 2>&1 || true
        svc_disable || true
        cleanup_firewall_rules

        remove_core_packages

        # 服务定义
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "$OPENRC_SCRIPT"
        rm -rf "$SYSTEMD_DROPIN_DIR"

        # 二进制与快捷命令
        rm -f /usr/bin/"$SERVICE_NAME" /usr/local/bin/"$SERVICE_NAME" /usr/local/bin/any /usr/bin/any
        local legacy
        for legacy in /usr/local/bin/a /usr/bin/a; do        # 兼容旧版脚本遗留的 a 命令
            if [[ -f "$legacy" ]] && grep -q "any.sh" "$legacy" 2>/dev/null; then
                rm -f "$legacy"
            fi
        done

        # 配置与数据
        rm -rf "$CONFIG_DIR" /var/lib/"$SERVICE_NAME" "$INFO_PATH" /root/AnyTLS "$SB_LOG_FILE" "$LOCAL_SCRIPT_PATH"

        [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl daemon-reload || true
        log_success "Sing-Box 及脚本组件已彻底清理卸载完成！"
        pause
        exit 0
    else
        log_info "已取消卸载。"
        pause
    fi
}

# ------------------------------------------------------------------------------
# 主菜单循环
# ------------------------------------------------------------------------------
main_menu() {
    check_root
    detect_env
    force_register_shortcut
    trap 'echo -e "\n${RED}[!] 操作被用户中断${NC}"; exit 1' INT TERM

    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}       Sing-Box (AnyTLS / AnyReality) 管理脚本       ${NC}"
        echo -e "         快捷指令: 在终端输入 ${YELLOW}${BOLD}any${NC} 即可快速打开"

        # 每轮刷新内核路径 (安装/卸载后会变化)
        hash -r
        SB_BIN=$(command -v sing-box 2>/dev/null || true)
        print_system_status

        echo -e " ${GREEN}1.${NC} 安装 / 重构节点"
        echo -e " ${GREEN}2.${NC} 服务管理 (启动/停止/重启)"
        echo -e " ${GREEN}3.${NC} 查看节点链接"
        echo -e " ${GREEN}4.${NC} 查看运行状态"
        echo -e " ${GREEN}5.${NC} 查看实时日志"
        echo -e " ${YELLOW}6.${NC} 仅删除节点 (保留内核)"
        echo -e " ${RED}7.${NC} 彻底卸载 Sing-Box"
        echo -e " ${YELLOW}0.${NC} 退出脚本"
        echo -e "${CYAN}=====================================================${NC}"

        local opt
        read -rp " 请输入选项 [0-7]: " opt
        case "$opt" in
            1) install_node ;;
            2) manage_service ;;
            3) show_links ;;
            4) show_status ;;
            5) show_logs ;;
            6) remove_node_keep_core ;;
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
