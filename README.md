# AnyTLS & AnyReality One-Click Installation Script

An automated, lightweight Bash script to deploy and manage **AnyTLS** and **AnyReality** (`AnyTLS + REALITY`) proxy protocols powered by the official **Sing-Box** core.

Designed for anti-DPI stealth, zero-certificate deployment, and high TCP throughput, this script streamlines keypair generation, firewall configuration, and dual-protocol management into an interactive CLI.

---

## ✨ Features

* **Dual-Protocol Support**: Deploy **AnyReality** (certificate-free REALITY handshake), **AnyTLS** (self-signed ECC TLS), or both simultaneously.
* **Official Sing-Box Core**: Pulls directly from the official Sing-Box installation channel (`sing-box.app`) with clean `direct` outbound routing.
* **Automated Security**: Locally generates `x25519` keypairs, random passwords, and `short_id`s with strict file permission controls.
* **Smart Environment Setup**: Automatic port availability checks and UFW / Firewalld rule configuration.
* **Quick Management CLI**: Built-in `any` shortcut command for one-tap status checks, live log monitoring, link generation, and clean uninstallation.

---

## 🚀 Quick Installation

Run the following command as `root` on your Linux VPS (Debian / Ubuntu / CentOS / Rocky):

### Shortcut command

any


### Debian/Ubuntu/Alpine

```bash
sh -c 'set -e; [ "$(id -u)" -eq 0 ] || { echo "请使用 root 运行：sudo -i"; exit 1; }; URL="https://raw.githubusercontent.com/B-Zayne/One-Click-for-Anytls-Reality/refs/heads/main/Any-MultiOS-128M-V2.sh"; if [ -f /etc/alpine-release ]; then apk add --no-cache bash curl ca-certificates >/dev/null; elif command -v apt-get >/dev/null 2>&1; then if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bash curl ca-certificates; fi; elif command -v dnf >/dev/null 2>&1; then dnf install -y bash curl ca-certificates; elif command -v yum >/dev/null 2>&1; then yum install -y bash curl ca-certificates; fi; curl -fsSL "$URL" -o /tmp/any.sh; exec bash /tmp/any.sh'


