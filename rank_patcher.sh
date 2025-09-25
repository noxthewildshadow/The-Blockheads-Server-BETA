#!/bin/bash

# --- CONFIGURACIÓN ---
WORLD_ID="$1"
SCREEN_SESSION="$2"
SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CLOUD_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"

# --- VALIDACIÓN DE ARGUMENTOS ---
if [ -z "$WORLD_ID" ] || [ -z "$SCREEN_SESSION" ]; then
    echo "Error: World ID and Screen Session must be provided." >&2
    echo "Usage: ./rank_patcher.sh <world_id> <screen_session_name>" >&2
    exit 1
fi

# --- RUTAS DE ARCHIVOS ---
WORLD_DIR="$SAVES_DIR/$WORLD_ID"
PLAYERS_LOG="$WORLD_DIR/players.log"
CONSOLE_LOG="$WORLD_DIR/console.log"
ADMIN_LIST="$WORLD_DIR/adminlist.txt"
MOD_LIST="$WORLD_DIR/modlist.txt"
WHITELIST="$WORLD_DIR/whitelist.txt"
BLACKLIST="$WORLD_DIR/blacklist.txt"
CLOUD_ADMIN_LIST="$CLOUD_DIR/cloudWideOwnedAdminlist.txt"

# --- FUNCIÓN PARA ENVIAR COMANDOS AL SERVIDOR ---
send_command() {
    screen -S "$SCREEN_SESSION" -p 0 -X stuff "$1^M"
}

# --- FUNCIÓN PARA ENVIAR MENSAJES PRIVADOS A JUGADORES ---
send_message() {
    local player_name="$1"
    local message="$2"
    send_command "/msg \"$player_name\" $message"
}

# --- INICIALIZACIÓN ---
# Crea los archivos necesarios si no existen
touch "$PLAYERS_LOG" "$CLOUD_ADMIN_LIST"

# Limpia las listas de rangos al iniciar, excepto whitelist y blacklist
> "$ADMIN_LIST"
> "$MOD_LIST"

# --- MONITOR DE CAMBIOS EN players.log ---
monitor_players_log() {
    # Almacena el contenido previo de players.log para detectar cambios
    declare -A last_known_state
    while IFS='|' read -r name ip1 ip2 pass rank white black; do
        last_known_state["$name"]="$rank|$white|$black"
    done < "$PLAYERS_LOG"

    while true; do
        # Espera 1 segundo entre cada verificación
        sleep 1

        # Si el archivo no existe, salta el ciclo
        [ ! -f "$PLAYERS_LOG" ] && continue

        while IFS='|' read -r name ip1 ip2 pass rank white black; do
            # Normaliza los campos eliminando espacios
            name=$(echo "$name" | xargs)
            rank=$(echo "$rank" | xargs)
            white=$(echo "$white" | xargs)
            black=$(echo "$black" | xargs)
            
            local current_state="$rank|$white|$black"
            local old_state="${last_known_state[$name]}"

            if [ "$current_state" != "$old_state" ]; then
                echo "Change detected for $name: $old_state -> $current_state"
                
                # Desglosa el estado anterior
                old_rank=$(echo "$old_state" | cut -d'|' -f1)
                old_black=$(echo "$old_state" | cut -d'|' -f3)

                # --- Lógica de Promoción/Degradación ---
                if [ "$rank" != "$old_rank" ]; then
                    # Quitar rangos viejos
                    [ "$old_rank" == "ADMIN" ] && send_command "/unadmin \"$name\""
                    [ "$old_rank" == "MOD" ] && send_command "/unmod \"$name\""
                    [ "$old_rank" == "SUPER" ] && sed -i "/^${name}$/d" "$CLOUD_ADMIN_LIST"
                    
                    # Asignar rangos nuevos
                    [ "$rank" == "ADMIN" ] && send_command "/admin \"$name\""
                    [ "$rank" == "MOD" ] && send_command "/mod \"$name\""
                    if [ "$rank" == "SUPER" ]; then
                        # Asegura que no esté duplicado
                        sed -i "/^${name}$/d" "$CLOUD_ADMIN_LIST"
                        echo "$name" >> "$CLOUD_ADMIN_LIST"
                    fi
                fi

                # --- Lógica de Blacklist ---
                if [ "$black" == "YES" ] && [ "$old_black" != "YES" ]; then
                    send_command "/unmod \"$name\""
                    send_command "/unadmin \"$name\""
                    send_command "/ban \"$name\""
                    send_command "/ban-ip $ip2"
                    # Si era SUPER, quitarlo de la lista global
                    if [ "$old_rank" == "SUPER" ]; then
                        sed -i "/^${name}$/d" "$CLOUD_ADMIN_LIST"
                    fi
                fi

                # Actualiza el estado conocido
                last_known_state["$name"]="$current_state"
            fi
        done < "$PLAYERS_LOG"
    done
}

