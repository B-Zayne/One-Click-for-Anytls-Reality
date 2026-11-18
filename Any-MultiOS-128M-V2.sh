#!/usr/bin/env bash
# AnyTLS / AnyReality manager - Alpine / Debian / Ubuntu edition
# v2.1.0: 强制 sing-box >= 1.12；注入 GOMEMLIMIT/GOGC；移除进程替换；加固密钥解析。
set -Eeuo pipefail
umask 077

readonly CONFIG_PATH=/etc/sing-box/config.json
readonly INFO_PATH=/root/.sb_info.json
readonly TLS_DIR=/root/AnyTLS/tls
readonly SERVICE_NAME=sing-box
readonly LOCAL_SCRIPT_PATH=/root/any.sh
readonly VERSION=2.1.0
readonly MIN_SING_BOX_MAJOR=1
readonly MIN_SING_BOX_MINOR=12
readonly GOMEMLIMIT_VALUE="${GOMEMLIMIT_VALUE:-48MiB}"
readonly GOGC_VALUE="${GOGC_VALUE:-70}"

RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
fi

info(){ printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
ok(){ printf '%b[ OK ]%b %s\n' "$GREEN" "$NC" "$*"; }
warn(){ printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
err(){ printf '%b[FAIL]%b %s\n' "$RED" "$NC" "$*" >&2; }
pause(){ printf '\n按回车键继续...'; read -r _ || true; }

check_root(){
  if (( EUID != 0 )); then err '请使用 root 运行：sudo -i'; exit 1; fi
}

is_alpine(){ [[ -r /etc/alpine-release ]]; }

service_action(){
  local action="$1"
  if command -v systemctl >/dev/null 2>&1; then
    case "$action" in
      enable) systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 ;;
      disable) systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
      start|stop|restart) systemctl "$action" "$SERVICE_NAME" ;;
      status) systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1 ;;
      reload) systemctl daemon-reload ;;
    esac
  elif command -v rc-service >/dev/null 2>&1; then
    case "$action" in
      enable) rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 ;;
      disable) rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true ;;
      start|stop|restart|status) rc-service "$SERVICE_NAME" "$action" ;;
      reload) : ;;
    esac
  else
    err '未检测到 systemd 或 OpenRC，无法管理 sing-box 服务。'
    return 1
  fi
}

ensure_systemd_unit(){
  # 为 systemd 环境注入 Go 内存限制（drop-in，不覆盖包自带 unit）
  local dir=/etc/systemd/system/sing-box.service.d
  mkdir -p "$dir"
  cat > "$dir/override.conf" <<EOF
[Service]
Environment="GOMEMLIMIT=${GOMEMLIMIT_VALUE}"
Environment="GOGC=${GOGC_VALUE}"
Environment="GOMAXPROCS=1"
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
}

ensure_alpine_service(){
  command -v rc-service >/dev/null 2>&1 || return 0
  if [[ ! -x /etc/init.d/sing-box ]]; then
    mkdir -p /etc/init.d
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
export GOMEMLIMIT="${GOMEMLIMIT_VALUE}"
export GOGC="${GOGC_VALUE}"
export GOMAXPROCS=1
depend() { need net; }
EOF
    chmod 755 /etc/init.d/sing-box
  else
    # 已有服务文件也确保环境变量存在
    if ! grep -q 'GOMEMLIMIT' /etc/init.d/sing-box 2>/dev/null; then
      sed -i "/command_background=/a export GOMEMLIMIT=\"${GOMEMLIMIT_VALUE}\"\nexport GOGC=\"${GOGC_VALUE}\"\nexport GOMAXPROCS=1" /etc/init.d/sing-box 2>/dev/null || true
    fi
  fi
}

