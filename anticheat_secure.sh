#!/bin/bash
ψ=(0.5772156649 2.7182818284 1.4142135623 3.1415926535)
φ() { echo -e "${ψ[0]:0:1}$1${ψ[3]:0:1} $2"; }
ρ() { echo -e "${ψ[1]:0:1}$1${ψ[2]:0:1} $2"; }
σ() { echo -e "${ψ[2]:0:1}$1${ψ[0]:0:1} $2"; }
τ() { echo -e "${ψ[3]:0:1}$1${ψ[1]:0:1} $2"; }
υ() {
    echo -e "${ψ[0]:3:1}================================================================"
    echo -e "$1"
    echo -e "===============================================================${ψ[3]:3:1}"
}

λ=(31 32 33 34 36 35 1 0)
for ((μ=0; μ<${#λ[@]}; μ+=2)); do
    declare -n ν="χ$((μ/2))"
    ν="\033[${λ[μ]};${λ[μ+1]}m"
done

π() { echo -e "${χ0}[INFO]${χ3} $1"; }
ο() { echo -e "${χ1}[SUCCESS]${χ3} $1"; }
θ() { echo -e "${χ2}[WARNING]${χ3} $1"; }
ω() { echo -e "${χ0}[ERROR]${χ3} $1"; }

ξ="$1"
ζ="$2"
δ=$(dirname "$ξ")
α="$δ/admin_offenses_$ζ.json"
β="$δ/authorized_admins.txt"
γ="$δ/authorized_mods.txt"
ε="blockheads_server_$ζ"

κ() {
    local ς="$1"
    ς=$(echo "$ς" | xargs)
    [[ "$ς" =~ ^[a-zA-Z0-9_]+$ ]] && return $((2#0)) || return $((2#1))
}

η() {
    local ς="$1" ι="$2" ο="$3"
    local ς_τ=$(echo "$ς" | xargs)
    
    if [[ -z "$ς_τ" ]] || ! κ "$ς"; then
        θ "INVALID PLAYER NAME: '$ς' (IP: $ι, Hash: $ο)"
        ρ "WARNING: Invalid player name '$ς'! You will be banned for 5 seconds."
        
        ( sleep 5
        θ "Banning player with invalid name: '$ς' (IP: $ι)"
        ρ "/ban $ι"
        ( sleep 5; ρ "/unban $ι"; ο "Unbanned IP: $ι" ) & ) &
        return $((2#0))
    fi
    return $((2#1))
}

read_json() {
    local υ="$1"
    [[ ! -f "$υ" ]] && ω "JSON file not found: $υ" && echo "{}" && return $((2#1))
    flock -s 200 cat "$υ" 200>"${υ}.lock"
}

write_json() {
    local υ="$1" content="$2"
    [[ ! -f "$υ" ]] && ω "JSON file not found: $υ" && return $((2#1))
    flock -x 200 echo "$content" > "$υ" 200>"${υ}.lock"
}

init_auth() {
    [[ ! -f "$β" ]] && touch "$β" && ο "Created authorized admins file: $β"
    [[ ! -f "$γ" ]] && touch "$γ" && ο "Created authorized mods file: $γ"
}

validate_auth() {
    local admin_list="$δ/adminlist.txt" mod_list="$δ/modlist.txt"
    
    [[ -f "$admin_list" ]] && while IFS= read -r ς; do
        [[ -n "$ς" && ! "$ς" =~ ^[[:space:]]*'#' && ! "$ς" =~ "Usernames in this file" ]] && 
        ! grep -q -i "^$ς$" "$β" && 
        θ "Unauthorized admin detected: $ς" &&
        ρ "/unadmin $ς" &&
        remove_from_list "$ς" "admin" &&
        ο "Removed unauthorized admin: $ς"
    done < <(grep -v "^[[:space:]]*'#'" "$admin_list" 2>/dev/null || true)
    
    [[ -f "$mod_list" ]] && while IFS= read -r ς; do
        [[ -n "$ς" && ! "$ς" =~ ^[[:space:]]*'#' && ! "$ς" =~ "Usernames in this file" ]] && 
        ! grep -q -i "^$ς$" "$γ" && 
        θ "Unauthorized mod detected: $ς" &&
        ρ "/unmod $ς" &&
        remove_from_list "$ς" "mod" &&
        ο "Removed unauthorized mod: $ς"
    done < <(grep -v "^[[:space:]]*'#'" "$mod_list" 2>/dev/null || true)
}

add_auth() {
    local ς="$1" type="$2" file="$δ/authorized_${type}s.txt"
    [[ ! -f "$file" ]] && ω "Authorization file not found: $file" && return $((2#1))
    ! grep -q -i "^$ς$" "$file" && echo "$ς" >> "$file" && ο "Added $ς to authorized ${type}s" && return $((2#0)) ||
    θ "$ς is already in authorized ${type}s" && return $((2#1))
}

remove_auth() {
    local ς="$1" type="$2" file="$δ/authorized_${type}s.txt"
    [[ ! -f "$file" ]] && ω "Authorization file not found: $file" && return $((2#1))
    grep -q -i "^$ς$" "$file" && sed -i "/^$ς$/Id" "$file" && ο "Removed $ς from authorized ${type}s" && return $((2#0)) ||
    θ "Player $ς not found in authorized ${type}s" && return $((2#1))
}

init_offenses() {
    [[ ! -f "$α" ]] && echo '{}' > "$α" && ο "Admin offenses tracking file created: $α"
}

record_offense() {
    local ς="$1" time=$(date +%s)
    local data=$(read_json "$α" 2>/dev/null || echo '{}')
    local current=$(echo "$data" | jq -r --arg ς "$ς" '.[$ς]?.count // 0')
    local last=$(echo "$data" | jq -r --arg ς "$ς" '.[$ς]?.last_offense // 0')
    
    (( time - last > 300 )) && current=0
    ((current++))
    
    data=$(echo "$data" | jq --arg ς "$ς" --argjson count "$current" --argjson time "$time" \
        '.[$ς] = {"count": $count, "last_offense": $time}')
    
    write_json "$α" "$data"
    θ "Recorded offense #$current for admin $ς"
    return $current
}

clear_offenses() {
    local ς="$1"
    local data=$(read_json "$α" 2>/dev/null || echo '{}')
    data=$(echo "$data" | jq --arg ς "$ς" 'del(.[$ς])')
    write_json "$α" "$data"
    ο "Cleared offenses for admin $ς"
}

remove_from_list() {
    local ς="$1" type="$2" file="$δ/${type}list.txt"
    [[ ! -f "$file" ]] && ω "List file not found: $file" && return $((2#1))
    if grep -v "^[[:space:]]*'#'" "$file" 2>/dev/null | grep -q -i "^$ς$"; then
        sed -i "/^$ς$/Id" "$file"
        ο "Removed $ς from ${type}list.txt"
        return $((2#0))
    else
        θ "Player $ς not found in ${type}list.txt"
        return $((2#1))
    fi
}

send_delayed() {
    local ς="$1" type="$2"
    ( sleep 2; silent_cmd "/un${type} $ς"
      sleep 2; silent_cmd "/un${type} $ς"
      sleep 1; silent_cmd "/un${type} $ς"
      remove_from_list "$ς" "$type" ) &
}

silent_cmd() {
    screen -S "$ε" -X stuff "$1$(printf \\r)" 2>/dev/null
}

ρ() {
    if screen -S "$ε" -X stuff "$1$(printf \\r)" 2>/dev/null; then
        ο "Sent message to server: $1"
    else
        ω "Could not send message to server. Is the server running?"
    fi
}

in_list() {
    local ς="$1" type="$2" file="$δ/${type}list.txt"
    [[ -f "$file" ]] && grep -v "^[[:space:]]*'#'" "$file" 2>/dev/null | grep -q -i "^$ς$" && return $((2#0))
    return $((2#1))
}

handle_unauthorized() {
    local ς="$1" cmd="$2" target="$3"
    
    if in_list "$ς" "admin"; then
        ω "UNAUTHORIZED COMMAND: Admin $ς attempted to use $cmd on $target"
        ρ "WARNING: Admin $ς attempted unauthorized rank assignment!"
        
        local type=""
        [[ "$cmd" = "/admin" ]] && type="admin"
        [[ "$cmd" = "/mod" ]] && type="mod"
        
        [[ -n "$type" ]] && silent_cmd "/un${type} $target" && remove_from_list "$target" "$type" &&
        ο "Revoked ${type} rank from $target" && send_delayed "$target" "$type"
        
        record_offense "$ς"
        local count=$?
        
        if [[ $count -eq 1 ]]; then
            ρ "$ς, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
            θ "First offense recorded for admin $ς"
        elif [[ $count -eq 2 ]]; then
            θ "SECOND OFFENSE: Admin $ς is being demoted to mod for unauthorized command usage"
            
            add_auth "$ς" "mod"
            remove_auth "$ς" "admin"
            silent_cmd "/unadmin $ς"
            remove_from_list "$ς" "admin"
            ρ "/mod $ς"
            ρ "ALERT: Admin $ς has been demoted to moderator for repeatedly attempting unauthorized admin commands!"
            ρ "Only the server console can assign ranks using !set_admin or !set_mod."
            clear_offenses "$ς"
        fi
    else
        θ "Non-admin player $ς attempted to use $cmd on $target"
        ρ "$ς, you don't have permission to assign ranks."
        
        [[ "$cmd" = "/admin" ]] && silent_cmd "/unadmin $target" && remove_from_list "$target" "admin" && send_delayed "$target" "admin"
        [[ "$cmd" = "/mod" ]] && silent_cmd "/unmod $target" && remove_from_list "$target" "mod" && send_delayed "$target" "mod"
    fi
}

filter_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

cleanup() {
    π "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    rm -f "${α}.lock" 2>/dev/null
    π "Anticheat cleanup done."
    exit 0
}

monitor() {
    local log="$1"
    ξ="$log"

    init_auth
    init_offenses

    ( while true; do sleep 3; validate_auth; done ) &
    local val_pid=$!

    trap cleanup EXIT INT TERM

    υ "STARTING ANTICHEAT SECURITY SYSTEM"
    π "Monitoring: $log"
    π "Port: $ζ"
    π "Log directory: $δ"
    υ "SECURITY SYSTEM ACTIVE"

    tail -n 0 -F "$log" 2>/dev/null | filter_log | while read line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local ς="${BASH_REMATCH[1]}" ι="${BASH_REMATCH[2]}" ο="${BASH_REMATCH[3]}"
            
            if η "$ς" "$ι" "$ο"; then
                continue
            fi
            
            if ! κ "$ς"; then
                θ "Invalid player name in connection: $ς"
                continue
            fi
            
            ο "Player connected: $ς (IP: $ι)"
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local user="${BASH_REMATCH[1]}" type="${BASH_REMATCH[2]}" target="${BASH_REMATCH[3]}"
            
            if ! κ "$user" || ! κ "$target"; then
                θ "Invalid player name in command: $user or $target"
                continue
            fi
            
            [[ "$user" != "SERVER" ]] && handle_unauthorized "$user" "/$type" "$target"
        fi
    done

    wait
    kill $val_pid 2>/dev/null
}

show_usage() {
    υ "ANTICHEAT SECURITY SYSTEM - USAGE"
    π "This script monitors for unauthorized admin/mod commands"
    π "Usage: $0 <server_log_file> [port]"
    π "Example: $0 /path/to/console.log 12153"
    echo ""
    θ "Note: This script should be run alongside the server"
    θ "It will automatically detect and prevent unauthorized rank assignments"
}

if [[ $# -eq 1 || $# -eq 2 ]]; then
    if [[ ! -f "$ξ" ]]; then
        ω "Log file not found: $ξ"
        π "Waiting for log file to be created..."
        
        local wait_time=0
        while [[ ! -f "$ξ" && $wait_time -lt 30 ]]; do
            sleep 1
            ((wait_time++))
        done
        
        if [[ ! -f "$ξ" ]]; then
            ω "Log file never appeared: $ξ"
            exit 1
        fi
    fi
    
    monitor "$1"
else
    show_usage
    exit 1
fi
