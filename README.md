# The BlockHeads Server with EXPLOIT FIXES & MODS - Complete Installation Guide

## Introduction

Welcome\! This guide will help you install your own private The BlockHeads server on a Linux system. This enhanced installer not only sets up the server but also includes a **Mod Loader**, **Security Patches**, and a **Rank Manager**. The process is automated to be as simple as possible.

## Prerequisites

Before you begin, make sure you have:

  * **Linux Server (OS):** Recommended: Ubuntu 22.04+ or any modern system based on Debian or Arch.
  * **Root/Sudo Access:** Required to install programs.
  * **`curl` Command:** The installer needs this to download itself.
  * **Hardware:**
      * At least 2GB of RAM (4GB+ recommended if running mods).
      * 25GB of disk space.

-----

## Installation: Step-by-Step

Follow these 6 steps to get your server running.

### 1\. Connect to Your Server (ONLY IF YOU USE A VPS)

If your server is remote (like a VPS), connect to it using SSH.

```bash
ssh your_user@SERVER_IP_ADDRESS
```

### 2\. Check if you have `curl`

Most systems already have it. Check with:

```bash
curl --version
```

If you don't see a version, install it (example for Debian/Ubuntu):

```bash
sudo apt update
sudo apt install curl -y
```

### 3\. Run the Installer

This is the main command. It will download the script, compile the necessary patches/mods from source code (`.c`), and set up the environment.

```bash
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/installer.sh | sudo bash
```

The script will automatically:

1.  Install dependencies (`clang`, `make`, `screen`, etc.).
2.  Download the server binary and fix library incompatibilities.
3.  **Compile Mods & Patches:** It will turn the raw C code into loadable modules (`.so`).
4.  Organize files into `patches/critical`, `patches/optional`, and `patches/mods`.

### 4\. Create Your First World

Once the installation is finished, create your world using the binary tool:

```bash
./blockheads_server171 -n
```

Follow the on-screen instructions to name and configure your world. **When finished, press `CTRL+C` to exit** and return to the terminal.

*To see a list of the worlds you've created, use: `./blockheads_server171 -l`*

### 5\. Start Your Server (Interactive Mode)

Now, use the server manager to start your world. This version is **interactive**.

```bash
./server_manager.sh start YourWorldID 12153
```

  * Replace `YourWorldID` with the name of the world you created.
  * `12153` is the default port.

**During startup, the script will ask you:**

1.  **Start Rank Manager (Security & Ranks)? (y/N):**
      * Type `y` to enable the password/rank system.
      * Type `n` to run a vanilla server without the external rank manager.
2.  **Enable patches/mods:**
      * It will list every available mod (e.g., `chest_dupe`, `mob_spawner`) and ask if you want to load it for this session.
      * *Note: Critical security patches (like `name_exploit`) are loaded automatically.*

### 6\. Connect in the Game

You're all set\! Open The BlockHeads on your phone or PC and connect using:

  * **IP:** Your server's IP address.
  * **Port:** `12153` (or the port you chose).

-----

## Mods & Patches System

Your server now supports custom C-based mods and patches. These are stored in the `patches/` folder.

### Critical Patches (Always Active)

  * **`name_exploit`**: Prevents players from joining with invalid names, empty names, or spoofed exploit strings.

### Optional Mods (Toggle on Startup)

You can choose to enable these when starting the server:

  * **`ban_all_new_drops`**: Prevents newly spawned items from dropping on the ground (lag reduction/anti-grief).
  * **`chest_dupe_plus_any_item`**: Allows specific chest interaction mechanics or duplication features.
  * **`fill_chest_with_any_id`**: Admin tool to fill chests with specific item IDs.
  * **`mob_spawner`**: Adds mechanics to spawn mobs.
  * **`pause_server_world`**: Can freeze the world state.
  * **`place_banned_blocks`**: Allows admins to place blocks that are usually restricted.
  * **`spawn_any_tree`**: Custom tree generation tools.
  * **`freight_car_patch` / `portal_chest_patch`**: Fixes or modifies behavior for specific items to prevent crashes/exploits.

-----

## Server Management

Use the `server_manager.sh` script to control your server.

### Starting the Server

```bash
./server_manager.sh start YourWorldID 12153
```

### Stopping the Server (Safely)

This stops the server, the rank manager, and cleans up the ports.

```bash
./server_manager.sh stop 12153
```

*To stop ALL running servers: `./server_manager.sh stop`*

### Checking Status

Shows if servers are RUNNING or STOPPED, and if the Rank Manager is active.

```bash
./server_manager.sh status 12153
```

### Viewing the Console

To see the live server console:

```bash
screen -r blockheads_server_12153
```

*To exit the console without stopping the server, press: `CTRL+A` then `D`.*

-----

## Security and Rank System (Rank Patcher)

If you chose **"Yes"** to the Rank Manager prompt during startup, the `rank_manager.sh` script is running in the background.

  * **Player Authentication:** Verifies IP addresses. If an IP changes, the player must verify with their password.
  * **Password Protection:** Players must create a password (`!psw`) to play.
  * **Auto-Kick:** Unverified players are kicked after a grace period.

### Player Commands (in-game chat):

  * `!psw YOUR_PASSWORD YOUR_PASSWORD`
    (Register your password).
  * `!change_psw OLD_PASSWORD NEW_PASSWORD`
    (Change password).
  * `!ip_change YOUR_PASSWORD`
    (Verify identity after IP change).

-----

## Troubleshooting

1.  **"Port already in use"**

      * Use `./server_manager.sh stop PORT` to free it, or choose a different port (e.g., 12154).

2.  **"Permission denied"**

      * Run: `chmod +x server_manager.sh rank_manager.sh installer.sh`

3.  **Mods not working / Compilation errors**

      * The installer tries to compile `.c` files to `.so`. If this failed, run `./server_manager.sh install-deps` to ensure you have `clang` and `make`.
      * Check `patches/` to ensure `.so` files exist.

## Support

Oficial discord for updates:
`https://discord.gg/TTNCvguEmV`