# --- MONITOR DE CONSOLA PARA COMANDOS Y CONEXIONES ---
monitor_console_log() {
    # Espera a que el archivo de log se cree
    while [ ! -f "$CONSOLE_LOG" ]; do sleep 1; done

    tail -F -n 0 "$CONSOLE_LOG" | while read -r line; do
        # --- DETECCIÓN DE CONEXIÓN DE JUGADOR ---
        if echo "$line" | grep -q "Player Connected"; then
            PLAYER_NAME=$(echo "$line" | awk -F'Player Connected | \\|' '{print $2}' | xargs)
            PLAYER_IP=$(echo "$line" | awk -F' \\| ' '{print $2}' | xargs)

            # Si el jugador no existe en players.log, lo crea
            if ! grep -q "^$PLAYER_NAME |" "$PLAYERS_LOG"; then
                echo "$PLAYER_NAME | $PLAYER_IP | $PLAYER_IP | NONE | NONE | NO | NO" >> "$PLAYERS_LOG"
                # Recordatorio para poner contraseña
                (sleep 5; send_message "$PLAYER_NAME" "Welcome! Please set a password with: !password <pass> <confirm>") &
                # Kick si no pone contraseña en 1 minuto
                (sleep 60; 
                    if grep -q "^$PLAYER_NAME |.*| NONE |" "$PLAYERS_LOG"; then
                        send_message "$PLAYER_NAME" "You are being kicked for not setting a password."
                        send_command "/kick \"$PLAYER_NAME\""
                    fi
                ) &
            else
                # El jugador ya existe, actualiza su IP actual y verifica
                FIRST_IP=$(grep "^$PLAYER_NAME |" "$PLAYERS_LOG" | cut -d'|' -f2 | xargs)
                CURRENT_IP=$(grep "^$PLAYER_NAME |" "$PLAYERS_LOG" | cut -d'|' -f3 | xargs)

                # Si la IP de conexión es diferente a la última registrada
                if [ "$PLAYER_IP" != "$CURRENT_IP" ]; then
                    sed -i "s|^$PLAYER_NAME |.*|.*|.*|.*|.*|.*$|$PLAYER_NAME | $FIRST_IP | $PLAYER_IP | $(grep "^$PLAYER_NAME |" "$PLAYERS_LOG" | cut -d'|' -f4-)|" "$PLAYERS_LOG"
                    
                    send_message "$PLAYER_NAME" "Your IP has changed. You have 30 seconds to verify with: !ip_change <password>"
                    # Inicia cooldown de 30 segundos para kick/ban
                    (
                        sleep 30
                        # Vuelve a verificar la IP actual en el log
                        VERIFIED_IP=$(grep "^$PLAYER_NAME |" "$PLAYERS_LOG" | cut -d'|' -f3 | xargs)
                        if [ "$PLAYER_IP" == "$VERIFIED_IP" ]; then
                            send_message "$PLAYER_NAME" "Your IP is still unverified. Kicking and banning IP for 30 seconds."
                            send_command "/kick \"$PLAYER_NAME\""
                            send_command "/ban-ip $PLAYER_IP"
                            # Desbanea la IP después de 30 segundos
                            (sleep 30; send_command "/unban-ip $PLAYER_IP") &
                        fi
                    ) &
                fi
            fi
        fi

        # --- DETECCIÓN DE COMANDOS DE CONTRASEÑA ---
        if echo "$line" | grep -qE ": !password|: !ip_change|: !change_psw"; then
            PLAYER_NAME=$(echo "$line" | awk -F'] ' '{print $2}' | awk -F':' '{print $1}' | xargs)
            COMMAND=$(echo "$line" | awk -F': ' '{print $2}')
            
            send_command "/clear"
            sleep 0.25 # Pequeña pausa antes de responder

            # Comando !password
            if echo "$COMMAND" | grep -q "^!password"; then
                PASS1=$(echo "$COMMAND" | awk '{print $2}')
                PASS2=$(echo "$COMMAND" | awk '{print $3}')
                if [ -z "$PASS1" ] || [ -z "$PASS2" ]; then
                    send_message "$PLAYER_NAME" "Usage: !password <password> <confirm_password>"
                elif [ ${#PASS1} -lt 7 ] || [ ${#PASS1} -gt 16 ]; then
                    send_message "$PLAYER_NAME" "Error: Password must be between 7 and 16 characters."
                elif [ "$PASS1" != "$PASS2" ]; then
                    send_message "$PLAYER_NAME" "Error: Passwords do not match."
                else
                    sed -i "s|^\($PLAYER_NAME | [^|]* | [^|]* | \)[^|]*|\1$PASS1|" "$PLAYERS_LOG"
                    send_message "$PLAYER_NAME" "Password set successfully!"
                fi
            
            # Comando !ip_change
            elif echo "$COMMAND" | grep -q "^!ip_change"; then
                PASS=$(echo "$COMMAND" | awk '{print $2}')
                SAVED_PASS=$(grep "^$PLAYER_NAME |" "$PLAYERS_LOG" | cut -d'|' -f4 | xargs)
                PLAYER_IP=$(grep "^$PLAYER_NAME |" "$PLAYERS_LOG" | cut -d'|' -f3 | xargs)

                if [ "$PASS" == "$SAVED_PASS" ]; then
                    # Actualiza la PRIMERA IP a la nueva IP verificada
                    sed -i "s|^\($PLAYER_NAME | \)[^|]*|\1$PLAYER_IP|" "$PLAYERS_LOG"
                    send_message "$PLAYER_NAME" "IP verified and updated successfully!"
                else
                    send_message "$PLAYER_NAME" "Error: Incorrect password."
                fi

            # Comando !change_psw
            elif echo "$COMMAND" | grep -q "^!change_psw"; then
                OLD_PASS=$(echo "$COMMAND" | awk '{print $2}')
                NEW_PASS=$(echo "$COMMAND" | awk '{print $3}')
                SAVED_PASS=$(grep "^$PLAYER_NAME |" "$PLAYERS_LOG" | cut -d'|' -f4 | xargs)

                if [ "$OLD_PASS" != "$SAVED_PASS" ]; then
                    send_message "$PLAYER_NAME" "Error: Old password does not match."
                elif [ ${#NEW_PASS} -lt 7 ] || [ ${#NEW_PASS} -gt 16 ]; then
                    send_message "$PLAYER_NAME" "Error: New password must be between 7 and 16 characters."
                else
                    sed -i "s|^\($PLAYER_NAME | [^|]* | [^|]* | \)[^|]*|\1$NEW_PASS|" "$PLAYERS_LOG"
                    send_message "$PLAYER_NAME" "Password changed successfully!"
                fi
            fi
        fi
    done
}


# --- INICIA LOS MONITORES EN SEGUNDO PLANO ---
echo "Rank Patcher started for world $WORLD_ID (Session: $SCREEN_SESSION)"
monitor_players_log &
monitor_console_log &

# Mantiene el script principal en ejecución
wait
