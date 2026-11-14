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

### Debian/Ubuntu

```bash
bash <(wget -qO- https://raw.githubusercontent.com/B-Zayne/One-Click-for-Anytls-Reality/refs/heads/main/Any.sh)
```

## Alpine

```bash
apk update && apk add --no-cache bash curl && curl -fsSL https://raw.githubusercontent.com/B-Zayne/One-Click-for-Anytls-Reality/refs/heads/main/Any.sh -o /root/any.sh && chmod +x /root/any.sh && bash /root/any.sh
```

### Alpine 128RAM
```bash
apk update && apk add --no-cache bash curl && rm -rf /var/cache/apk/* && curl -fsSL https://raw.githubusercontent.com/B-Zayne/One-Click-for-Anytls-Reality/refs/heads/main/any128.sh -o /root/any128.sh && chmod +x /root/any128.sh && bash /root/any128.sh
```
