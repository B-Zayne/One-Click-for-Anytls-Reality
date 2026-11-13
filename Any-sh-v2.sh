#!/usr/bin/env bash
# Any.sh V2 - sing-box AnyTLS-Reality + AnyTLS TLS manager
# Supports Debian/Ubuntu, RHEL/Rocky/AlmaLinux/Fedora families.
# AnyTLS uses standard TLS. Reality is implemented as AnyTLS + REALITY:
# sing-box does not support REALITY inside an AnyTLS inbound.

set -Eeuo pipefail
umask 077

readonly VERSION="2.0.0"
readonly SERVICE="sing-box"
readonly CONFIG="/etc/sing-box/config.json"
readonly INFO="/etc/sing-box/any-manager.json"
readonly LEGACY_INFO="/root/.sb_info.json"
readonly TLS_DIR="/etc/sing-box/anytls"
readonly SCRIPT_COPY="/usr/local/lib/any-manager/Any.sh"
readonly SHORTCUT="/usr/local/bin/any"
readonly BACKUP_DIR="/etc/sing-box/backup"
readonly DEFAULT_PADDING='["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"]'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; RESET=$'\033[0m'

log()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
err()  { printf '%s[ERR ]%s %s\n' "$RED" "$RESET" "$*" >&2; }
pause(){ read -r -p "按 Enter 继续..." _ || true; }
die(){ err "$*"; return 1; }

on_error() {
  local rc=$?
  err "脚本在第 ${BASH_LINENO[0]:-未知} 行发生错误（退出码 ${rc}）。"
  if command -v systemctl >/dev/null 2>&1; then
    warn "可查看日志：journalctl -u ${SERVICE} -n 80 --no-pager"
  fi
  exit "$rc"
}
trap on_error ERR

require_root() {
  [[ ${EUID} -eq 0 ]] || { err "请使用 root 用户运行：sudo bash Any.sh"; exit 1; }
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; return 1; }; }

valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}
valid_domain() {
  local d=$1
  [[ ${#d} -le 253 && "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
port_busy() {
  local p=$1 listeners="" owned=0 meta
  if command -v ss >/dev/null 2>&1; then
    listeners=$(ss -H -ltnp "( sport = :${p} )" 2>/dev/null || true)
    [[ -z "$listeners" ]] && return 1
    # Permit reuse only when the listener is sing-box and metadata identifies this as our old port.
    for meta in "$INFO" "$LEGACY_INFO"; do
      if [[ -s "$meta" ]] && jq -e --arg p "$p" '(.reality.port // "") == $p or (.anytls.port // "") == $p' "$meta" >/dev/null 2>&1; then
        owned=1
        break
      fi
    done
    if (( owned == 1 )) && grep -q 'users:(("sing-box"' <<<"$listeners"; then
      return 1
    fi
    return 0
  elif command -v lsof >/dev/null 2>&1; then
    for meta in "$INFO" "$LEGACY_INFO"; do
      if [[ -s "$meta" ]] && jq -e --arg p "$p" '(.reality.port // "") == $p or (.anytls.port // "") == $p' "$meta" >/dev/null 2>&1; then
        owned=1
        break
      fi
    done
    if (( owned == 1 )) && lsof -nP -iTCP:"$p" -sTCP:LISTEN -c sing-box >/dev/null 2>&1; then
      return 1
    fi
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  else
    warn "无法检测端口占用（缺少 ss/lsof）；请自行确认。"
    return 1
  fi
}

ask_port() {
  local prompt=$1 default=$2 p
  while true; do
    read -r -p "${prompt} [默认 ${default}]: " p
    p=${p:-$default}
    if ! valid_port "$p"; then warn "端口必须是 1-65535 的整数。"; continue; fi
    if port_busy "$p"; then warn "TCP ${p} 已被监听，请更换。"; continue; fi
    printf '%s' "$p"; return
  done
}
ask_domain() {
  local prompt=$1 default=$2 d
  while true; do
    read -r -p "${prompt} [默认 ${default}]: " d
    d=${d:-$default}
    if valid_domain "$d"; then printf '%s' "$d"; return; fi
    warn "请输入有效域名，例如 example.com（不要带协议、端口或路径）。"
  done
}
random_secret(){ openssl rand -hex 24; }
random_uuid(){ cat /proc/sys/kernel/random/uuid; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  else return 1; fi
}
install_deps() {
  local pm; pm=$(detect_pkg_manager) || die "仅支持 apt、dnf、yum 系统。"
  log "安装依赖（curl、jq、openssl、iproute2）..."
  case "$pm" in
    apt) apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq openssl iproute2 ca-certificates ;;
    dnf) dnf install -y curl jq openssl iproute ca-certificates ;;
    yum) yum install -y curl jq openssl iproute ca-certificates ;;
  esac
  need_cmd curl; need_cmd jq; need_cmd openssl; need_cmd ss; need_cmd systemctl
}
install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    log "检测到 sing-box：$(sing-box version | head -n 1)"
    read -r -p "是否通过官方安装脚本更新到最新 Stable 正式版？[y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0
  else
    log "安装 sing-box Stable 正式版（不启用 Beta）..."
  fi
  local installer
  installer=$(mktemp /tmp/sing-box-install.XXXXXX)
  chmod 700 "$installer"
  if ! curl --proto '=https' --tlsv1.2 -fsSL https://sing-box.app/install.sh -o "$installer"; then
    rm -f -- "$installer"
    die "无法从 sing-box 官方站点下载安装脚本。"
  fi
  if ! bash "$installer"; then
    rm -f -- "$installer"
    die "sing-box 官方安装脚本执行失败。"
  fi
  rm -f -- "$installer"
  need_cmd sing-box
  sing-box version
}
require_anytls_version() {
  local version
  version=$(sing-box version | awk '/sing-box version/ {print $3; exit}')
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "无法识别 sing-box 版本：$version"
  if [[ "$(printf '%s\n' 1.12.0 "$version" | sort -V | head -n1)" != "1.12.0" ]]; then
    die "AnyTLS 入站要求 sing-box 1.12.0 或更新版本；当前版本：$version"
  fi
}
prepare_dirs() {
  install -d -m 700 /etc/sing-box "$BACKUP_DIR" "$TLS_DIR" "$(dirname "$SCRIPT_COPY")"
  local svc_user svc_group
  svc_user=$(systemctl show -p User --value "$SERVICE" 2>/dev/null || true)
  if [[ -n "$svc_user" ]]; then
    svc_group=$(id -gn "$svc_user" 2>/dev/null || printf '%s' "$svc_user")
    chown root:"$svc_group" /etc/sing-box
    chmod 750 /etc/sing-box
  else
    chmod 700 /etc/sing-box
  fi
  chmod 700 "$TLS_DIR" "$BACKUP_DIR"
}
LAST_BACKUP=""
backup_current() {
  LAST_BACKUP=""
  if [[ -s "$CONFIG" ]]; then
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    LAST_BACKUP="$BACKUP_DIR/config-${stamp}.json"
    cp -a "$CONFIG" "$LAST_BACKUP"
    chmod 600 "$LAST_BACKUP"
    log "已备份原配置：$LAST_BACKUP"
  fi
}
make_cert() {
  local domain=$1
  log "生成本地自签名 ECC 证书（客户端需启用跳过证书验证）..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" \
    -days 825 -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain}" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
  chmod 600 "$TLS_DIR/server.key"
  chmod 644 "$TLS_DIR/server.crt"
  local svc_user svc_group
  svc_user=$(systemctl show -p User --value "$SERVICE" 2>/dev/null || true)
  if [[ -n "$svc_user" ]]; then
    svc_group=$(id -gn "$svc_user" 2>/dev/null || printf '%s' "$svc_user")
    chown root:"$svc_group" "$TLS_DIR" "$TLS_DIR/server.key" "$TLS_DIR/server.crt"
    chmod 750 "$TLS_DIR"
    chmod 640 "$TLS_DIR/server.key"
  fi
  openssl x509 -in "$TLS_DIR/server.crt" -noout -checkend 0 >/dev/null
  # Ensure private key and certificate match.
  local a b
  a=$(openssl pkey -in "$TLS_DIR/server.key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  b=$(openssl x509 -in "$TLS_DIR/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ "$a" == "$b" ]] || die "证书与私钥不匹配。"
}
open_firewall() {
  local p=$1 changed=0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${p}/tcp" || warn "UFW 放行失败，请手动开放 TCP ${p}。"
    changed=1
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${p}/tcp" && firewall-cmd --reload || warn "Firewalld 放行失败，请手动开放 TCP ${p}。"
    changed=1
  elif command -v iptables >/dev/null 2>&1; then
    warn "未自动修改 iptables；请确认系统防火墙允许 TCP ${p}。"
  else
    warn "未检测到活动防火墙；还需检查云厂商安全组是否放行 TCP ${p}。"
  fi
  (( changed == 1 )) || true
  warn "同时检查 VPS 云安全组/网络 ACL：必须放行 TCP ${p}。"
}
get_public_ip() {
  local ip=""
  ip=$(curl -4fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if [[ -z "$ip" ]]; then ip=$(curl -6fsS --connect-timeout 4 --max-time 8 https://api64.ipify.org 2>/dev/null || true); fi
  if [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then printf '%s' "$ip"; else printf 'YOUR_SERVER_IP'; fi
}
uri_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}
ensure_systemd() {
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}
config_base() {
  if [[ -s "$CONFIG" ]]; then
    jq -e 'type == "object" and (.inbounds == null or (.inbounds|type=="array"))' "$CONFIG" >/dev/null \
      || die "现有 $CONFIG 不是可识别的 sing-box JSON 配置，已停止以避免覆盖。"
    cat "$CONFIG"
  else
    jq -n '{log:{level:"info",timestamp:true},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}'
  fi
}
write_config() {
  local new_inbounds=$1 tmp old legacy_r_port="" legacy_t_port=""
  tmp=$(mktemp "${CONFIG}.XXXXXX")
  old=$(config_base)
  if [[ -s "$LEGACY_INFO" ]]; then
    legacy_r_port=$(jq -r '.reality.port // empty' "$LEGACY_INFO" 2>/dev/null || true)
    legacy_t_port=$(jq -r '.anytls.port // empty' "$LEGACY_INFO" 2>/dev/null || true)
  fi
  # Replace this manager's tagged entries. Migrate only untagged V1 inbounds matching its old metadata.
  printf '%s\n' "$old" | jq --argjson add "$new_inbounds" --arg legacy_r "$legacy_r_port" --arg legacy_t "$legacy_t_port" '
    .inbounds = ((.inbounds // []) | map(select(
      ((.tag // "") != "any-manager-vless-reality") and
      ((.tag // "") != "any-manager-anytls-reality") and
      ((.tag // "") != "any-manager-anytls") and
      ((.tag // "") != "in-vless-reality") and
      ((.tag // "") != "in-anytls") and
      (((.tag // "") == "" and (.type // "") == "anytls" and (.tls.reality.enabled // false) == true and $legacy_r != "" and ((.listen_port // 0)|tostring) == $legacy_r) | not) and
      (((.tag // "") == "" and (.type // "") == "anytls" and (.tls.certificate_path // "") == "/root/AnyTLS/tls/server.crt" and $legacy_t != "" and ((.listen_port // 0)|tostring) == $legacy_t) | not)
    )) + $add)
    | .outbounds = (if ((.outbounds // []) | length) == 0 then [{"type":"direct","tag":"direct"}] else .outbounds end)
    | .log = (.log // {"level":"info","timestamp":true})
  ' > "$tmp"
  chmod 600 "$tmp"
  if ! sing-box check -c "$tmp"; then
    rm -f -- "$tmp"
    die "Sing-box 配置检查失败，原配置未更改。"
  fi
  backup_current
  mv -f "$tmp" "$CONFIG"
  local svc_user svc_group
  svc_user=$(systemctl show -p User --value "$SERVICE" 2>/dev/null || true)
  if [[ -n "$svc_user" ]]; then
    svc_group=$(id -gn "$svc_user" 2>/dev/null || printf '%s' "$svc_user")
    chown root:"$svc_group" "$CONFIG"
    chmod 640 "$CONFIG"
  else
    chmod 600 "$CONFIG"
  fi
}
set_runtime_permissions() {
  local run_user run_group
  run_user=$(systemctl show -p User --value "$SERVICE" 2>/dev/null || true)
  if [[ -z "$run_user" || "$run_user" == root ]]; then
    chmod 700 /etc/sing-box
    [[ -d "$TLS_DIR" ]] && chmod 700 "$TLS_DIR"
    [[ -f "$TLS_DIR/server.key" ]] && chmod 600 "$TLS_DIR/server.key"
    [[ -f "$TLS_DIR/server.crt" ]] && chmod 644 "$TLS_DIR/server.crt"
    [[ -f "$CONFIG" ]] && chmod 600 "$CONFIG"
  else
    run_group=$(id -gn "$run_user" 2>/dev/null || printf '%s' "$run_user")
    chown root:"$run_group" /etc/sing-box "$CONFIG"
    chmod 750 /etc/sing-box
    chmod 640 "$CONFIG"
    if [[ -d "$TLS_DIR" ]]; then
      chown root:"$run_group" "$TLS_DIR"
      chmod 750 "$TLS_DIR"
    fi
    if [[ -f "$TLS_DIR/server.key" ]]; then
      chown root:"$run_group" "$TLS_DIR/server.key"
      chmod 640 "$TLS_DIR/server.key"
    fi
    if [[ -f "$TLS_DIR/server.crt" ]]; then
      chown root:"$run_group" "$TLS_DIR/server.crt"
      chmod 644 "$TLS_DIR/server.crt"
    fi
  fi
}

restart_checked() {
  ensure_systemd
  if systemctl restart "$SERVICE" && systemctl is-active --quiet "$SERVICE"; then
    ok "sing-box 已成功启动。"
  else
    err "服务启动失败。"
    journalctl -u "$SERVICE" -n 60 --no-pager || true
    return 1
  fi
}
save_info() {
  local obj=$1 tmp
  tmp=$(mktemp "${INFO}.XXXXXX")
  printf '%s\n' "$obj" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INFO"
}

deploy() {
  clear 2>/dev/null || true
  printf '%s\n' "部署模式：" "1. AnyTLS + REALITY（保留原 AnyReality 设计）" \
    "2. AnyTLS + 普通 TLS" "3. 双模式同时部署" "0. 返回"
  local mode
  read -r -p "选择 [0-3]: " mode
  [[ "$mode" == 0 ]] && return
  [[ "$mode" =~ ^[123]$ ]] || { warn "无效选项"; pause; return; }

  install_deps
  install_singbox
  require_anytls_version
  prepare_dirs
  [[ -f /root/.sb_info.json ]] && chmod 600 /root/.sb_info.json

  local inbounds='[]' info='{}' ports=()
  local r_port="" r_pwd="" r_priv="" r_pub="" r_sid="" r_sni=""
  local t_port="" t_pwd="" t_sni=""

  if [[ "$mode" == 1 || "$mode" == 3 ]]; then
    echo
    r_port=$(ask_port "AnyTLS-Reality 监听端口" "1443")
    ports+=("$r_port")
    r_sni=$(ask_domain "Reality 握手目标域名" "www.microsoft.com")
    read -r -s -p "AnyTLS-Reality 密码 [留空自动生成]: " r_pwd
    printf '\n'
    r_pwd=${r_pwd:-$(random_secret)}
    r_sid=$(openssl rand -hex 4)
    local kp
    kp=$(sing-box generate reality-keypair)
    r_priv=$(awk '/PrivateKey/{print $2}' <<<"$kp")
    r_pub=$(awk '/PublicKey/{print $2}' <<<"$kp")
    [[ -n "$r_priv" && -n "$r_pub" ]] || die "Reality 密钥生成失败，sing-box 输出格式不符合预期。"
    local r_json
    [[ "$r_sid" =~ ^[0-9a-f]{8}$ ]] || die "Reality short_id 生成结果不合法。"
    r_json=$(jq -n --arg s "$r_sni" --arg k "$r_priv" --arg id "$r_sid" \
      --arg pwd "$r_pwd" --argjson p "$r_port" --argjson padding "$DEFAULT_PADDING" '{
        type:"anytls",tag:"any-manager-anytls-reality",listen:"::",listen_port:$p,
        users:[{name:"user",password:$pwd}],padding_scheme:$padding,
        tls:{enabled:true,server_name:$s,reality:{
          enabled:true,handshake:{server:$s,server_port:443},
          private_key:$k,short_id:[$id]
        }}
      }')
    inbounds=$(jq --argjson x "$r_json" '. + [$x]' <<<"$inbounds")
    info=$(jq --arg p "$r_port" --arg s "$r_sni" --arg pwd "$r_pwd" --arg pk "$r_pub" --arg id "$r_sid" \
      '. + {reality:{port:$p,sni:$s,password:$pwd,pbk:$pk,sid:$id}}' <<<"$info")
  fi

  if [[ "$mode" == 2 || "$mode" == 3 ]]; then
    echo
    t_port=$(ask_port "AnyTLS 监听端口" "2026")
    [[ " ${ports[*]} " == *" ${t_port} "* ]] && die "两个协议端口不能重复。"
    ports+=("$t_port")
    t_sni=$(ask_domain "AnyTLS 证书域名（自签证书 SAN）" "www.microsoft.com")
    read -r -s -p "AnyTLS 密码 [留空自动生成]: " t_pwd
    printf '\n'
    t_pwd=${t_pwd:-$(random_secret)}
    make_cert "$t_sni"
    local t_json
    t_json=$(jq -n --arg pwd "$t_pwd" --argjson p "$t_port" --argjson padding "$DEFAULT_PADDING" \
      --arg cert "$TLS_DIR/server.crt" --arg key "$TLS_DIR/server.key" '{
        type:"anytls",tag:"any-manager-anytls",listen:"::",listen_port:$p,
        users:[{name:"user",password:$pwd}],padding_scheme:$padding,
        tls:{enabled:true,certificate_path:$cert,key_path:$key}
      }')
    inbounds=$(jq --argjson x "$t_json" '. + [$x]' <<<"$inbounds")
    info=$(jq --arg p "$t_port" --arg pwd "$t_pwd" --arg s "$t_sni" \
      '. + {anytls:{port:$p,password:$pwd,sni:$s,insecure:true}}' <<<"$info")
  fi

  write_config "$inbounds"
  for p in "${ports[@]}"; do open_firewall "$p"; done
  if ! restart_checked; then
    err "新配置启动失败，正在恢复上一份配置。"
    if [[ -n "$LAST_BACKUP" && -s "$LAST_BACKUP" ]]; then
      cp -a "$LAST_BACKUP" "$CONFIG"
      set_runtime_permissions || true
      systemctl restart "$SERVICE" || true
    else
      rm -f "$CONFIG"
      systemctl stop "$SERVICE" || true
    fi
    return 1
  fi
  save_info "$info"
  show_links
}
show_links() {
  [[ -s "$INFO" ]] || { warn "没有已保存的节点信息。"; pause; return; }
  local ip; ip=$(get_public_ip)
  if [[ "$ip" == "YOUR_SERVER_IP" ]]; then
    read -r -p "无法自动获取公网 IP，请输入服务器 IP 或域名: " ip
    [[ -n "$ip" ]] || { warn "未提供服务器地址。"; pause; return; }
  fi
  local host="$ip"
  [[ "$ip" == *:* ]] && host="[$ip]"
  echo
  echo "================ 节点链接 ================"
  if jq -e '.reality' "$INFO" >/dev/null; then
    local p s pwd pk sid name
    p=$(jq -r '.reality.port' "$INFO"); s=$(jq -r '.reality.sni' "$INFO")
    pwd=$(jq -r '.reality.password' "$INFO"); pk=$(jq -r '.reality.pbk' "$INFO"); sid=$(jq -r '.reality.sid' "$INFO")
    name=$(uri_encode "AnyTLS-Reality-${ip}")
    printf 'AnyTLS + REALITY（Shadowrocket / sing-box 分享链接）：\n'
    printf 'anytls://%s@%s:%s?security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' \
      "$(uri_encode "$pwd")" "$host" "$p" "$(uri_encode "$s")" "$pk" "$sid" "$name"
    printf '\nsing-box 客户端 outbound JSON：\n'
    jq -n --arg server "$ip" --argjson port "$p" --arg password "$pwd" --arg sni "$s" --arg pk "$pk" --arg sid "$sid" '{
      type:"anytls",tag:"anytls-reality-out",server:$server,server_port:$port,password:$password,
      tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$pk,short_id:$sid}}
    }'
    printf '\n'
  fi
  if jq -e '.anytls' "$INFO" >/dev/null; then
    local p pwd s name
    p=$(jq -r '.anytls.port' "$INFO"); pwd=$(jq -r '.anytls.password' "$INFO"); s=$(jq -r '.anytls.sni' "$INFO")
    name=$(uri_encode "AnyTLS-${ip}")
    printf 'AnyTLS（Shadowrocket / sing-box 分享链接；自签证书需允许 insecure）：\n'
    printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s\n' \
      "$(uri_encode "$pwd")" "$host" "$p" "$(uri_encode "$s")" "$name"
    if [[ -s "$TLS_DIR/server.crt" ]]; then
      local pin
      pin=$(openssl x509 -in "$TLS_DIR/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | openssl base64 -A)
      printf '\nsing-box 1.13.0+ 客户端 outbound JSON（公钥 pinning，不需要 insecure）：\n'
      jq -n --arg server "$ip" --argjson port "$p" --arg password "$pwd" --arg sni "$s" --arg pin "$pin" '{
        type:"anytls",tag:"anytls-out",server:$server,server_port:$port,password:$password,
        tls:{enabled:true,server_name:$sni,certificate_public_key_sha256:[$pin]}
      }'
    fi
    printf '\n'
  fi
  echo "提示：节点链接包含认证凭据，请勿公开分享。"
  echo "=========================================="
  pause
}
status() {
  echo "脚本版本：$VERSION"
  if command -v sing-box >/dev/null 2>&1; then sing-box version | head -n 2; else echo "sing-box：未安装"; fi
  systemctl status "$SERVICE" --no-pager -l 2>/dev/null || true
  if [[ -s "$INFO" ]]; then
    echo "管理器元数据：存在（权限 $(stat -c '%a' "$INFO" 2>/dev/null || echo '?')）"
    jq -r 'to_entries[] | "协议：\(.key)，端口：\(.value.port)"' "$INFO"
  fi
  pause
}
logs(){ journalctl -u "$SERVICE" -n 60 -f --no-pager; }
service_menu() {
  echo "1. 启动  2. 停止  3. 重启  4. 检查配置  0. 返回"
  local a; read -r -p "选择: " a
  case "$a" in
    1) systemctl start "$SERVICE";;
    2) systemctl stop "$SERVICE";;
    3) systemctl restart "$SERVICE";;
    4) sing-box check -c "$CONFIG";;
    0) return;;
    *) warn "无效选项";;
  esac
  pause
}
uninstall() {
  warn "卸载将移除本管理器添加的入站和证书，不会自动卸载 sing-box 核心，也不会删除其他入站。"
  read -r -p "确认卸载本管理器配置？输入 YES: " answer
  [[ "$answer" == YES ]] || { log "已取消。"; pause; return; }
  if [[ -s "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    local tmp; tmp=$(mktemp "${CONFIG}.XXXXXX")
    backup_current
    local legacy_r_port="" legacy_t_port=""
    if [[ -s "$LEGACY_INFO" ]]; then
      legacy_r_port=$(jq -r '.reality.port // empty' "$LEGACY_INFO" 2>/dev/null || true)
      legacy_t_port=$(jq -r '.anytls.port // empty' "$LEGACY_INFO" 2>/dev/null || true)
    fi
    jq --arg legacy_r "$legacy_r_port" --arg legacy_t "$legacy_t_port" 'del(.inbounds[] | select(
      (.tag // "") == "any-manager-vless-reality" or
      (.tag // "") == "any-manager-anytls-reality" or
      (.tag // "") == "any-manager-anytls" or
      (.tag // "") == "in-vless-reality" or
      (.tag // "") == "in-anytls" or
      ((.tag // "") == "" and (.type // "") == "anytls" and (.tls.reality.enabled // false) == true and $legacy_r != "" and ((.listen_port // 0)|tostring) == $legacy_r) or
      ((.tag // "") == "" and (.type // "") == "anytls" and (.tls.certificate_path // "") == "/root/AnyTLS/tls/server.crt" and $legacy_t != "" and ((.listen_port // 0)|tostring) == $legacy_t)
    ))' "$CONFIG" > "$tmp"
    chmod 600 "$tmp"
    if sing-box check -c "$tmp"; then
      mv -f "$tmp" "$CONFIG"
      set_runtime_permissions
      systemctl restart "$SERVICE" || warn "服务重启失败，请检查日志。"
    else
      rm -f -- "$tmp"
      die "清理后的配置校验失败，原配置保持不变。"
    fi
  fi
  rm -rf -- "$TLS_DIR"
  rm -rf -- /root/AnyTLS/tls
  rm -f -- "$INFO" /root/.sb_info.json /root/any.sh
  if [[ -f "$SHORTCUT" ]] && grep -q 'ANYSH_MANAGED_SHORTCUT_V2' "$SHORTCUT"; then rm -f -- "$SHORTCUT"; fi
  rm -f -- "$SCRIPT_COPY"
  rmdir -- "$(dirname "$SCRIPT_COPY")" 2>/dev/null || true
  ok "本管理器创建的入站、元数据、证书和快捷命令已清理。sing-box 核心及其余配置保留。"
  pause
}
full_uninstall() {
  warn "彻底卸载会停止并移除 sing-box 程序包、/etc/sing-box 全部配置及备份。其他业务共用此核心时不要执行。"
  read -r -p "确认继续？请输入 UNINSTALL SING-BOX：" answer
  [[ "$answer" == "UNINSTALL SING-BOX" ]] || { log "已取消。"; pause; return; }
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  local pm; pm=$(detect_pkg_manager || true)
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y sing-box || true ;;
    dnf) dnf remove -y sing-box || true ;;
    yum) yum remove -y sing-box || true ;;
  esac
  rm -rf -- /etc/sing-box
  rm -f -- "$INFO" /root/.sb_info.json /root/any.sh
  if [[ -f "$SHORTCUT" ]] && grep -q 'ANYSH_MANAGED_SHORTCUT_V2' "$SHORTCUT"; then rm -f -- "$SHORTCUT"; fi
  rm -f -- "$SCRIPT_COPY"
  rmdir -- "$(dirname "$SCRIPT_COPY")" 2>/dev/null || true
  rm -rf -- /root/AnyTLS
  ok "已执行 sing-box 全量卸载清理。"
  pause
}

register_shortcut() {
  install -d -m 755 "$(dirname "$SCRIPT_COPY")"
  if [[ "$0" != "$SHORTCUT" && "$0" != "$SCRIPT_COPY" && -f "$0" && -r "$0" ]]; then
    install -m 700 "$0" "$SCRIPT_COPY"
  elif [[ ! -s "$SCRIPT_COPY" ]]; then
    warn "当前不是可复制的本地脚本文件；请先下载 Any.sh，再运行 bash Any.sh。"
    return 1
  fi
  if [[ -e "$SHORTCUT" && ! -f "$SHORTCUT" ]]; then
    warn "$SHORTCUT 已存在且不是普通文件，跳过快捷命令注册。"; return 1
  fi
  if [[ -f "$SHORTCUT" ]] && ! grep -q 'ANYSH_MANAGED_SHORTCUT_V2' "$SHORTCUT"; then
    warn "$SHORTCUT 已被其他程序占用，拒绝覆盖。"; return 1
  fi
  cat > "$SHORTCUT" <<'EOF'
#!/usr/bin/env bash
# ANYSH_MANAGED_SHORTCUT_V2
exec bash /usr/local/lib/any-manager/Any.sh "$@"
EOF
  chmod 755 "$SHORTCUT"
}
main() {
  require_root
  register_shortcut || true
  while true; do
    clear 2>/dev/null || true
    echo "=============================================="
    echo "      sing-box AnyTLS-Reality / AnyTLS 管理器"
    echo "                    V${VERSION}"
    echo "=============================================="
    if systemctl is-active --quiet "$SERVICE"; then ok "sing-box：运行中"; else warn "sing-box：未运行或未安装"; fi
    echo "1. 安装 / 重构节点"
    echo "2. 服务管理"
    echo "3. 查看节点链接"
    echo "4. 查看运行状态"
    echo "5. 实时日志（Ctrl+C 返回）"
    echo "6. 卸载本管理器配置（保留其他入站和核心）"
    echo "7. 完全卸载 sing-box（危险操作）"
    echo "0. 退出"
    read -r -p "请选择 [0-7]: " choice || exit 0
    case "$choice" in
      1) deploy ;;
      2) service_menu ;;
      3) show_links ;;
      4) status ;;
      5) logs || true ;;
      6) uninstall ;;
      7) full_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}
main "$@"
