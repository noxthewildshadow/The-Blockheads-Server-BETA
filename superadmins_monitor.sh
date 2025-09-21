#!/bin/bash
# =============================================================================
# SUPERADMINS MONITOR SCRIPT
# =============================================================================

# Load common functions
source blockheads_common.sh

SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
SUPERADMINS_FILE="$SAVES_DIR/../superadminslist.txt"

print_header "STARTING SUPERADMINS MONITOR"

# Create superadminslist.txt if it doesn't exist
if [ ! -f "$SUPERADMINS_FILE" ]; then
    touch "$SUPERADMINS_FILE"
    print_success "Created superadminslist.txt"
fi

while true; do
    if [ -f "$SUPERADMINS_FILE" ]; then
        # Read the superadmins list
        while read -r username; do
            # Skip empty lines
            [ -z "$username" ] && continue
            
            # For each world in the saves directory
            for world in "$SAVES_DIR"/*; do
                if [ -d "$world" ]; then
                    players_log="$world/players.log"
                    if [ -f "$players_log" ]; then
                        # Check if the user is in the players.log with ADMIN rank
                        if grep -q "^$username|" "$players_log"; then
                            # Check if the rank is ADMIN
                            current_rank=$(grep "^$username|" "$players_log" | cut -d'|' -f5)
                            if [ "$current_rank" != "ADMIN" ]; then
                                # Update the rank to ADMIN while preserving other fields
                                sed -i "s/^$username|\(.*\)|\(.*\)|\(.*\)|\(.*\)|\(.*\)|\(.*\)$/$username|\1|\2|\3|ADMIN|\5|\6/" "$players_log"
                                print_success "Updated $username to ADMIN in $world"
                            fi
                        else
                            # The user is not in the players.log, add them with ADMIN rank
                            echo "$username|unknown|unknown|NONE|ADMIN|NO|NO" >> "$players_log"
                            print_success "Added $username as ADMIN in $world"
                        fi
                    fi
                fi
            done
        done < "$SUPERADMINS_FILE"
    fi
    sleep 0.5
done
