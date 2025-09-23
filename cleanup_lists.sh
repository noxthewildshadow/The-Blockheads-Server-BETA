#!/bin/bash
# =============================================================================
# CLEANUP LISTS SCRIPT - CLEAN ALL LIST FILES ON SERVER STARTUP
# =============================================================================

# Load common functions
source blockheads_common.sh

# Initialize variables
LOG_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/default"

# Function to clean all list files
clean_all_list_files() {
    local lists=("adminlist" "modlist" "whitelist" "blacklist")
    
    for list_type in "${lists[@]}"; do
        local list_file="$LOG_DIR/${list_type}.txt"
        if [ -f "$list_file" ]; then
            > "$list_file"  # Empty the file
            print_success "Cleared ${list_type}.txt"
        else
            touch "$list_file"
        fi
    done
    
    # Cloudwide admin list should only contain SUPER admins from players.log
    local superadmin_file="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    if [ -f "$superadmin_file" ]; then
        > "$superadmin_file"
        print_success "Cleared cloudWideOwnedAdminlist.txt"
    fi
    
    print_status "All list files cleared. They will be populated dynamically as players connect."
}

# Main execution
print_header "CLEANING UP LIST FILES"
clean_all_list_files
print_header "CLEANUP COMPLETE"
