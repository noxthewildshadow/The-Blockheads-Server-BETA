#!/usr/bin/env bash
# rank_patcher.sh
# Implementa la lógica descrita en INSTRUCCIONES.txt:
# - Mantiene players.log por mundo en $HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/<world_id>/players.log
# - Monitorea cambios cada 0.25s
# - Sincroniza adminlist.txt y modlist.txt para jugadores conectados con IP verificada
# - Maneja comandos sensibles (!password, !ip_change, !change_psw), /clear y cooldowns
# - Gestiona cloudWideOwnedAdminlist.txt para SUPER
# - Ejecuta comandos en la consola del servidor (vía screen)
#
# Requerimientos: bash >=4 (para arrays asociativos), inotify-tools (opcional),
# screen, lsof, md5sum, coreutils. Asume que el script se ejecuta desde la carpeta
# donde están server_manager.sh y los archivos world_id_*.txt (tal como el installer).
#
# Basado en las reglas exactas del archivo de instrucciones del usuario. (Referencia incluida).
# :contentReference[oaicite:1]{index=1}

set -u
shopt -s extglob

# ---------- CONFIG ----------
BASE_SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CLOUD_ADMIN_FILE="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
COOLDOWN=0.5              # 0.5 seconds before sending any confirmation/error message
PLAYERS_POLL_INTERVAL=0.25 # poll players.log every 0.25 seconds
KICK_IF_NO_PSW_TIMEOUT=60  # 1 minute to create password if required
IP_CHANGE_WINDOW=30       # 30 seconds to verify IP
# Pattern for server screen sessions: blockheads_server_<port>
WORLD_ID_FILE_PREFIX="world_id_"
# Command to send line into screen session (send Enter)
screen_send() { local session="$1"; local cmd="$2"; screen -S "$session" -X stuff "$cmd$(printf '\r')"; }

# ---------- UTIL ----------
log() { echo "[`date '+%F %T'`] $*"; }
err() { echo >&2 "[ERROR] $*"; }

# Ensure saves directory exists
mkdir -p "$BASE_SAVES_DIR"

# Create cloud admin file if not exists (managed only by this script)
mkdir -p "$(dirname "$CLOUD_ADMIN_FILE")"
[ -f "$CLOUD_ADMIN_FILE" ] || >"$CLOUD_ADMIN_FILE"

# Map: world_id -> players.log path
declare -A PLAYERS_FILE_FOR_WORLD
# In-memory snapshot of players.log contents: associative array of player -> rawline
# format used internally: "NAME|IP|PSW|RANK|WHITELISTED|BLACKLISTED"
declare -A SNAPSHOT

# Track pending timers and actions per player
declare -A PENDING_KICK_TIMER_PID    # when player must create password
declare -A PENDING_IP_TIMER_PID      # when player must confirm IP
declare -A PENDING_IP_EXPECTED       # expected new ip for verification (not strictly required)
declare -A PENDING_IP_PLAYER_WORLD   # world_id for pending ip timers
declare -A CONNECTED_PLAYERS_IP      # player -> current known IP (from logs / connection events)