sing_box_version_supported(){
  command -v sing-box >/dev/null 2>&1 || return 1
  local v major minor
  v=$(sing-box version 2>/dev/null | awk '/version/ {print $3; exit}')
  v=${v#v}
  major=$(printf '%s' "$v" | cut -d. -f1)
  minor=$(printf '%s' "$v" | cut -d. -f2)
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  if (( major > MIN_SING_BOX_MAJOR )); then return 0; fi
  if (( major == MIN_SING_BOX_MAJOR && minor >= MIN_SING_BOX_MINOR )); then return 0; fi
  return 1
}

install_dependencies(){
  info '检查轻量依赖...'
  if is_alpine; then
    command -v apk >/dev/null 2>&1 || { err '未找到 apk'; return 1; }
    apk add --no-cache bash curl jq openssl ca-certificates iproute2 >/dev/null
    update-ca-certificates >/dev/null 2>&1 || true

    if ! command -v sing-box >/dev/null 2>&1; then
      info 'Alpine：尝试从 community 仓库安装 sing-box...'
      apk add --no-cache sing-box >/dev/null 2>&1 || true
    fi

    if ! sing_box_version_supported; then
      local cur=""
      command -v sing-box >/dev/null 2>&1 && cur=$(sing-box version 2>/dev/null | head -1 || true)
      err "当前 sing-box 版本不满足 AnyTLS 最低要求（>= ${MIN_SING_BOX_MAJOR}.${MIN_SING_BOX_MINOR}）。"
      [[ -n "$cur" ]] && err "已安装：$cur"
      warn 'Alpine 请确保 community 仓库已启用，或手动下载官方二进制放置到 /usr/local/bin/sing-box。'
      warn '也可临时使用 edge 仓库：apk add -X https://dl-cdn.alpinelinux.org/alpine/edge/community --no-cache sing-box'
      return 1
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl ca-certificates iproute2
    if ! command -v sing-box >/dev/null 2>&1; then
      curl -fsSL https://sing-box.app/install.sh | sh
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq openssl ca-certificates iproute
    command -v sing-box >/dev/null 2>&1 || curl -fsSL https://sing-box.app/install.sh | sh
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq openssl ca-certificates iproute
    command -v sing-box >/dev/null 2>&1 || curl -fsSL https://sing-box.app/install.sh | sh
  else
    err '暂不支持此发行版的依赖安装。'; return 1
  fi

  command -v sing-box >/dev/null 2>&1 || { err 'sing-box 内核安装失败'; return 1; }
  if ! sing_box_version_supported; then
    err 'sing-box 版本仍低于 AnyTLS 要求（>= 1.12.0），请手动升级内核。'
    return 1
  fi
  ensure_alpine_service
  if command -v systemctl >/dev/null 2>&1; then ensure_systemd_unit; fi
  command -v jq >/dev/null 2>&1 || { err 'jq 安装失败'; return 1; }
  ok "依赖就绪：$(sing-box version 2>/dev/null | head -n 1)"
}

register_shortcut(){
  if [[ -f "$0" && "$0" != "$LOCAL_SCRIPT_PATH" ]]; then
    cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    chmod 700 "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
  fi
  if [[ -s "$LOCAL_SCRIPT_PATH" ]]; then
    printf '#!/bin/sh\nexec /bin/bash /root/any.sh "$@"\n' > /usr/local/bin/any
    chmod 755 /usr/local/bin/any
  fi
}

validate_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
port_busy(){
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntu 2>/dev/null | awk -v p="$p" '$5 ~ (":" p "$") {found=1} END{exit !found}'
  else return 1; fi
}
get_public_ip(){
  local ip=''
  ip=$(curl -4fsS --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null || true)
  [[ -n "$ip" ]] || ip=$(curl -6fsS --connect-timeout 4 --max-time 6 https://api64.ipify.org 2>/dev/null || true)
  printf '%s' "${ip:-YOUR_SERVER_IP}"
}

open_firewall_port(){
  local p="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
    ufw allow "$p/tcp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --add-port="$p/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  else
    warn "未检测到受支持的主机防火墙；请务必在云厂商安全组放行 TCP ${p}。"
  fi
}

generate_cert(){
  local sni="$1"
  mkdir -p "$TLS_DIR"
  # 不使用 Bash 进程替换，避免 Alpine/musl + OpenSSL 的 FIFO 兼容性问题
  openssl ecparam -genkey -name prime256v1 -out "${TLS_DIR}/server.key.tmp" >/dev/null 2>&1 || {
    err 'EC 私钥生成失败'; return 1
  }
  openssl req -x509 -nodes -key "${TLS_DIR}/server.key.tmp" \
    -out "${TLS_DIR}/server.crt" -subj "/CN=$sni" -days 3650 >/dev/null 2>&1 || {
    rm -f "${TLS_DIR}/server.key.tmp"; err '证书签名失败'; return 1
  }
  mv -f "${TLS_DIR}/server.key.tmp" "${TLS_DIR}/server.key"
  chmod 600 "$TLS_DIR/server.key"; chmod 644 "$TLS_DIR/server.crt"
}

backup_config(){
  if [[ -s "$CONFIG_PATH" ]]; then
    cp -p "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  if [[ -s "$INFO_PATH" ]]; then
    cp -p "$INFO_PATH" "${INFO_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

write_and_apply(){
  local inbounds="$1" metadata="$2" tmp
  mkdir -p "$(dirname "$CONFIG_PATH")"
  tmp=$(mktemp "${CONFIG_PATH}.XXXXXX")
  jq -n --argjson ib "$inbounds" '{log:{level:"warn",timestamp:false},inbounds:$ib}' > "$tmp"
  if ! sing-box check -c "$tmp"; then
    rm -f "$tmp"; err '配置校验失败，原配置未覆盖。'; return 1
  fi
  backup_config
  install -m 600 "$tmp" "$CONFIG_PATH"
  rm -f "$tmp"
  printf '%s\n' "$metadata" | jq . > "${INFO_PATH}.tmp"
  install -m 600 "${INFO_PATH}.tmp" "$INFO_PATH"
  rm -f "${INFO_PATH}.tmp"
  service_action enable || true
  service_action restart
  ok '配置已通过 sing-box check，并已重启服务。'
}

status_summary(){
  echo '-----------------------------------------------------'
  if command -v sing-box >/dev/null 2>&1; then
    echo "内核：$(sing-box version 2>/dev/null | head -n 1)"
  else echo '内核：未安装'; fi
  if [[ -s "$CONFIG_PATH" ]]; then
    local n=0; n=$(jq '.inbounds | length' "$CONFIG_PATH" 2>/dev/null || echo 0)
    echo "节点：$n 个"
    if service_action status >/dev/null 2>&1; then echo '服务：运行中'; else echo '服务：未运行'; fi
  else echo '节点：未配置'; fi
  echo '-----------------------------------------------------'
}

install_node(){
  clear 2>/dev/null || true
  echo '部署节点：1) AnyReality  2) AnyTLS  3) 双协议  0) 返回'
  read -r -p '请选择 [0-3]：' mode
  case "$mode" in 1|2|3) ;; 0) return ;; *) err '无效选项'; return ;; esac
  install_dependencies || return
  local inbounds='[]' metadata='{}' p pwd sni keypair priv pub sid inbound

  if [[ -s "$CONFIG_PATH" ]]; then
    warn '安装/重构会替换本脚本管理的 inbounds；原配置将自动备份。'
    read -r -p '继续重构配置？[y/N]：' confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return
  fi

  if [[ "$mode" == 1 || "$mode" == 3 ]]; then
    echo; echo '--- 配置 AnyReality ---'
    while :; do
      read -r -p '端口 [1443]：' p; p=${p:-1443}
      if validate_port "$p" && ! port_busy "$p"; then break; fi
      warn '端口无效或已占用，请重新输入。'
    done
    read -r -p '密码 [自动生成]：' pwd; pwd=${pwd:-$(openssl rand -hex 16)}
    read -r -p 'Reality SNI [genshin.hoyoverse.com]：' sni; sni=${sni:-genshin.hoyoverse.com}

    keypair=$(sing-box generate reality-keypair) || { err 'Reality 密钥生成失败'; return; }
    # Reality 输出格式固定为 "PrivateKey: xxx" 与 "PublicKey: xxx"
    priv=$(printf '%s\n' "$keypair" | awk -F': *' '/PrivateKey/ {print $2; exit}')
    pub=$(printf '%s\n' "$keypair" | awk -F': *' '/PublicKey/ {print $2; exit}')
    if [[ -z "$priv" || -z "$pub" ]]; then
      err '无法解析 Reality 密钥对输出。原始输出如下，请手动记录：'
      printf '%s\n' "$keypair" >&2
      return 1
    fi
    sid=$(openssl rand -hex 8)

    inbound=$(jq -n --argjson p "$p" --arg w "$pwd" --arg s "$sni" --arg k "$priv" --arg id "$sid" \
      '{type:"anytls",listen:"::",listen_port:$p,users:[{name:"user",password:$w}],
        padding_scheme:["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
        tls:{enabled:true,server_name:$s,reality:{enabled:true,handshake:{server:$s,server_port:443},private_key:$k,short_id:[$id]}}}')
    inbounds=$(jq -cn --argjson a "$inbounds" --argjson b "$inbound" '$a+[$b]')
    metadata=$(jq -cn --arg p "$p" --arg w "$pwd" --arg s "$sni" --arg pk "$pub" --arg id "$sid" \
      '{reality:{port:$p,pwd:$w,sni:$s,pk:$pk,id:$id}}')
    open_firewall_port "$p"
  fi

  if [[ "$mode" == 2 || "$mode" == 3 ]]; then
    echo; echo '--- 配置 AnyTLS ---'
    while :; do
      read -r -p '端口 [2026]：' p; p=${p:-2026}
      if validate_port "$p" && ! port_busy "$p"; then
        if [[ "$mode" == 3 ]] && [[ "$(jq -r '.reality.port // empty' <<< "$metadata")" == "$p" ]]; then
          warn '端口不能与 AnyReality 重复'; continue
        fi
        break
      fi
      warn '端口无效或已占用，请重新输入。'
    done
    read -r -p '密码 [自动生成]：' pwd; pwd=${pwd:-$(openssl rand -hex 16)}
    read -r -p 'TLS 域名 [genshin.hoyoverse.com]：' sni; sni=${sni:-genshin.hoyoverse.com}
    generate_cert "$sni" || return

    inbound=$(jq -n --argjson p "$p" --arg w "$pwd" \
      '{type:"anytls",listen:"::",listen_port:$p,users:[{password:$w}],
        padding_scheme:["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
        tls:{enabled:true,certificate_path:"/root/AnyTLS/tls/server.crt",key_path:"/root/AnyTLS/tls/server.key"}}')
    inbounds=$(jq -cn --argjson a "$inbounds" --argjson b "$inbound" '$a+[$b]')
    metadata=$(jq -c --arg p "$p" --arg w "$pwd" --arg s "$sni" '. + {anytls:{port:$p,pwd:$w,sni:$s}}' <<< "$metadata")
    open_firewall_port "$p"
  fi

  write_and_apply "$inbounds" "$metadata" || return
  show_links
}

show_links(){
  [[ -s "$INFO_PATH" ]] || { warn '没有节点信息'; return; }
  local ip; ip=$(get_public_ip)
  if jq -e '.reality' "$INFO_PATH" >/dev/null 2>&1; then
    printf '\n[AnyReality / AnyTLS-Reality]\nanytls://%s@%s:%s/?sni=%s&fp=chrome&pbk=%s&sid=%s#AnyReality_%s\n' \
      "$(jq -r .reality.pwd "$INFO_PATH")" "$ip" "$(jq -r .reality.port "$INFO_PATH")" \
      "$(jq -r .reality.sni "$INFO_PATH")" "$(jq -r .reality.pk "$INFO_PATH")" \
      "$(jq -r .reality.id "$INFO_PATH")" "$ip"
  fi
  if jq -e '.anytls' "$INFO_PATH" >/dev/null 2>&1; then
    printf '\n[AnyTLS]\nanytls://%s@%s:%s/?sni=%s&insecure=1#AnyTLS_%s\n' \
      "$(jq -r .anytls.pwd "$INFO_PATH")" "$ip" "$(jq -r .anytls.port "$INFO_PATH")" \
      "$(jq -r .anytls.sni "$INFO_PATH")" "$ip"
  fi
  pause
}

manage_service(){
  echo '1) 启动  2) 停止  3) 重启  0) 返回'
  read -r -p '请选择：' a
  case "$a" in
    1) service_action start && ok '已启动' ;;
    2) service_action stop && ok '已停止' ;;
    3) service_action restart && ok '已重启' ;;
    0) return ;;
    *) warn '无效选项' ;;
  esac
  pause
}

