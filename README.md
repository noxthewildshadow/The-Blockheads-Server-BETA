# The BlockHeads Server - Complete Installation Guide

## Introduction

This guide will help you set up your own The BlockHeads server on a Linux system. The installation process is automated and designed to be as simple as possible, even for users with limited technical experience.

## Prerequisites

Before you begin, ensure you have:
- A Linux server (22.04)
- At least 2GB of RAM (4GB+ recommended for multiple players)
- 25GB of free disk space
- sudo/root access to the server

## Quick Installation

Run this single command to install everything automatically:

```bash
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-BETA/refs/heads/main/installer.sh | sudo bash
```

The script will:
1. Install required dependencies
2. Download the server files
3. Set up the server manager and economy bot
4. Apply compatibility patches

## Step-by-Step Guide

### 1. Connect to Your Server

If you're using a remote server, connect via SSH:
```bash
ssh username@your-server-ip
```

### 2. Run the Installation

Execute the installation command:
```bash
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-BETA/refs/heads/main/installer.sh | sudo bash
```

### 3. Create Your First World

After installation, create your first world:
```bash
cd ~
./blockheads_server171 -n
```

Follow the on-screen instructions to set up your world. When finished, press `CTRL+C` to exit.

### 4. Start the Server

Start your server with your world name:
```bash
./server_manager.sh start MyWorldID 12153
```

Replace "MyWorldID" with your actual world ID.

### 5. Connect to Your Server

Open The BlockHeads game on your device and connect using:
- IP: Your server's IP address
- Port: 12153 (or whatever port you specified)

## Server Management

### Starting the Server
```bash
./server_manager.sh start WorldName 12153
```

### Stopping the Server
```bash
./server_manager.sh stop
```

### Checking Status
```bash
./server_manager.sh status
```

### Viewing All Running Servers
```bash
./server_manager.sh list
```

## Economy System Features

Your server includes an automated economy system with these features:

- **Login Rewards**: Players get 1 ticket every hour they're online
- **Rank Purchases**: 
  - MOD rank: 10 tickets
  - ADMIN rank: 20 tickets
- **Gift System**:
  - Gift MOD to another player: 15 tickets
  - Gift ADMIN to another player: 30 tickets

### Available Commands for Players:
- `!tickets` - Check your ticket balance
- `!buy_mod` - Purchase MOD rank
- `!buy_admin` - Purchase ADMIN rank
- `!give_mod PLAYERNAME` - Gift MOD rank to another player
- `!give_admin PLAYERNAME` - Gift ADMIN rank to another player
- `!economy_help` - Show economy commands

## Advanced Configuration

### Running Multiple Servers

You can run multiple worlds on different ports:
```bash
# First server
./server_manager.sh start World1 12153

# Second server (in a different terminal or screen session)
./server_manager.sh start World2 12154
```

### Admin Commands

Server operators can use these commands in the bot terminal:
- `!send_ticket PLAYERNAME AMOUNT` - Give tickets to a player
- `!set_mod PLAYERNAME` - Set a player as MOD (console only)
- `!set_admin PLAYERNAME` - Set a player as ADMIN (console only)

## Troubleshooting

### Common Issues

1. **Port already in use**
   ```bash
   # Use a different port
   ./server_manager.sh start MyWorld 12154
   ```

2. **World not found**
   - Make sure you created the world first with `./blockheads_server171 -n`

3. **Permission denied errors**
   - Ensure you're using `sudo` for installation
   - Check file permissions with `ls -la`

4. **Server won't start**
   - Check if all dependencies are installed: `sudo apt-get install -y libgnustep-base1.28 libdispatch0 patchelf wget jq screen lsof`

### Getting Help

If you encounter issues:

1. Check the troubleshooting section above
2. Ensure your server meets the minimum requirements
3. Check the GitHub repository for updates: https://github.com/noxthewildshadow/TheBlockHeads-Server-BETA
4. Create an issue on GitHub if you've found a bug

## Security Notes

- Change default ports for better security
- Regularly update your server software
- Use a firewall to restrict access to necessary ports only
- Consider using VPN for private servers

## Support

For additional help:
1. Check the GitHub repository: https://github.com/noxthewildshadow/TheBlockHeads-Server-BETA
2. Create an issue on GitHub for bugs or problems
3. Check existing issues for solutions to common problems

## Congratulations!

You've successfully set up your own The BlockHeads server! Enjoy playing with your friends on your custom server.

Remember to regularly back up your world files located in:
`~/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/`

Happy gaming!