# Helper: normalize trim whitespace
trim() { local v="$*"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

# Helper: get screen session for a given world_id
# Strategy: look for world_id_<port>.txt files in cwd; if found, read which port maps to this world_id
find_screen_for_world() {
    local world_id="$1"
    # search for matching world_id_* files in current working dir and the script dir
    for f in ./world_id_*.txt world_id_*.txt; do
        [ -f "$f" ] || continue
        if [ "$(cat "$f" 2>/dev/null)" = "$world_id" ]; then
            local port="${f#*world_id_}"
            port="${port%.txt}"
            printf "blockheads_server_%s" "$port"
            return 0
        fi
    done
    # fallback: if only one running blockheads_server_* screen exists, use it (best-effort)
    local sc=$(screen -list 2>/dev/null | grep -oE "blockheads_server_[0-9]+" | head -n1 || true)
    if [ -n "$sc" ]; then
        printf "%s" "$sc"
        return 0
    fi
    # not found
    return 1
}

# Send command to world (via screen session)
send_cmd_to_world() {
    local world_id="$1"; shift
    local cmd="$*"
    local sess
    if ! sess=$(find_screen_for_world "$world_id"); then
        err "No screen session found for world '$world_id' (cannot send: $cmd)"
        return 1
    fi
    log "-> Sending to [$sess] : $cmd"
    screen_send "$sess" "$cmd"
    return 0
}

# Safe /clear then send a message after COOLDOWN
clear_and_announce() {
    local world_id="$1"; local message="$2"
    send_cmd_to_world "$world_id" "/clear"
    sleep "$COOLDOWN"
    # Use /say to broadcast the confirmation (server must support it)
    send_cmd_to_world "$world_id" "/say $message"
}

# read players.log for a world and return array of normalized lines (trimmed)
read_players_file_lines() {
    local file="$1"
    [ -f "$file" ] || { printf ''; return 0; }
    # read lines, ignore completely empty lines
    awk 'NF{print}' "$file"
}

# Parse a players.log line into fields:
# NAME | IP | PSW | RANK | WHITELISTED | BLACKLISTED
# returns fields in global variables
parse_players_line() {
    local line="$1"
    IFS='|' read -r a b c d e f <<< "$line"
    PLAYER_NAME=$(trim "$a")
    PLAYER_IP=$(trim "$b")
    PLAYER_PSW=$(trim "$c")
    PLAYER_RANK=$(trim "$d")
    PLAYER_WHITELISTED=$(trim "$e")
    PLAYER_BLACKLISTED=$(trim "$f")
}

# Update cloud admin list (ensure unique names, one per line)
cloud_admin_add() {
    local name="$1"
    grep -Fxq "$name" "$CLOUD_ADMIN_FILE" 2>/dev/null || echo "$name" >> "$CLOUD_ADMIN_FILE"
}
cloud_admin_remove() {
    local name="$1"
    [ -f "$CLOUD_ADMIN_FILE" ] || return
    grep -Fxv "$name" "$CLOUD_ADMIN_FILE" > "${CLOUD_ADMIN_FILE}.tmp" || true
    mv -f "${CLOUD_ADMIN_FILE}.tmp" "$CLOUD_ADMIN_FILE"
}

# Sync adminlist.txt and modlist.txt for connected players with verified IPs
sync_txt_lists_for_world() {
    local world_id="$1"
    local dir="$BASE_SAVES_DIR/$world_id"
    mkdir -p "$dir"
    local adminfile="$dir/adminlist.txt"
    local modfile="$dir/modlist.txt"
    # Build lists from current SNAPSHOT but include only players with IP != UNKNOWN and that are connected (we check CONNECTED_PLAYERS_IP)
    >"$adminfile"
    >"$modfile"
    for k in "${!SNAPSHOT[@]}"; do
        local line="${SNAPSHOT[$k]}"
        parse_players_line "$line"
        # only include if IP is not UNKNOWN and player is connected and IP matches
        if [ "$PLAYER_IP" != "UNKNOWN" ] && [ -n "${CONNECTED_PLAYERS_IP[$PLAYER_NAME]:-}" ] && [ "${CONNECTED_PLAYERS_IP[$PLAYER_NAME]}" = "$PLAYER_IP" ]; then
            case "$PLAYER_RANK" in
                ADMIN) grep -Fxq "$PLAYER_NAME" "$adminfile" 2>/dev/null || echo "$PLAYER_NAME" >> "$adminfile" ;;
                MOD) grep -Fxq "$PLAYER_NAME" "$modfile" 2>/dev/null || echo "$PLAYER_NAME" >> "$modfile" ;;
            esac
        fi
    done
    # Ensure whitelist.txt and blacklist.txt are not populated by default from players.log (they may be populated only as needed)
    # Note: whitelist/blacklist are managed but the instruction says default server lists remain empty until verified players connect.
}

