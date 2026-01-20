---

# The BlockHeads Server with EXPLOIT FIXES & MODS

### Complete Installation Guide (Enhanced)

## Introduction

Welcome.
This guide explains how to install and run your own **private The BlockHeads server** on Linux.

This installer is **not a vanilla setup**. It provides:

* A fully automated server installation
* A **C-based Mod & Patch Loader**
* **Critical exploit fixes**
* An optional **Rank & Password Manager**
* Interactive startup with per-session mod selection

Everything is designed to be simple, reproducible, and secure.

---

## Prerequisites

Before starting, make sure your system meets the following requirements:

### System Requirements

* **Operating System:**

  * Ubuntu 22.04+ recommended
  * Any modern Debian-based or Arch-based distribution should work

* **Access:**

  * Root or sudo privileges are required

* **Required Tools:**

  * `curl` (used to download the installer)

### Hardware

* **RAM:**

  * Minimum: 2 GB
  * Recommended: 4 GB or more (especially when using mods)

* **Disk Space:**

  * At least 25 GB of free space

---

## Installation – Step by Step

Follow these steps in order.

---

### 1. Connect to Your Server (VPS Only)

If you are using a remote server (VPS or dedicated server), connect via SSH:

```bash
ssh your_user@SERVER_IP_ADDRESS
```

Skip this step if you are already working locally.

---

### 2. Verify `curl` Is Installed

Check if `curl` is available:

```bash
curl --version
```

If the command is not found, install it.

**Debian / Ubuntu:**

```bash
sudo apt update
sudo apt install curl -y
```

---

### 3. Run the Installer

This command downloads and executes the full installer:

```bash
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/installer.sh | sudo bash
```

#### What the installer does automatically

1. Installs all required dependencies
   (`clang`, `make`, `screen`, standard libraries, etc.)

2. Downloads the official BlockHeads server binary
   and fixes library compatibility issues

3. Compiles all patches and mods

   * Raw `.c` source files are compiled into `.so` shared libraries
   * These are dynamically loaded at runtime

4. Organizes everything into a clear structure:

```
patches/
├── critical/
├── optional/
└── mods/
```

Critical patches are always loaded.
Optional mods are selected interactively at startup.

---

### 4. Create Your First World

After installation, create a world using the server binary:

```bash
./blockheads_server171 -n
```

Follow the on-screen prompts to configure the world.

When finished, **press `CTRL + C`** to exit back to the terminal.

To list existing worlds:

```bash
./blockheads_server171 -l
```

---

### 5. Start the Server (Interactive Mode)

Start your world using the server manager:

```bash
./server_manager.sh start YourWorldID 12153
```

* Replace `YourWorldID` with your actual world name
* `12153` is the default port (you may change it)

#### Interactive startup options

During startup, you will be prompted for:

1. **Rank Manager (Security & Authentication)**

   * `y`: Enable password-based authentication and ranks
   * `n`: Run without external authentication (vanilla behavior)

2. **Optional patches and mods**

   * Each available module is listed
   * You can enable or disable them individually
   * **Critical security patches are always enabled automatically**

---

### 6. Connect From the Game

Open The BlockHeads and connect using:

* **IP:** Your server’s IP address
* **Port:** `12153` (or the port you selected)

---

## Mods & Patch System

This server supports **native C-based runtime patches**.

All patches are stored in the `patches/` directory and loaded as `.so` modules.

---

### Critical Patches (Always Enabled)

* **`name_exploit`**
  Prevents invalid player names, empty names, and known exploit strings.

These patches are mandatory and cannot be disabled.

---

### Optional Mods (Selectable at Startup)

You can enable these per session:

* **`ban_all_new_drops`**
  Prevents newly spawned items from dropping on the ground
  (anti-lag / anti-grief)

* **`chest_dupe_plus_any_item`**
  Modifies chest behavior for specific duplication mechanics

* **`fill_chest_with_any_id`**
  Admin tool to fill chests with specific item IDs

* **`mob_spawner`**
  Adds custom mob spawning mechanics

* **`pause_server_world`**
  Allows freezing the world state

* **`place_banned_blocks`**
  Allows admins to place normally restricted blocks

* **`spawn_any_tree`**
  Custom tree generation utilities

* **`freight_car_patch` / `portal_chest_patch`**
  Fixes or modifies item behavior to prevent crashes or exploits

---

## Server Management

All server control is handled via `server_manager.sh`.

---

### Start a Server

```bash
./server_manager.sh start YourWorldID 12153
```

---

### Stop a Server Safely

Stops the server, rank manager, and frees the port:

```bash
./server_manager.sh stop 12153
```

Stop all running servers:

```bash
./server_manager.sh stop
```

---

### Check Server Status

```bash
./server_manager.sh status 12153
```

Displays whether the server and rank manager are running.

---

### View the Live Console

```bash
screen -r blockheads_server_12153
```

Detach without stopping the server:

```
CTRL + A, then D
```

---

## Security & Rank System (Rank Manager)

If enabled during startup, `rank_manager.sh` runs in the background.

### Features

* IP-based player verification
* Mandatory password registration
* Auto-kick for unverified players
* Protection against identity spoofing

---

### In-Game Player Commands

* Register password:

  ```
  !psw YOUR_PASSWORD YOUR_PASSWORD
  ```

* Change password:

  ```
  !change_psw OLD_PASSWORD NEW_PASSWORD
  ```

* Verify after IP change:

  ```
  !ip_change YOUR_PASSWORD
  ```

---

## Troubleshooting

### Port already in use

```bash
./server_manager.sh stop PORT
```

Or choose another port (e.g. `12154`).

---

### Permission denied

```bash
chmod +x server_manager.sh rank_manager.sh installer.sh
```

---

### Mods not working / Compilation errors

* Ensure dependencies are installed:

  ```bash
  ./server_manager.sh install-deps
  ```
* Verify that `.so` files exist inside `patches/`
* Check compilation output during installer execution

---

## Support

Official Discord for updates and support:

```
https://discord.gg/YG22C2FCRp
```

