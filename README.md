# The BlockHeads Server - Complete Installation Guide

## Introduction

Welcome\! This guide will help you install your own The BlockHeads server on a Linux system. The process is automated to be as simple as possible, even if you don't have much technical experience.

## Prerequisites

Before you begin, make sure you have:

  * **Linux Server (OS):** Recommended: Ubuntu 22.04+ or any modern system based on Debian or Arch.
  * **Root/Sudo Access:** Required to install programs.
  * **`curl` Command:** The installer needs this to download itself.
  * **Hardware:**
      * At least 2GB of RAM (4GB+ recommended for many servers running).
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

This is the main command. It will download and run the installation script. It will ask for your `sudo` password.

```bash
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-BETA/refs/heads/main/installer.sh | sudo bash
```

The script will automatically do the following:

1.  Install all required dependencies (libraries, `screen`, etc.).
2.  Download the The BlockHeads server files.
3.  Download the `server_manager.sh` and `rank_patcher.sh` scripts.
4.  Apply compatibility patches to the server binary.

### 4\. Create Your First World

Once the installation is finished, create your world. The server binary has a tool for this:

```bash
./blockheads_server171 -n
```

Follow the on-screen instructions to name and configure your world. **When finished, press `CTRL+C` to exit** and return to the terminal.

*To see a list of the worlds you've created, you can use: `./blockheads_server171 -l`*

### 5\. Start Your Server

Now, use the server manager to start your world.

```bash
./server_manager.sh start YourWorldID 12153
```

  * Replace `YourWorldName` with the name or ID of the world you created in step 4.
  * `12153` is the default port. You can change it if you want.

The manager will start the server and the security script (`rank_patcher`) in the background.

### 6\. Connect in the Game

You're all set\! Open The BlockHeads on your phone or PC and connect using:

  * **IP:** Your server's IP address.
  * **Port:** `12153` (or the port you chose).

-----

## Server Management

Use the `server_manager.sh` script to control your server.

### Starting the Server

```bash
./server_manager.sh start YourWorldID 12153
```

### Stopping the Server (Safely)

This will stop both the server and the security script.

```bash
./server_manager.sh stop 12153
```

*To stop ALL running servers, just use: `./server_manager.sh stop`*

### Checking Status

Shows if the server and patcher are "RUNNING" or "STOPPED".

```bash
./server_manager.sh status 12153
```

### Viewing the Server Console

To see the live server console (and type admin commands), use:

```bash
screen -r blockheads_server_12153
```

*To exit the console without stopping the server, press: `CTRL+A` and then `D`.*

### Listing All Servers

Shows all servers that are currently running in their `screen` sessions.

```bash
./server_manager.sh list
```

-----

## Important\! Back Up Your Worlds

Your world files are the most important thing. They are saved in the following folder:
`~/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/`

Be sure to make regular backups of this folder.

-----

## Security and Rank System (Rank Patcher)

Your server includes a script (`rank_patcher.sh`) that automatically handles player security and ranks.

  * **Player Authentication:** Verifies a player's IP. If their IP changes, the script will ask them to verify their identity with their password.
  * **Password Protection:** All players must create a password to protect their account.
  * **Automated Ranks:** Applies MOD/ADMIN/SUPER ranks based on the `players.log` file. (The server owner manages this; it is not a "shop").

### Player Commands (in the in-game chat):

  * `!psw YOUR_PASSWORD YOUR_PASSWORD`
    (Use this the first time you join to create your password).

  * `!change_psw OLD_PASSWORD NEW_PASSWORD`
    (To change your password).

  * `!ip_change YOUR_PASSWORD`
    (Use this if the server asks you to verify your identity due to an IP change).

-----

## Advanced: Running Multiple Servers

You can run several worlds at the same time, as long as you use different ports.

```bash
# Server 1
./server_manager.sh start MyWorldID1 12153

# Server 2
./server_manager.sh start MyWorldID2 12154
```

-----

## Troubleshooting

1.  **"Port already in use"**

      * This means another program (or another BH server) is already using that port.
      * **Solution:** Choose a different port (e.g., 12154, 12155, etc.).

    <!-- end list -->

    ```bash
    ./server_manager.sh start YourWorldID 12154
    ```

2.  **"World not found"**

      * **Solution:** Make sure you created the world first with `./blockheads_server171 -n`.
      * Check that you spelled the name exactly right. Use `./blockheads_server171 -l` to see the correct names.

3.  **"Permission denied"**

      * **Solution:** Make sure the `.sh` files are executable: `chmod +x server_manager.sh rank_patcher.sh`

4.  **Server won't start (Missing Dependencies)**

      * The installer should have handled this, but if it fails, you can try reinstalling the dependencies manually using the manager:

    <!-- end list -->

    ```bash
    ./server_manager.sh install-deps
    ```

## Support

If you still have problems:

1.  Re-read the "Troubleshooting" section.
2.  Visit the GitHub repository to see updates or "Issues" reported by others:
    `https://github.com/noxthewildshadow/TheBlockHeads-Server-BETA`
3.  If you find a new bug, create a new "Issue" on GitHub detailing the problem.