# Helper: send admin/mod/unadmin/unmod/unban/ban/kick commands
do_rank_command() {
    local world_id="$1"; local cmd="$2"; local target="$3"
    send_cmd_to_world "$world_id" "/$cmd $target"
}

# Handle when a player's record changed (cmp previous -> current)
handle_record_transition() {
    local world_id="$1"; local oldline="$2"; local newline="$3"
    parse_players_line "$oldline"
    local old_name="$PLAYER_NAME" old_ip="$PLAYER_IP" old_psw="$PLAYER_PSW" old_rank="$PLAYER_RANK" old_black="$PLAYER_BLACKLISTED"
    parse_players_line "$newline"
    local name="$PLAYER_NAME" ip="$PLAYER_IP" psw="$PLAYER_PSW" rank="$PLAYER_RANK" black="$PLAYER_BLACKLISTED"
    # RANK transitions
    if [ "$old_rank" != "$rank" ]; then
        # promotions
        if [ "$old_rank" = "NONE" ] && [ "$rank" = "ADMIN" ]; then
            do_rank_command "$world_id" "admin" "$name"
        elif [ "$old_rank" = "NONE" ] && [ "$rank" = "MOD" ]; then
            do_rank_command "$world_id" "mod" "$name"
        elif [ "$rank" = "SUPER" ] && [ "$old_rank" != "SUPER" ]; then
            # add to cloudWideOwnedAdminlist.txt
            cloud_admin_add "$name"
        fi
        # demotions
        if [ "$old_rank" = "ADMIN" ] && [ "$rank" = "NONE" ]; then
            do_rank_command "$world_id" "unadmin" "$name"
        fi
        if [ "$old_rank" = "MOD" ] && [ "$rank" = "NONE" ]; then
            do_rank_command "$world_id" "unmod" "$name"
        fi
        if [ "$old_rank" = "SUPER" ] && [ "$rank" = "NONE" ]; then
            cloud_admin_remove "$name"
        fi
    fi

    # BLACKLIST transitions
    if [ "$old_black" != "$black" ]; then
        if [ "$black" = "YES" ]; then
            # If was SUPER, stop server if connected
            if [ "$old_rank" = "SUPER" ]; then
                send_cmd_to_world "$world_id" "/stop"
                sleep 1
            fi
            # unmod/unadmin/ban name and ban ip
            do_rank_command "$world_id" "unmod" "$name"
            do_rank_command "$world_id" "unadmin" "$name"
            do_rank_command "$world_id" "ban" "$name"
            # ban by IP if available and not UNKNOWN
            if [ "$ip" != "UNKNOWN" ]; then
                do_rank_command "$world_id" "ban" "$ip"
                # schedule unban? The instruction doesn't require automatic unban here except for the IP-change flow
            fi
            cloud_admin_remove "$name"
        elif [ "$old_black" = "YES" ] && [ "$black" != "YES" ]; then
            # removed from blacklist -> maybe unban? no instruction specified, so do nothing automatically
            :
        fi
    fi
}