show_status(){
  if command -v systemctl >/dev/null 2>&1; then systemctl status "$SERVICE_NAME" --no-pager || true
  elif command -v rc-service >/dev/null 2>&1; then rc-service "$SERVICE_NAME" status || true
  else warn '未检测到服务管理器'; fi
  [[ -x "$(command -v sing-box 2>/dev/null || true)" ]] && sing-box version || true
  pause
}

show_logs(){
  if command -v journalctl >/dev/null 2>&1; then journalctl -u "$SERVICE_NAME" -n 80 --no-pager
  elif [[ -f /var/log/sing-box.log ]]; then tail -n 80 /var/log/sing-box.log
  else warn '当前服务未配置可读取的日志文件；可使用 rc-service sing-box status 检查状态。'; fi
  pause
}

remove_nodes_keep_core(){
  clear 2>/dev/null || true
  echo '删除节点（保留 sing-box 内核）'
  echo '1) 删除 AnyReality 节点  2) 删除 AnyTLS 节点  3) 删除全部节点  0) 返回'
  read -r -p '请选择 [0-3]：' choice
  [[ "$choice" == 0 ]] && return
  [[ -s "$CONFIG_PATH" ]] || { warn '未找到配置文件'; pause; return; }
  [[ -s "$INFO_PATH" ]] || { warn '未找到节点元数据；为防误删，不自动修改未知配置'; pause; return; }

  local newcfg newmeta reality_port anytls_port
  reality_port=$(jq -r '.reality.port // empty' "$INFO_PATH")
  anytls_port=$(jq -r '.anytls.port // empty' "$INFO_PATH")
  case "$choice" in
    1) [[ -n "$reality_port" ]] || { warn '没有 AnyReality 节点'; pause; return; }
       newcfg=$(jq --arg p "$reality_port" '.inbounds |= map(select((.listen_port|tostring) != $p))' "$CONFIG_PATH")
       newmeta=$(jq 'del(.reality)' "$INFO_PATH") ;;
    2) [[ -n "$anytls_port" ]] || { warn '没有 AnyTLS 节点'; pause; return; }
       newcfg=$(jq --arg p "$anytls_port" '.inbounds |= map(select((.listen_port|tostring) != $p))' "$CONFIG_PATH")
       newmeta=$(jq 'del(.anytls)' "$INFO_PATH") ;;
    3) newcfg=$(jq --arg rp "$reality_port" --arg tp "$anytls_port" \
         '.inbounds |= map(select(((.listen_port|tostring) != $rp) and ((.listen_port|tostring) != $tp)))' "$CONFIG_PATH")
       newmeta='{}' ;;
    *) warn '无效选项'; pause; return ;;
  esac

  local tmpcheck; tmpcheck=$(mktemp)
  printf '%s\n' "$newcfg" > "$tmpcheck"
  if ! sing-box check -c "$tmpcheck"; then
    rm -f "$tmpcheck"; err '新配置校验失败，未执行删除'; pause; return
  fi
  rm -f "$tmpcheck"

  read -r -p '确认删除所选节点？[y/N]：' confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info '已取消'; return; }
  backup_config
  local tmp; tmp=$(mktemp "${CONFIG_PATH}.XXXXXX")
  printf '%s\n' "$newcfg" > "$tmp"; install -m 600 "$tmp" "$CONFIG_PATH"; rm -f "$tmp"
  printf '%s\n' "$newmeta" | jq . > "${INFO_PATH}.tmp"
  install -m 600 "${INFO_PATH}.tmp" "$INFO_PATH"; rm -f "${INFO_PATH}.tmp"
  if [[ "$choice" == 2 || "$choice" == 3 ]]; then rm -rf "$TLS_DIR"; fi

  if [[ "$(jq '.inbounds | length' <<< "$newcfg")" -eq 0 ]]; then
    service_action stop >/dev/null 2>&1 || true
    service_action disable >/dev/null 2>&1 || true
    ok '节点配置已删除；因无剩余节点，服务已停止。sing-box 内核保留。'
  else
    service_action restart
    ok '所选节点已删除，剩余节点已重新加载；sing-box 内核保留。'
  fi
  pause
}

