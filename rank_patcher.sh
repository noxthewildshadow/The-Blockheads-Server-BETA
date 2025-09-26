#!/usr/bin/env bash
# rank_patcher.sh
# Author: Generated for user
# Purpose: Maintain players.log as authoritative source for ranks, passwords, IPs and privileges
# Targets: The Blockheads server manager setup that uses screen sessions named blockheads_server_<port>
# Requirements implemented:
#  - Create players.log automatically when a world exists
#  - Monitor players.log every 1 second and apply changes
#  - Tail console.log for chat commands (!password, !ip_change, !change_psw) and connection events
#  - Sync adminlist.txt, modlist.txt, whitelist.txt, blacklist.txt from players.log for connected and verified IP players
#  - Manage cloudWideOwnedAdminlist.txt for SUPER rank
#  - Enforce cooldowns, /clear usage and timers for password/ip verification
# NOTE: This script assumes server_manager.sh creates world_id_<port>.txt files and that servers run in
# screen sessions named blockheads_server_<port>. If your setup differs, adjust send_command_to_screen().

set -o errexit
set -o pipefail
set -o nounset

# Configuration
SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
GLOBAL_CLOUD_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
POLL_INTERVAL=1              # seconds: monitor players.log every 1 second
GENERAL_COOLDOWN=1           # seconds before sending any command or message
SHORT_COOLDOWN=0.5           # used between /clear and confirmation
TEMP_DIR="/tmp/rank_patcher_$$"
mkdir -p "$TEMP_DIR"

# Utilities
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# Ensure required tools
if ! command -v screen >/dev/null 2>&1; then
  err "screen is required but not found. Install screen and retry."; exit 1
fi

# Helper: safe read of first two header lines for txt files
preserve_header() {
  local file="$1"
  if [ -f "$file" ]; then
    head -n 2 "$file"
  else
    # default two header lines
    printf "# HEADER LINE 1\n# HEADER LINE 2\n"
  fi
}

# Helper: write list while preserving first two lines
write_list_preserve_header() {
  local listfile="$1"; shift
  local entries=("$@")
  local tmp="$TEMP_DIR/$(basename "$listfile").tmp"
  preserve_header "$listfile" > "$tmp"
  for e in "${entries[@]}"; do
    echo "$e" >> "$tmp"
  done
  mv "$tmp" "$listfile"
}

# Helper: send a command to the server screen session for a given port
send_command_to_screen() {
  local port="$1"; shift
  local cmd="$*"
  local session="blockheads_server_${port}"
  # Respect general cooldown before sending any command
  sleep "$GENERAL_COOLDOWN"
  # Use screen stuff to send command and newline
  screen -S "$session" -p 0 -X stuff "$cmd\r" || err "Failed to send to screen $session: $cmd"
}