# Apply full scan comparing snapshot -> current for a world
scan_players_file_and_apply() {
    local world_id="$1"
    local file="${PLAYERS_FILE_FOR_WORLD[$world_id]}"
    local lines
    IFS=$'\n' read -d '' -r -a lines < <(read_players_file_lines "$file" && printf '\0')
    # build map of current
    declare -A current_map=()
    for ln in "${lines[@]}"; do
        # identify player key by NAME (first field)
        parse_players_line "$ln"
        local key="$PLAYER_NAME"
        [ -z "$key" ] && continue
        current_map["$key"]="$ln"
    done
    # compare previous SNAPSHOT entries for this world (we store by world prefix to avoid collisions)
    for key in "${!SNAPSHOT[@]}"; do
        # Only consider keys belonging to this world: we encoded them including world id prefix
        if [[ "$key" == "${world_id}:"* ]]; then
            local pname="${key#${world_id}:}"
            local old_line="${SNAPSHOT[$key]}"
            local new_line="${current_map[$pname]:-}"
            if [ -z "$new_line" ]; then
                # player removed from file -> treat as no change (explicit handling not required by instructions)
                unset 'SNAPSHOT[$key]'
            elif [ "$old_line" != "$new_line" ]; then
                handle_record_transition "$world_id" "$old_line" "$new_line"
                SNAPSHOT["${world_id}:${pname}"]="$new_line"
            fi
        fi
    done
    # check for new players added to file
    for k in "${!current_map[@]}"; do
        local mapkey="${world_id}:${k}"
        if [ -z "${SNAPSHOT[$mapkey]:-}" ]; then
            # new entry added manually
            SNAPSHOT[$mapkey]="${current_map[$k]}"
            # No specific 'on add' actions except syncing lists; but if rank is SUPER add to cloud list
            parse_players_line "${current_map[$k]}"
            if [ "$PLAYER_RANK" = "SUPER" ]; then
                cloud_admin_add "$PLAYER_NAME"
            fi
        fi
    done

    # After handling transitions, rebuild per-world SNAPSHOT-only listing used for sync
    # For syncing we need a flat SNAPSHOT per world (without world prefix)
    # Build temporary mapping for sync function
    declare -A tmp_map=()
    for k in "${!SNAPSHOT[@]}"; do
        if [[ "$k" == "${world_id}:"* ]]; then
            local pname="${k#${world_id}:}"
            tmp_map["$pname"]="${SNAPSHOT[$k]}"
        fi
    done
    # Replace SNAPSHOT entries for world with tmp_map entries (encapsulated in SNAPSHOT_WORLD_* variables)
    # We'll rely on existing SNAPSHOT but the sync function expects SNAPSHOT to have entries without world prefix.
    # For simplicity for sync, temporarily export the values into SNAPSHOT_FOR_SYNC array variable
    declare -gA SNAPSHOT_FOR_SYNC
    for k in "${!tmp_map[@]}"; do
        SNAPSHOT_FOR_SYNC[$k]="${tmp_map[$k]}"
    done
    # Also update the global CONNECTED_PLAYERS_IP map by scanning console.log connection events (done elsewhere)
    # Finally sync the admin/mod txts
    sync_txt_lists_for_world "$world_id"
}

# ---------- Monitor server console logs for chat messages and connect/disconnect events ----------
# We will tail console.log files for ALL worlds found under $BASE_SAVES_DIR and handle in-game commands:
# - !password P1 P2
# - !change_psw OLD NEW
# - !ip_change PSW
# and also handle connection log lines to record CONNECTED_PLAYERS_IP mapping for verification.

# Launch a monitor that tails all console.log files (one per running world directory)
start_console_tail_monitors() {
    # find all console.log files under saves
    local logs=()
    while IFS= read -r -d $'\0' f; do logs+=("$f"); done < <(find "$BASE_SAVES_DIR" -type f -name "console.log" -print0 2>/dev/null)
    if [ "${#logs[@]}" -eq 0 ]; then
        log "No console.log files found to monitor. Will watch for creation."
        return 0
    fi
    # For each log spawn a background tail -F process feeding into a handler
    for logfile in "${logs[@]}"; do
        _monitor_single_console "$logfile" &
    done
}