uninstall_all(){
  echo '彻底卸载将删除 sing-box 内核、服务文件及本脚本配置。'
  read -r -p '确定彻底卸载？输入 YES 确认：' confirm
  [[ "$confirm" == YES ]] || { info '已取消'; return; }
  service_action stop >/dev/null 2>&1 || true
  service_action disable >/dev/null 2>&1 || true

  if is_alpine; then
    if command -v apk >/dev/null 2>&1; then apk del sing-box >/dev/null 2>&1 || true; fi
    rm -f /usr/bin/sing-box /usr/local/bin/sing-box
    rm -f /etc/init.d/sing-box
  else
    if command -v apt-get >/dev/null 2>&1; then apt-get remove -y sing-box >/dev/null 2>&1 || true; fi
    rm -f /usr/local/bin/sing-box /usr/bin/sing-box
    rm -f /etc/systemd/system/sing-box.service /lib/systemd/system/sing-box.service
    rm -rf /etc/systemd/system/sing-box.service.d
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -rf /etc/sing-box "$INFO_PATH" /root/AnyTLS
  rm -f /usr/local/bin/any "$LOCAL_SCRIPT_PATH"
  ok '卸载清理完成。'
  pause
}

main(){
  check_root
  if is_alpine && ! command -v bash >/dev/null 2>&1; then
    err '请先执行：apk add --no-cache bash，然后用 bash Any.sh 运行。'; exit 1
  fi
  register_shortcut
  while :; do
    clear 2>/dev/null || true
    echo '====================================================='
    echo '       Sing-box AnyTLS / AnyReality 管理脚本'
    echo "       Alpine / Debian / Ubuntu 通用版 v$VERSION"
    echo "       GOMEMLIMIT=${GOMEMLIMIT_VALUE}  GOGC=${GOGC_VALUE}"
    status_summary
    echo '1) 安装 / 重构节点'
    echo '2) 服务管理（启动 / 停止 / 重启）'
    echo '3) 查看节点链接'
    echo '4) 查看服务状态'
    echo '5) 查看日志'
    echo '6) 删除节点（保留 sing-box 内核）'
    echo '7) 彻底卸载 sing-box'
    echo '0) 退出'
    read -r -p '请选择 [0-7]：' opt
    case "$opt" in
      1) install_node ;;
      2) manage_service ;;
      3) show_links ;;
      4) show_status ;;
      5) show_logs ;;
      6) remove_nodes_keep_core ;;
      7) uninstall_all ;;
      0) exit 0 ;;
      *) warn '无效选项'; sleep 1 ;;
    esac
  done
}

main "$@"
