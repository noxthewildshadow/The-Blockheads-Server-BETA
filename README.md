```md
# The BlockHeads Server  
### Secure Private Server with Exploit Fixes, Mods & Rank System

![Platform](https://img.shields.io/badge/platform-linux-blue)
![Architecture](https://img.shields.io/badge/arch-x86__64-green)
![Status](https://img.shields.io/badge/status-beta-orange)
![Security](https://img.shields.io/badge/security-patched-brightgreen)
![Mods](https://img.shields.io/badge/mods-supported-blueviolet)

---

## 📖 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [System Requirements](#-system-requirements)
- [Project Structure](#-project-structure)
- [Installation](#-installation)
- [World Creation](#-world-creation)
- [Starting the Server](#-starting-the-server)
- [Connecting In-Game](#-connecting-in-game)
- [Mods & Patches](#-mods--patches)
- [Server Management](#-server-management)
- [Rank & Security System](#-rank--security-system)
- [Troubleshooting](#-troubleshooting)
- [Support](#-support)

---

## 📌 Overview

This project provides a **fully patched and extensible private server** for **The BlockHeads** on Linux.

It includes **critical exploit fixes**, an **interactive mod loader**, and an optional **rank & password-based security system**, all installed using a **single automated script**.

No prior knowledge of Linux server management or C compilation is required.

---

## ✨ Features

- Official BlockHeads server binary
- Automatic dependency installation
- Binary compatibility fixes
- C-based mod & patch system (`.so`)
- Critical security patches (always enabled)
- Optional gameplay and admin mods
- Interactive server manager
- Password & IP-based player authentication
- Screen-based console management

---

## ✅ System Requirements

### Operating System
- Linux (64-bit)
  - Recommended: Ubuntu 22.04+
  - Debian / Arch compatible

### Hardware
- Minimum:
  - 2 GB RAM
  - 25 GB free disk space
- Recommended:
  - 4 GB+ RAM (mods enabled)

### Permissions
- Root or sudo access

### Required Tool
- `curl`

---

## 📁 Project Structure

```

.
├── blockheads_server171
├── installer.sh
├── server_manager.sh
├── rank_manager.sh
├── patches/
│   ├── critical/
│   ├── optional/
│   └── mods/
└── worlds/

````

---

## 🛠 Installation

### 1. Connect to Your Server (VPS only)

```bash
ssh your_user@SERVER_IP
````

Skip this step if installing locally.

---

### 2. Ensure `curl` Is Installed

```bash
curl --version
```

If missing:

```bash
sudo apt update && sudo apt install curl -y
```

---

### 3. Run the Installer

```bash
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/installer.sh | sudo bash
```

### Installer Actions

* Installs build tools (`clang`, `make`, `screen`)
* Downloads server binary
* Fixes missing libraries
* Compiles `.c` patches into `.so`
* Organizes patches by category

⚠️ Critical patches are **always active**.

---

## 🌍 World Creation

Create a new world:

```bash
./blockheads_server171 -n
```

Exit setup with **CTRL + C**

List worlds:

```bash
./blockheads_server171 -l
```

---

## ▶ Starting the Server

```bash
./server_manager.sh start WorldID 12153
```

### Interactive Prompts

1. **Enable Rank Manager?**

   * `y` → password & IP protection
   * `n` → vanilla mode

2. **Enable Optional Mods**

   * Select each mod individually
   * Loaded per-session

---

## 🎮 Connecting In-Game

* IP: your server IP
* Port: `12153` (default)

---

## 🧩 Mods & Patches

### 🔒 Critical (Always Enabled)

* **name_exploit**
  Prevents invalid or exploit-based player names.

---

### ⚙ Optional Mods

| Mod                      | Description                 |
| ------------------------ | --------------------------- |
| ban_all_new_drops        | Prevents new item drops     |
| chest_dupe_plus_any_item | Chest interaction mechanics |
| fill_chest_with_any_id   | Admin item spawning         |
| mob_spawner              | Mob spawning tools          |
| pause_server_world       | Freeze world state          |
| place_banned_blocks      | Place restricted blocks     |
| spawn_any_tree           | Custom tree spawning        |
| freight_car_patch        | Freight car crash fix       |
| portal_chest_patch       | Portal chest exploit fix    |

---

## 🧰 Server Management

### Start Server

```bash
./server_manager.sh start WorldID Port
```

### Stop Server

```bash
./server_manager.sh stop Port
```

Stop all servers:

```bash
./server_manager.sh stop
```

### Server Status

```bash
./server_manager.sh status Port
```

---

## 🖥 Console Access

Attach:

```bash
screen -r blockheads_server_12153
```

Detach:

```
CTRL + A → D
```

---

## 🔐 Rank & Security System

### Features

* Password-protected accounts
* IP verification
* Auto-kick for unverified users
* Anti-impersonation

### In-Game Commands

```
!psw PASSWORD PASSWORD
!change_psw OLD_PASSWORD NEW_PASSWORD
!ip_change PASSWORD
```

---

## 🧯 Troubleshooting

### Port in Use

```bash
./server_manager.sh stop PORT
```

### Permission Issues

```bash
chmod +x installer.sh server_manager.sh rank_manager.sh
```

### Mods Not Compiling

```bash
./server_manager.sh install-deps
ls patches/*/*.so
```

---

## 💬 Support

Official Discord server:
[https://discord.gg/TTNCvguEmV](https://discord.gg/TTNCvguEmV)

---
