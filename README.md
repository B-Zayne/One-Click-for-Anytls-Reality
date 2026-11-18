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
if [ "$(id -u)" != 0 ]; then echo "请先使用 root 登录"; exit 1; fi; if command -v apk >/dev/null 2>&1; then apk add --no-cache bash curl ca-certificates; elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y bash curl ca-certificates; else echo "不支持的系统"; exit 1; fi && curl -fsSL "https://raw.githubusercontent.com/B-Zayne/One-Click-for-Anytls-Reality/refs/heads/main/Any-MultiOS-128M-V2.sh" -o /root/Any.sh && bash /root/Any.sh