# Monitor a single console.log file (background function)
_monitor_single_console() {
    local logfile="$1"
    log "Starting monitor for $logfile"
    # Continuously follow file
    tail -n0 -F "$logfile" 2>/dev/null | while IFS= read -r line; do
        # Example connection line from log (as given in INSTRUCCIONES.txt):
        # 2025-09-23 16:20:00.636 blockheads_server171[131869:131869] PLOT_HEAVEN - Player Connected THE_WILD_SHADOW | 187.233.203.236 | uuid
        if echo "$line" | grep -q "Player Connected"; then
            # extract world name and player info
            # get part after ']' to skip timestamp/frame
            local after=$(echo "$line" | sed -E 's/^[^]]*\] //; s/^[^]]* //;')
            # we expect: <WORLD> - Player Connected <NAME> | <IP> | <uuid>
            local world=$(echo "$after" | awk -F' - ' '{print $1}' | tr -d ' ')
            local rest=$(echo "$after" | awk -F' - ' '{print $2}')
            # parse name and ip
            local pname=$(echo "$rest" | sed -E 's/Player Connected //; s/ *\|.*//')
            local ip=$(echo "$rest" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
            # map player->ip
            CONNECTED_PLAYERS_IP["$pname"]="$ip"
            log "Detected connect: [$world] $pname -> $ip"
            # If there is an entry in players.log for this player, check IP mismatch triggers
            local world_dir="$(dirname "$logfile")"
            local world_id="$(basename "$world_dir")"
            # If players file exists, check stored IP
            local pfile="$BASE_SAVES_DIR/$world_id/players.log"
            if [ -f "$pfile" ]; then
                # find player line
                local pline=$(grep -E "^$pname[[:space:]]*\|" "$pfile" || true)
                if [ -n "$pline" ]; then
                    parse_players_line "$pline"
                    if [ "$PLAYER_IP" != "$ip" ]; then
                        # IP differs -> start ip-change workflow
                        log "IP mismatch for $pname (stored: $PLAYER_IP, current: $ip). Asking to verify within $IP_CHANGE_WINDOW seconds."
                        send_cmd_to_world "$world_id" "/say $pname: Your IP doesn't match our records. You have $IP_CHANGE_WINDOW seconds to run: !ip_change <your_password>"
                        # record expected
                        PENDING_IP_EXPECTED["$pname"]="$ip"
                        PENDING_IP_PLAYER_WORLD["$pname"]="$world_id"
                        # spawn timer
                        ( sleep "$IP_CHANGE_WINDOW"
                          # after window, check if resolved
                          if [ -n "${PENDING_IP_EXPECTED[$pname]:-}" ]; then
                              # not resolved
                              log "IP-change timeout for $pname -> kicking & banning IP $ip (temporary ban 30s)."
                              do_rank_command "$world_id" "kick" "$pname"
                              do_rank_command "$world_id" "ban" "$ip"
                              # schedule unban after 30s
                              ( sleep 30
                                do_rank_command "$world_id" "unban" "$ip"
                                log "Auto-unban executed for $ip after 30s (IP-change flow)."
                                ) &
                              unset PENDING_IP_EXPECTED["$pname"]
                              unset PENDING_IP_PLAYER_WORLD["$pname"]
                          fi
                        ) &
                        PENDING_IP_TIMER_PID["$pname"]=$!
                    fi
                fi
            fi
            continue
        fi

        # Player chat messages (format: "PLAYERNAME: message")
        # We'll capture !password, !change_psw and !ip_change and process them
        if echo "$line" | grep -qE '^[[:alnum:]_[:punct:]]+:'; then
            # only consider lines where chat appears (simplified)
            # Extract player and message
            player=$(echo "$line" | awk -F'] ' '{print $2}' | sed -n 's/^\([^:]*\):.*$/\1/p' || true)
            # Fallback: attempt simpler parse (if above fails)
            if [ -z "$player" ]; then
                player=$(echo "$line" | sed -E 's/^.*] //;s/:.*$//')
            fi
            msg=$(echo "$line" | sed -E 's/^.*: //')
            # Trim
            player=$(trim "$player")
            msg=$(trim "$msg")
            # if command !password
            if echo "$msg" | grep -qE '^!password[[:space:]]+'; then
                # parse args
                args=$(echo "$msg" | sed -E 's/^!password[[:space:]]+//')
                p1=$(echo "$args" | awk '{print $1}')
                p2=$(echo "$args" | awk '{print $2}')
                # input validation
                if [ -z "$p1" ] || [ -z "$p2" ]; then
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/clear"
                    sleep "$COOLDOWN"
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/say $player: password command requires two arguments."
                    continue
                fi
                if [ "${#p1}" -lt 7 ] || [ "${#p1}" -gt 16 ]; then
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/clear"
                    sleep "$COOLDOWN"
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/say $player: password length must be 7–16 characters."
                    continue
                fi
                if [ "$p1" != "$p2" ]; then
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/clear"
                    sleep "$COOLDOWN"
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/say $player: passwords do not match."
                    continue
                fi
                # update players.log for this world if player exists, else add entry
                local world_dir="$(dirname "$logfile")"
                local world_id="$(basename "$world_dir")"
                local pfile="$BASE_SAVES_DIR/$world_id/players.log"
                mkdir -p "$BASE_SAVES_DIR/$world_id"
                if grep -qE "^$player[[:space:]]*\|" "$pfile" 2>/dev/null; then
                    # replace password field (3rd field)
                    awk -F'|' -v OFS='|' -v name="$player" -v npw="$p1" '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if($1==name){$3=" "npw" "}; print}' "$pfile" > "${pfile}.tmp" && mv -f "${pfile}.tmp" "$pfile"
                else
                    # create new line with defaults
                    echo "$player | UNKNOWN | $p1 | NONE | NO | NO" >> "$pfile"
                fi
                # clear chat and confirm with cooldown
                send_cmd_to_world "$world_id" "/clear"
                sleep "$COOLDOWN"
                send_cmd_to_world "$world_id" "/say $player: password set successfully."
                # If there was a pending KICK timer because user lacked password, cancel it
                if [ -n "${PENDING_KICK_TIMER_PID[$player]:-}" ]; then
                    kill "${PENDING_KICK_TIMER_PID[$player]}" 2>/dev/null || true
                    unset PENDING_KICK_TIMER_PID["$player"]
                fi
                continue
            fi

            # !change_psw OLD NEW
            if echo "$msg" | grep -qE '^!change_psw[[:space:]]+'; then
                args=$(echo "$msg" | sed -E 's/^!change_psw[[:space:]]+//')
                old=$(echo "$args" | awk '{print $1}')
                new=$(echo "$args" | awk '{print $2}')
                if [ -z "$old" ] || [ -z "$new" ]; then
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/clear"
                    sleep "$COOLDOWN"
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/say $player: !change_psw requires old and new password."
                    continue
                fi
                if [ "${#new}" -lt 7 ] || [ "${#new}" -gt 16 ]; then
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/clear"
                    sleep "$COOLDOWN"
                    send_cmd_to_world "$(basename "$(dirname "$logfile")")" "/say $player: new password length must be 7–16."
                    continue
                fi
                # Update in players.log if old matches
                local world_dir="$(dirname "$logfile")"
                local world_id="$(basename "$world_dir")"
                local pfile="$BASE_SAVES_DIR/$world_id/players.log"
                if grep -qE "^$player[[:space:]]*\|" "$pfile" 2>/dev/null; then
                    curline=$(grep -E "^$player[[:space:]]*\|" "$pfile" | head -n1)
                    parse_players_line "$curline"
                    if [ "$PLAYER_PSW" != "$old" ]; then
                        send_cmd_to_world "$world_id" "/clear"
                        sleep "$COOLDOWN"
                        send_cmd_to_world "$world_id" "/say $player: old password incorrect."
                    else
                        # replace third field with new
                        awk -F'|' -v OFS='|' -v name="$player" -v npw="$new" '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if($1==name){$3=" "npw" "}; print}' "$pfile" > "${pfile}.tmp" && mv -f "${pfile}.tmp" "$pfile"
                        send_cmd_to_world "$world_id" "/clear"
                        sleep "$COOLDOWN"
                        send_cmd_to_world "$world_id" "/say $player: password changed successfully."
                    fi
                else
                    send_cmd_to_world "$world_id" "/clear"
                    sleep "$COOLDOWN"
                    send_cmd_to_world "$world_id" "/say $player: no password found; use !password to create one."
                fi
                continue
            fi

            # !ip_change PSW
            if echo "$msg" | grep -qE '^!ip_change[[:space:]]+'; then
                args=$(echo "$msg" | sed -E 's/^!ip_change[[:space:]]+//')
                given_psw="$args"
                local world_dir="$(dirname "$logfile")"
                local world_id="$(basename "$world_dir")"
                # find players.log entry
                local pfile="$BASE_SAVES_DIR/$world_id/players.log"
                if grep -qE "^$player[[:space:]]*\|" "$pfile" 2>/dev/null; then
                    curline=$(grep -E "^$player[[:space:]]*\|" "$pfile" | head -n1)
                    parse_players_line "$curline"
                    # check password
                    if [ "$PLAYER_PSW" = "$given_psw" ]; then
                        # update stored ip to current connected ip (from CONNECTED_PLAYERS_IP)
                        curip="${CONNECTED_PLAYERS_IP[$player]:-UNKNOWN}"
                        if [ -z "$curip" ] || [ "$curip" = "UNKNOWN" ]; then
                            send_cmd_to_world "$world_id" "/clear"
                            sleep "$COOLDOWN"
                            send_cmd_to_world "$world_id" "/say $player: cannot determine your current IP to update."
                        else
                            # update file third field remains psw, but second field replace with curip
                            awk -F'|' -v OFS='|' -v name="$player" -v nip="$curip" '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if($1==name){$2=" "nip" "}; print}' "$pfile" > "${pfile}.tmp" && mv -f "${pfile}.tmp" "$pfile"
                            # clear chat and confirm after cooldown
                            send_cmd_to_world "$world_id" "/clear"
                            sleep "$COOLDOWN"
                            send_cmd_to_world "$world_id" "/say $player: IP updated successfully."
                            # cancel pending ip timer if present
                            if [ -n "${PENDING_IP_TIMER_PID[$player]:-}" ]; then
                                kill "${PENDING_IP_TIMER_PID[$player]}" 2>/dev/null || true
                                unset PENDING_IP_TIMER_PID["$player"]
                                unset PENDING_IP_EXPECTED["$player"]
                                unset PENDING_IP_PLAYER_WORLD["$player"]
                            fi
                        fi
                    else
                        send_cmd_to_world "$world_id" "/clear"
                        sleep "$COOLDOWN"
                        send_cmd_to_world "$world_id" "/say $player: password incorrect for ip_change."
                    fi
                else
                    send_cmd_to_world "$world_id" "/clear"
                    sleep "$COOLDOWN"
                    send_cmd_to_world "$world_id" "/say $player: no account found. Use !password to create one."
                fi
                continue
            fi
        fi
    done
}

# ---------- Initial discovery of worlds & create players.log if at least one world exists ----------
discover_worlds_and_ensure_playerslog() {
    # For every directory under saves that is a world id, ensure players.log exists
    while IFS= read -r -d $'\0' dir; do
        local world_id
        world_id=$(basename "$dir")
        local pfile="$dir/players.log"
        PLAYERS_FILE_FOR_WORLD["$world_id"]="$pfile"
        mkdir -p "$dir"
        # Create file automatically after detecting at least one world
        if [ ! -f "$pfile" ]; then
            log "Creating players.log for world $world_id at $pfile"
            # Create default empty file (no header). The file is sole source of truth.
            >"$pfile"
        fi
    done < <(find "$BASE_SAVES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

# ---------- Main Loop ----------
main_loop() {
    log "Rank patcher started. Monitoring every $PLAYERS_POLL_INTERVAL s. (Reference: INSTRUCCIONES.txt)."
    discover_worlds_and_ensure_playerslog
    start_console_tail_monitors

    # Build initial snapshot
    for world_id in "${!PLAYERS_FILE_FOR_WORLD[@]}"; do
        file="${PLAYERS_FILE_FOR_WORLD[$world_id]}"
        IFS=$'\n' read -d '' -r -a LINES < <(read_players_file_lines "$file" && printf '\0')
        for ln in "${LINES[@]}"; do
            parse_players_line "$ln"
            SNAPSHOT["${world_id}:${PLAYER_NAME}"]="$ln"
        done
    done

    # Continuous monitoring loop
    while true; do
        # rediscover worlds (in case new worlds created)
        discover_worlds_and_ensure_playerslog

        for world_id in "${!PLAYERS_FILE_FOR_WORLD[@]}"; do
            file="${PLAYERS_FILE_FOR_WORLD[$world_id]}"
            # Ensure file exists
            [ -f "$file" ] || touch "$file"
            # compute simple checksum to detect manual edits (or modified time)
            cur_sum=$(md5sum "$file" 2>/dev/null | awk '{print $1}')
            prev_var="SUM_${world_id}"
            prev_sum="${!prev_var:-}"
            if [ "$cur_sum" != "$prev_sum" ]; then
                # file changed -> full scan and apply transitions
                log "Detected change in players.log for world $world_id"
                # load file contents
                IFS=$'\n' read -d '' -r -a lines < <(read_players_file_lines "$file" && printf '\0')
                # ensure each line matches format with 6 fields, otherwise note and skip invalid lines
                # We'll normalize lines into exact format: NAME | IP | PSW | RANK | WHITELISTED | BLACKLISTED
                tmpfile="${file}.normalized.tmp"
                : > "$tmpfile"
                for l in "${lines[@]}"; do
                    # split and ensure 6 fields
                    IFS='|' read -r f1 f2 f3 f4 f5 f6 <<< "$l"
                    # If missing fields, pad with defaults
                    NAME=$(trim "${f1:-UNKNOWN}")
                    IP=$(trim "${f2:-UNKNOWN}")
                    PSW=$(trim "${f3:-NONE}")
                    RANK=$(trim "${f4:-NONE}")
                    WL=$(trim "${f5:-NO}")
                    BL=$(trim "${f6:-NO}")
                    # sanitize values: enforce uppercase for RANK, YES/NO for lists
                    RANK=$(echo "$RANK" | tr '[:lower:]' '[:upper:]')
                    [ -z "$RANK" ] && RANK="NONE"
                    # enforce allowed ranks
                    case "$RANK" in ADMIN|MOD|SUPER|NONE) ;; *) RANK="NONE" ;; esac
                    WL=$(echo "$WL" | tr '[:lower:]' '[:upper:]'); [ "$WL" != "YES" ] && WL="NO"
                    BL=$(echo "$BL" | tr '[:lower:]' '[:upper:]'); [ "$BL" != "YES" ] && BL="NO"
                    # password placeholder NONE -> if PSW is empty set NONE
                    [ -z "$PSW" ] && PSW="NONE"
                    echo "$NAME | $IP | $PSW | $RANK | $WL | $BL" >> "$tmpfile"
                done
                # atomically replace players.log with normalized version (keeps modifications consistent with instruction that players.log is single source)
                mv -f "$tmpfile" "$file"
                # Update sum
                declare "$prev_var=$cur_sum"
                # Now perform scan and actions
                scan_players_file_and_apply "$world_id"
                # refresh stored sum var from dynamic variable
                eval "SUM_${world_id}='$cur_sum'"
            fi
        done

        sleep "$PLAYERS_POLL_INTERVAL"
    done
}

# ---------- Start ----------
# Ensure script is not run as root (server files are per user)
if [ "$EUID" -eq 0 ]; then
    log "Script is running as root. Prefer running as normal user owning server files."
fi

main_loop