# Map world_id to port by scanning world logs for the line that reports port and id
# We'll attempt to read the console.log header for the mapping
get_port_for_world() {
  local world_dir="$1"
  local logfile="$world_dir/console.log"
  if [ ! -f "$logfile" ]; then
    echo ""; return
  fi
  # look for the most recent 'Loading world named' line
  local line
  line=$(grep -E "Loading world named .* on port [0-9]+ with id:" -a "$logfile" | tail -n1 || true)
  if [ -z "$line" ]; then
    # alternative: look for 'port' mention elsewhere
    line=$(grep -E "port [0-9]+.*id:" -a "$logfile" | tail -n1 || true)
  fi
  if [ -z "$line" ]; then echo ""; return; fi
  # extract port
  if [[ "$line" =~ port[[:space:]]([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Parse a players.log line into variables
# Format expected:
# NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED
parse_player_line() {
  local line="$1"
  IFS='|' read -r name ip pass rank whitelisted blacklisted <<< "${line}"
  # trim
  name=$(echo "$name" | sed 's/^ *//;s/ *$//')
  ip=$(echo "$ip" | sed 's/^ *//;s/ *$//')
  pass=$(echo "$pass" | sed 's/^ *//;s/ *$//')
  rank=$(echo "$rank" | sed 's/^ *//;s/ *$//' | tr '[:lower:]' '[:upper:]')
  whitelisted=$(echo "$whitelisted" | sed 's/^ *//;s/ *$//' | tr '[:lower:]' '[:upper:]')
  blacklisted=$(echo "$blacklisted" | sed 's/^ *//;s/ *$//' | tr '[:lower:]' '[:upper:]')
  echo "$name|$ip|$pass|$rank|$whitelisted|$blacklisted"
}

# Load players.log into associative array keyed by name
declare -A PLAYERS_RAW          # raw full line
declare -A PLAYERS_IP
declare -A PLAYERS_PASS
declare -A PLAYERS_RANK
declare -A PLAYERS_WHITELIST
declare -A PLAYERS_BLACKLIST

load_players_log() {
  local players_log="$1"
  # reset
  PLAYERS_RAW=()
  PLAYERS_IP=()
  PLAYERS_PASS=()
  PLAYERS_RANK=()
  PLAYERS_WHITELIST=()
  PLAYERS_BLACKLIST=()

  [ -f "$players_log" ] || return
  while IFS= read -r line || [ -n "$line" ]; do
    # ignore empty lines
    [ -z "$line" ] && continue
    parsed=$(parse_player_line "$line")
    IFS='|' read -r name ip pass rank whitelist black <<< "$parsed"
    # default values handling
    name=${name:-UNKNOWN}
    ip=${ip:-UNKNOWN}
    pass=${pass:-NONE}
    rank=${rank:-NONE}
    whitelist=${whitelist:-NO}
    black=${black:-NO}

    PLAYERS_RAW["$name"]="$line"
    PLAYERS_IP["$name"]="$ip"
    PLAYERS_PASS["$name"]="$pass"
    PLAYERS_RANK["$name"]="$rank"
    PLAYERS_WHITELIST["$name"]="$whitelist"
    PLAYERS_BLACKLIST["$name"]="$black"
  done < "$players_log"
}

# Function: ensure players.log exists for each world; create default file if missing
ensure_players_log_for_world() {
  local world_dir="$1"
  local players_file="$world_dir/players.log"
  if [ ! -f "$players_file" ]; then
    log "Creating players.log in $world_dir"
    # Create empty file
    echo "# players.log - autogenerated" > "$players_file"
    # no players yet
  fi
}

# Track connected players per world and their IPs and UUIDs
declare -A CONNECTED_PLAYERS  # key: world_dir:name -> ip

# Start tailing console.log for a world to detect events and commands
start_console_monitor() {
  local world_dir="$1"
  local logfile="$world_dir/console.log"
  [ -f "$logfile" ] || { log "Waiting for console.log at $logfile"; return; }
  log "Starting console monitor for $world_dir"
  # Use tail -n0 -F to follow new lines
  tail -n0 -F "$logfile" 2>/dev/null | while IFS= read -r line; do
    # parse connection lines like: 'WORLDNAME - Player Connected NAME | 1.2.3.4 | uuid'
    if echo "$line" | grep -q "Player Connected"; then
      # extract name and ip
      if [[ "$line" =~ Player[[:space:]]Connected[[:space:]]([^|]+)\|[[:space:]]*([0-9]{1,3}(\.[0-9]{1,3}){3}) ]]; then
        local pname=$(echo "${BASH_REMATCH[1]}" | sed 's/ *$//;s/^ *//')
        local pip="${BASH_REMATCH[2]}"
        CONNECTED_PLAYERS["$world_dir:$pname"]="$pip"
        log "Player connected: $pname in $world_dir with IP $pip"
        handle_player_join "$world_dir" "$pname" "$pip"
      fi
      continue
    fi

    # parse client disconnected
    if echo "$line" | grep -q "Client disconnected"; then
      # may contain uuid instead of name; but often later Disconnected messages show name
      if echo "$line" | grep -q "Player Disconnected"; then
        # format: SERVER - Player Disconnected NAME
        if [[ "$line" =~ Player[[:space:]]Disconnected[[:space:]](.+)$ ]]; then
          local pname=$(echo "${BASH_REMATCH[1]}" | sed 's/ *$//;s/^ *//')
          unset CONNECTED_PLAYERS["$world_dir:$pname"]
          log "Player disconnected: $pname from $world_dir"
        fi
      else
        # attempt to match uuid-based disconnects; skip
        :
      fi
      continue
    fi

    # parse chat messages: pattern 'NAME: message'
    if [[ "$line" =~ ^[0-9-:.,[:space:]]+\ ([^:]+):[[:space:]](.+)$ ]] || [[ "$line" =~ ^([^:]+):[[:space:]](.+)$ ]]; then
      # two patterns because logs may include timestamp prefix
      local pname
      local msg
      if [[ "$line" =~ ^[0-9-:.,[:space:]]+\ ([^:]+):[[:space:]](.+)$ ]]; then
        pname="${BASH_REMATCH[1]}"
        msg="${BASH_REMATCH[2]}"
      else
        pname="${BASH_REMATCH[1]}"
        msg="${BASH_REMATCH[2]}"
      fi
      # Trim
      pname=$(echo "$pname" | sed 's/^ *//;s/ *$//')
      msg=$(echo "$msg" | sed 's/^ *//;s/ *$//')

      # Check for commands
      case "$msg" in
        !password\ *)
          handle_cmd_password "$world_dir" "$pname" "$msg"
          ;;
        !ip_change\ *)
          handle_cmd_ip_change "$world_dir" "$pname" "$msg"
          ;;
        !change_psw\ *)
          handle_cmd_change_psw "$world_dir" "$pname" "$msg"
          ;;
      esac
    fi
  done &
}

# Handle when a player joins: enforce password prompt and IP verification
handle_player_join() {
  local world_dir="$1"; local pname="$2"; local pip="$3"
  local players_file="$world_dir/players.log"
  load_players_log "$players_file"
  # find by exact name, or UNKNOWN entries
  local saved_ip="${PLAYERS_IP[$pname]:-}" || true
  local saved_pass="${PLAYERS_PASS[$pname]:-NONE}"
  local saved_rank="${PLAYERS_RANK[$pname]:-NONE}"

  # Save connection mapping already done

  # IP verification: if saved_ip is UNKNOWN or differs
  if [ -z "$saved_ip" ] || [ "$saved_ip" = "UNKNOWN" ] || [ "$saved_ip" != "$pip" ]; then
    # notify player to verify new IP within 30 seconds
    log "IP mismatch for $pname: saved '$saved_ip' current '$pip' - starting ip verification"
    send_command_to_screen "$(get_port_for_world "$world_dir")" "tell $pname You have 30 seconds to verify your new IP using: !ip_change YOUR_PASSWORD"

    # start 30s timer
    (sleep 30
      # reload players file, if ip was updated by script by !ip_change this pending entry should be updated
      load_players_log "$players_file"
      local new_ip="${PLAYERS_IP[$pname]:-}"
      if [ "$new_ip" != "$pip" ]; then
        # Kick and ban ip
        local port=$(get_port_for_world "$world_dir")
        log "IP verification failed for $pname - kicking and temporarily banning IP $pip"
        send_command_to_screen "$port" "/kick $pname"
        sleep 0.2
        send_command_to_screen "$port" "/ban $pip"
        # schedule unban after 30s
        (sleep 30; send_command_to_screen "$port" "/unban $pip") &
      fi
    ) &
  fi

  # Password enforcement: if rank NONE and password NONE
  if [ "${PLAYERS_RANK[$pname]:-NONE}" = "NONE" ] && [ "${PLAYERS_PASS[$pname]:-NONE}" = "NONE" -o "${PLAYERS_PASS[$pname]:-NONE}" = "" ]; then
    local port=$(get_port_for_world "$world_dir")
    send_command_to_screen "$port" "tell $pname You must create a password with: !password PASSWORD CONFIRM_PASSWORD within 60 seconds or you will be kicked"
    # start 60s timer
    (sleep 60
      load_players_log "$players_file"
      local passnow="${PLAYERS_PASS[$pname]:-NONE}"
      if [ "$passnow" = "NONE" ] || [ -z "$passnow" ]; then
        log "Player $pname did not create password in time - kicking"
        send_command_to_screen "$port" "/kick $pname"
      fi
    ) &
  fi
}

# Command handlers
handle_cmd_password() {
  local world_dir="$1"; local pname="$2"; local msg="$3"
  # parse arguments
  # msg looks like: !password PASS CONF
  local args
  args=$(echo "$msg" | sed 's/^!password[[:space:]]*//')
  local pass1=$(echo "$args" | awk '{print $1}')
  local pass2=$(echo "$args" | awk '{print $2}')

  local players_file="$world_dir/players.log"
  local port=$(get_port_for_world "$world_dir")

  # clear chat immediately
  send_command_to_screen "$port" "/clear"
  sleep "$SHORT_COOLDOWN"

  if [ -z "$pass1" ] || [ -z "$pass2" ]; then
    sleep "$GENERAL_COOLDOWN"
    send_command_to_screen "$port" "tell $pname Password and confirmation required"
    return
  fi
  if [ ${#pass1} -lt 7 ] || [ ${#pass1} -gt 16 ]; then
    sleep "$GENERAL_COOLDOWN"
    send_command_to_screen "$port" "tell $pname Password must be 7-16 characters"
    return
  fi
  if [ "$pass1" != "$pass2" ]; then
    sleep "$GENERAL_COOLDOWN"
    send_command_to_screen "$port" "tell $pname Passwords do not match"
    return
  fi

  # Update players.log: either update existing user line or add new line
  # Ensure we only modify players.log (authoritative)
  if [ ! -f "$players_file" ]; then echo "# players.log" > "$players_file"; fi
  # If user exists, replace password field
  if grep -q -F "$pname" "$players_file"; then
    # replace the password field (3rd field)
    awk -F'|' -v name="$pname" -v newpass="$pass1" 'BEGIN{OFS=" | "}{gsub(/^ *| *$/,"",$1); if($1==name){$3=newpass} print}' "$players_file" > "$players_file.tmp" && mv "$players_file.tmp" "$players_file"
  else
    # add line with defaults
    echo "$pname | UNKNOWN | $pass1 | NONE | NO | NO" >> "$players_file"
  fi

  # confirmation
  sleep "$GENERAL_COOLDOWN"
  send_command_to_screen "$port" "tell $pname Password set successfully"
}

handle_cmd_ip_change() {
  local world_dir="$1"; local pname="$2"; local msg="$3"
  # msg: !ip_change PASSWORD
  local args=$(echo "$msg" | sed 's/^!ip_change[[:space:]]*//')
  local provided_pass=$(echo "$args" | awk '{print $1}')
  local players_file="$world_dir/players.log"
  local port=$(get_port_for_world "$world_dir")

  # clear chat
  send_command_to_screen "$port" "/clear"
  sleep "$SHORT_COOLDOWN"

  load_players_log "$players_file"
  local saved_pass="${PLAYERS_PASS[$pname]:-NONE}"
  if [ -z "$saved_pass" ] || [ "$saved_pass" = "NONE" ]; then
    sleep "$GENERAL_COOLDOWN"
    send_command_to_screen "$port" "tell $pname No password set in records"
    return
  fi
  if [ "$provided_pass" != "$saved_pass" ]; then
    sleep "$GENERAL_COOLDOWN"
    send_command_to_screen "$port" "tell $pname Incorrect password for IP change"
    return
  fi

  # Update IP in players.log to current connected IP
  local cur_ip="${CONNECTED_PLAYERS["$world_dir:$pname"]:-UNKNOWN}"
  # Replace player's IP field (second) in players.log
  awk -F'|' -v name="$pname" -v nip="$cur_ip" 'BEGIN{OFS=" | "}{gsub(/^ *| *$/,"",$1); if($1==name){$2=nip} print}' "$players_file" > "$players_file.tmp" && mv "$players_file.tmp" "$players_file"

  sleep "$GENERAL_COOLDOWN"
  send_command_to_screen "$port" "tell $pname IP changed and verified"
}

handle_cmd_change_psw() {
  local world_dir="$1"; local pname="$2"; local msg="$3"
  # msg: !change_psw OLDPSW NEWPSW
  local args=$(echo "$msg" | sed 's/^!change_psw[[:space:]]*//')
  local oldpw=$(echo "$args" | awk '{print $1}')
  local newpw=$(echo "$args" | awk '{print $2}')
  local players_file="$world_dir/players.log"
  local port=$(get_port_for_world "$world_dir")

  # clear chat
  send_command_to_screen "$port" "/clear"
  sleep "$SHORT_COOLDOWN"

  load_players_log "$players_file"
  local saved_pass="${PLAYERS_PASS[$pname]:-NONE}"
  if [ "$oldpw" != "$saved_pass" ]; then
    sleep "$GENERAL_COOLDOWN"
    send_command_to_screen "$port" "tell $pname Old password incorrect"
    return
  fi
  if [ ${#newpw} -lt 7 ] || [ ${#newpw} -gt 16 ]; then
    sleep "$GENERAL_COOLDOWN"
    send_command_to_screen "$port" "tell $pname New password must be 7-16 characters"
    return
  fi

  # update players.log
  awk -F'|' -v name="$pname" -v npw="$newpw" 'BEGIN{OFS=" | "}{gsub(/^ *| *$/,"",$1); if($1==name){$3=npw} print}' "$players_file" > "$players_file.tmp" && mv "$players_file.tmp" "$players_file"

  sleep "$GENERAL_COOLDOWN"
  send_command_to_screen "$port" "tell $pname Password changed successfully"
}

# Monitor players.log for changes and apply rules
monitor_players_log_loop() {
  # For each world dir under saves, ensure players.log exists and start monitor
  while true; do
    # discover worlds
    for world_dir in "$SAVES_DIR"/*/; do
      [ -d "$world_dir" ] || continue
      # remove trailing slash
      world_dir=${world_dir%/}
      ensure_players_log_for_world "$world_dir"
      # start console monitor if not already
      if ! pgrep -f "tail -F $world_dir/console.log" >/dev/null 2>&1; then
        start_console_monitor "$world_dir" || true
      fi
      # watch players.log modtime
      local players_file="$world_dir/players.log"
      # initialize last mod time file
      local keyname=$(echo "$world_dir" | md5sum | awk '{print $1}')
      local statefile="$TEMP_DIR/players_state_$keyname"
      local last_mtime=0
      if [ -f "$statefile" ]; then last_mtime=$(cat "$statefile"); fi
      if [ -f "$players_file" ]; then
        local mtime=$(stat -c %Y "$players_file" 2>/dev/null || echo 0)
        if [ "$mtime" -ne "$last_mtime" ]; then
          log "Detected change in $players_file"
          echo "$mtime" > "$statefile"
          handle_players_log_change "$world_dir" "$players_file"
        fi
      fi
    done
    sleep "$POLL_INTERVAL"
  done
}

# Handle players.log change rules
handle_players_log_change() {
  local world_dir="$1"; local players_file="$2"
  # load previous state if any
  local keyname=$(echo "$world_dir" | md5sum | awk '{print $1}')
  local prevdump="$TEMP_DIR/players_prev_$keyname"
  local curdump="$TEMP_DIR/players_cur_$keyname"
  [ -f "$prevdump" ] || touch "$prevdump"
  cp "$players_file" "$curdump"

  # Build arrays for old and new
  declare -A OLD_RANK
  declare -A NEW_RANK
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    IFS='|' read -r oname oip opass orank owhite oblack <<< "$(parse_player_line "$line")"
    oname=$(echo "$oname" | sed 's/^ *//;s/ *$//')
    OLD_RANK["$oname"]="$orank"
  done < "$prevdump"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    IFS='|' read -r nname nip npass nrank nwhite nblack <<< "$(parse_player_line "$line")"
    nname=$(echo "$nname" | sed 's/^ *//;s/ *$//')
    NEW_RANK["$nname"]="$nrank"
  done < "$curdump"

  # Compare and act
  for name in "${!NEW_RANK[@]}"; do
    oldr="${OLD_RANK[$name]:-NONE}"
    newr="${NEW_RANK[$name]:-NONE}"
    # handle rank promotions
    if [ "$oldr" != "$newr" ]; then
      local port=$(get_port_for_world "$world_dir")
      if [ "$oldr" = "NONE" ] && [ "$newr" = "ADMIN" ]; then
        send_command_to_screen "$port" "/admin $name"
      elif [ "$oldr" = "NONE" ] && [ "$newr" = "MOD" ]; then
        send_command_to_screen "$port" "/mod $name"
      elif [ "$newr" = "SUPER" ]; then
        # add to cloud list
        if [ ! -f "$GLOBAL_CLOUD_LIST" ]; then
          echo "# cloudWideOwnedAdminlist - autogenerated" > "$GLOBAL_CLOUD_LIST"
        fi
        # preserve header then add if not exists
        if ! grep -q -F "$name" "$GLOBAL_CLOUD_LIST"; then
          # create temp preserving first two lines
          tmp="$TEMP_DIR/cloud.tmp"
          preserve_header "$GLOBAL_CLOUD_LIST" > "$tmp"
          grep -v -F "$(sed 's/[]\/.*^$[]/\\&/g' "$name")" "$GLOBAL_CLOUD_LIST" | tail -n +3 >> "$tmp" || true
          echo "$name" >> "$tmp"
          mv "$tmp" "$GLOBAL_CLOUD_LIST"
        fi
      fi

      # handle demotions
      if [ "$oldr" = "ADMIN" ] && [ "$newr" = "NONE" ]; then
        send_command_to_screen "$port" "/unadmin $name"
      elif [ "$oldr" = "MOD" ] && [ "$newr" = "NONE" ]; then
        send_command_to_screen "$port" "/unmod $name"
      elif [ "$oldr" = "SUPER" ] && [ "$newr" = "NONE" ]; then
        # remove from cloud list
        if [ -f "$GLOBAL_CLOUD_LIST" ]; then
          tmp="$TEMP_DIR/cloud_rm.tmp"
          preserve_header "$GLOBAL_CLOUD_LIST" > "$tmp"
          # remove occurrences after header
          tail -n +3 "$GLOBAL_CLOUD_LIST" | grep -v -F "$name" >> "$tmp" || true
          mv "$tmp" "$GLOBAL_CLOUD_LIST"
        fi
      fi
    fi
  done

  # Blacklist changes: read old and new blacklisted fields
  # Build dictionaries for blacklisted
  declare -A OLD_BLACK
  declare -A NEW_BLACK
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    IFS='|' read -r oname oip opass orank owhite oblack <<< "$(parse_player_line "$line")"
    oname=$(echo "$oname" | sed 's/^ *//;s/ *$//')
    OLD_BLACK["$oname"]="$oblack"
  done < "$prevdump"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    IFS='|' read -r nname nip npass nrank nwhite nblack <<< "$(parse_player_line "$line")"
    nname=$(echo "$nname" | sed 's/^ *//;s/ *$//')
    NEW_BLACK["$nname"]="$nblack"
  done < "$curdump"

  for name in "${!NEW_BLACK[@]}"; do
    oldb="${OLD_BLACK[$name]:-NO}"
    newb="${NEW_BLACK[$name]:-NO}"
    if [ "$oldb" != "$newb" ]; then
      if [ "$newb" = "YES" ]; then
        # perform unmod, unadmin, ban name, ban ip
        local port=$(get_port_for_world "$world_dir")
        # if they were SUPER, do /stop if connected
        local oldrank="${OLD_RANK[$name]:-NONE}"
        if [ "$oldrank" = "SUPER" ]; then
          # if connected, issue /stop
          if [ -n "${CONNECTED_PLAYERS["$world_dir:$name"]:-}" ]; then
            send_command_to_screen "$port" "/stop"
            sleep 0.5
          fi
        fi
        send_command_to_screen "$port" "/unmod $name"
        sleep 0.2
        send_command_to_screen "$port" "/unadmin $name"
        sleep 0.2
        send_command_to_screen "$port" "/ban $name"

        # find ip in current players file
        ipline=$(grep -F "$name" "$curdump" || true)
        if [ -n "$ipline" ]; then
          IFS='|' read -r _ ip _ <<< "$(parse_player_line "$ipline")"
          ip=$(echo "$ip" | sed 's/^ *//;s/ *$//')
          if [ -n "$ip" ] && [ "$ip" != "UNKNOWN" ]; then
            sleep 0.2
            send_command_to_screen "$port" "/ban $ip"
            # schedule unban after 30s
            (sleep 30; send_command_to_screen "$port" "/unban $ip") &
          fi
        fi

        # remove SUPER from cloud list if present
        if [ -f "$GLOBAL_CLOUD_LIST" ]; then
          tmp="$TEMP_DIR/cloud_rm2.tmp"
          preserve_header "$GLOBAL_CLOUD_LIST" > "$tmp"
          tail -n +3 "$GLOBAL_CLOUD_LIST" | grep -v -F "$name" >> "$tmp" || true
          mv "$tmp" "$GLOBAL_CLOUD_LIST"
        fi
      fi
    fi
  done

  # After applying global rules, persist current file as prev
  cp "$curdump" "$prevdump"

  # Sync adminlist.txt and modlist.txt for connected and IP-verified players
  sync_server_lists_from_players "$world_dir" "$curdump"
}

# Sync adminlist and modlist from players.log but only include players who are connected and have verified IP
sync_server_lists_from_players() {
  local world_dir="$1"; local curdump="$2"
  local adminfile="$world_dir/adminlist.txt"
  local modfile="$world_dir/modlist.txt"
  # gather names
  declare -a admins
  declare -a mods

  # load current players from curdump
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    IFS='|' read -r pname pip ppass prank pwhite pblack <<< "$(parse_player_line "$line")"
    pname=$(echo "$pname" | sed 's/^ *//;s/ *$//')
    pip=$(echo "$pip" | sed 's/^ *//;s/ *$//')
    prank=$(echo "$prank" | tr '[:lower:]' '[:upper:]')
    # only include players with verified IP (not UNKNOWN) and currently connected
    if [ "$pip" != "UNKNOWN" ] && [ -n "${CONNECTED_PLAYERS["$world_dir:$pname"]:-}" ]; then
      if [ "$prank" = "ADMIN" ]; then admins+=("$pname"); fi
      if [ "$prank" = "MOD" ]; then mods+=("$pname"); fi
    fi
  done < "$curdump"

  # write files while preserving header lines
  write_list_preserve_header "$adminfile" "${admins[@]}"
  write_list_preserve_header "$modfile" "${mods[@]}"
}

# Main
log "Starting rank_patcher"
# Ensure saves dir exists
mkdir -p "$SAVES_DIR"

# Start monitor loop
monitor_players_log_loop

# cleanup trap
trap 'rm -rf "$TEMP_DIR"; exit 0' EXIT
