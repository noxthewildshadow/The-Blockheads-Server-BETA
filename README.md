````md
# The BlockHeads Server  
### Secure Private Server with Exploit Fixes, Mods & Rank System  
**Complete Linux Installation Guide**

---

## Overview

This project allows you to host your **own private The BlockHeads server** on Linux with **critical exploit fixes**, **optional mods**, and an **advanced Rank & Security system**.

The installer is fully automated and will:

- Set up the official server binary
- Fix library compatibility issues
- Compile **C-based patches and mods** into `.so` modules
- Provide an interactive server manager
- Optionally enable a **password + IP verification system**

No prior experience with compiling C code or managing game servers is required.

---

## System Requirements

### Operating System
- **Linux (64-bit)**
  - Recommended: **Ubuntu 22.04+**
  - Compatible with Debian-based or Arch-based distributions

### Access
- Root or **sudo** privileges

### Hardware
- **Minimum:**  
  - 2 GB RAM  
  - 25 GB free disk space
- **Recommended (with mods):**  
  - 4 GB RAM or more

### Required Tools
- `curl` (used only to download the installer)

---

## What This Installer Includes

✔ Official BlockHeads server binary  
✔ Automatic dependency installation  
✔ Binary compatibility fixes  
✔ **Mod Loader system** (`.so` patches)  
✔ **Critical exploit fixes (always enabled)**  
✔ Optional gameplay & admin mods  
✔ Interactive server manager  
✔ Optional **Rank & Password security system**

---

## Installation (Step by Step)

### Step 1 – Connect to Your Server (VPS Only)

If you are using a VPS or remote machine:

```bash
ssh your_user@SERVER_IP
````

If you are installing locally, skip this step.

---

### Step 2 – Verify `curl` is Installed

Check if `curl` exists:

```bash
curl --version
```

If not installed (Ubuntu / Debian):

```bash
sudo apt update
sudo apt install curl -y
```

---

### Step 3 – Run the Automated Installer

This single command performs the full setup:

```bash
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/installer.sh | sudo bash
```

#### What the installer does internally:

1. Installs required packages:

   * `clang`
   * `make`
   * `screen`
   * system libraries

2. Downloads the official server binary

3. Fixes missing or incompatible libraries

4. Compiles **C source files (`.c`) into shared modules (`.so`)**

5. Organizes patches into:

   ```
   patches/
   ├── critical/
   ├── optional/
   └── mods/
   ```

**Critical security patches are always enabled and cannot be disabled**

---

## Creating Your First World

After installation finishes, create a world:

```bash
./blockheads_server171 -n
```

Follow the on-screen setup:

* World name
* World configuration

When finished:

* Press **CTRL + C** to exit safely

### List existing worlds:

```bash
./blockheads_server171 -l
```

---

## ▶ Starting the Server (Interactive Mode)

Use the server manager script:

```bash
./server_manager.sh start YourWorldID 12153
```

Replace:

* `YourWorldID` → your world name
* `12153` → server port (default)

---

### Interactive Startup Options

During startup, you will be prompted:

#### Enable Rank Manager & Security?

```
Start Rank Manager (Security & Ranks)? (y/N):
```

* `y` → Enables password + IP verification
* `n` → Runs vanilla-style server (no login system)

#### Enable Optional Mods?

* Each available mod is listed
* You choose **yes or no for each**
* Mods load **only for this session**

✔ Critical patches load automatically
✔ Optional mods are fully configurable

---

## Connecting In-Game

Open **The BlockHeads** and connect using:

* **IP:** Your server IP
* **Port:** `12153` (or the port you selected)

---

## Mods & Patch System Explained

All patches are written in **C** and loaded as `.so` modules.

### Critical Patches (Always Enabled)

* **`name_exploit`**

  * Blocks empty names
  * Blocks invalid characters
  * Prevents spoofed exploit strings

---

### ⚙ Optional Mods (Selectable on Startup)

| Mod                        | Description                                     |
| -------------------------- | ----------------------------------------------- |
| `ban_all_new_drops`        | Prevents new item drops (anti-lag / anti-grief) |
| `chest_dupe_plus_any_item` | Special chest duplication mechanics             |
| `fill_chest_with_any_id`   | Admin tool to spawn items                       |
| `mob_spawner`              | Custom mob spawning                             |
| `pause_server_world`       | Freeze world state                              |
| `place_banned_blocks`      | Allows restricted block placement               |
| `spawn_any_tree`           | Custom tree spawning                            |
| `freight_car_patch`        | Fixes freight car crashes                       |
| `portal_chest_patch`       | Fixes portal chest exploits                     |

---

## Server Management Commands

All server control is handled via:

```bash
./server_manager.sh
```

### Start Server

```bash
./server_manager.sh start WorldID Port
```

### Stop Server Safely

```bash
./server_manager.sh stop Port
```

Stop **all servers**:

```bash
./server_manager.sh stop
```

### Check Server Status

```bash
./server_manager.sh status Port
```

---

## Viewing the Live Console

Attach to the server screen:

```bash
screen -r blockheads_server_12153
```

Detach without stopping the server:

```
CTRL + A → D
```

---

## Rank & Security System (Optional)

If enabled, `rank_manager.sh` runs in the background.

### Features

✔ Password-protected accounts
✔ IP verification
✔ Automatic kick for unverified users
✔ Prevents impersonation & hijacking

---

### In-Game Commands

Register password:

```
!psw PASSWORD PASSWORD
```

Change password:

```
!change_psw OLD_PASSWORD NEW_PASSWORD
```

Verify after IP change:

```
!ip_change PASSWORD
```

---

## Troubleshooting

### Port Already in Use

```bash
./server_manager.sh stop PORT
```

Or choose another port (e.g. `12154`).

---

### Permission Denied

```bash
chmod +x installer.sh server_manager.sh rank_manager.sh
```

---

### Mods Not Compiling

```bash
./server_manager.sh install-deps
```

Verify compiled modules:

```bash
ls patches/*/*.so
```

---

## Support & Community

Official Discord for updates and support:
https://discord.gg/TTNCvguEmV

```
