#!/bin/bash

# Set error handling
set -e

# Define log file path
LOG_FILE="/tmp/cursor_linux_id_modifier.log"

# Initialize log file
initialize_log() {
    echo "========== Cursor ID Modifier Tool Log Start $(date) ==========" > "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions - output to both terminal and log file
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Log command output to log file
log_cmd_output() {
    local cmd="$1"
    local msg="$2"
    echo "[CMD] $(date '+%Y-%m-%d %H:%M:%S') Executing command: $cmd" >> "$LOG_FILE"
    echo "[CMD] $msg:" >> "$LOG_FILE"
    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

# Get current user
get_current_user() {
    if [ "$EUID" -eq 0 ]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "Unable to retrieve username"
    exit 1
fi

# Define Cursor paths on Linux
CURSOR_CONFIG_DIR="$HOME/.config/Cursor"
STORAGE_FILE="$CURSOR_CONFIG_DIR/User/globalStorage/storage.json"
BACKUP_DIR="$CURSOR_CONFIG_DIR/User/globalStorage/backups"

# Possible Cursor binary paths
CURSOR_BIN_PATHS=(
    "/usr/bin/cursor"
    "/usr/local/bin/cursor"
    "$HOME/.local/bin/cursor"
    "/opt/cursor/cursor"
    "/snap/bin/cursor"
    "$HOME/.cursor-portal-executable/usr/bin/cursor"
)

# Find Cursor installation path
find_cursor_path() {
    log_info "Searching for Cursor installation path..."
    
    for path in "${CURSOR_BIN_PATHS[@]}"; do
        if [ -f "$path" ]; then
            log_info "Found Cursor installation path: $path"
            CURSOR_PATH="$path"
            return 0
        fi
    done

    # Try locating with the 'which' command
    if command -v cursor &> /dev/null; then
        CURSOR_PATH=$(which cursor)
        log_info "Found Cursor via 'which': $CURSOR_PATH"
        return 0
    fi
    
    # Attempt to find possible installation paths
    local cursor_paths=$(find /usr /opt $HOME/.local -name "cursor" -type f -executable 2>/dev/null)
    if [ -n "$cursor_paths" ]; then
        CURSOR_PATH=$(echo "$cursor_paths" | head -1)
        log_info "Found Cursor via search: $CURSOR_PATH"
        return 0
    fi
    
    log_warn "Cursor executable not found, will attempt to use configuration directory"
    return 1
}

# Locate and identify Cursor resource files
find_cursor_resources() {
    log_info "Searching for Cursor resource directory..."
    
    # Possible resource directory paths
    local resource_paths=(
        "/usr/lib/cursor"
        "/usr/share/cursor"
        "/opt/cursor"
        "$HOME/.local/share/cursor"
        "$HOME/.cursor-portal-executable/usr/share/cursor"
    )
    
    for path in "${resource_paths[@]}"; do
        if [ -d "$path" ]; then
            log_info "Found Cursor resource directory: $path"
            CURSOR_RESOURCES="$path"
            return 0
        fi
    done
    
    # If CURSOR_PATH exists, try inferring from it
    if [ -n "$CURSOR_PATH" ]; then
        local base_dir=$(dirname "$CURSOR_PATH")
        if [ -d "$base_dir/resources" ]; then
            CURSOR_RESOURCES="$base_dir/resources"
            log_info "Inferred resource directory from binary path: $CURSOR_RESOURCES"
            return 0
        fi
    fi
    
    log_warn "Cursor resource directory not found"
    return 1
}

# Check permissions
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run this script with sudo"
        echo "Example: sudo $0"
        exit 1
    fi
}

# Check and terminate Cursor processes
check_and_kill_cursor() {
    log_info "Checking for Cursor processes..."
    
    local attempt=1
    local max_attempts=5
    
    # Function: Get process details
    get_process_details() {
        local process_name="$1"
        log_debug "Getting details for $process_name process:"
        ps aux | grep -i "cursor" | grep -v grep | grep -v "cursor_linux_id_modifier.sh"
    }
    
    while [ $attempt -le $max_attempts ]; do
        # Use precise matching to get Cursor processes, excluding current script and grep process
        CURSOR_PIDS=$(ps aux | grep -i "cursor" | grep -v "grep" | grep -v "cursor_linux_id_modifier.sh" | awk '{print $2}' || true)
        
        if [ -z "$CURSOR_PIDS" ]; then
            log_info "No running Cursor processes found"
            return 0
        fi
        
        log_warn "Found running Cursor processes"
        get_process_details "cursor"
        
        log_warn "Attempting to terminate Cursor processes..."
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "Forcing process termination..."
            kill -9 $CURSOR_PIDS 2>/dev/null || true
        else
            kill $CURSOR_PIDS 2>/dev/null || true
        fi
        
        sleep 1
        
        # Recheck if processes are still running, excluding current script and grep process
        if ! ps aux | grep -i "cursor" | grep -v "grep" | grep -v "cursor_linux_id_modifier.sh" > /dev/null; then
            log_info "Cursor processes successfully terminated"
            return 0
        fi
        
        log_warn "Waiting for processes to terminate, attempt $attempt/$max_attempts..."
        ((attempt++))
    done
    
    log_error "Failed to terminate Cursor processes after $max_attempts attempts"
    get_process_details "cursor"
    log_error "Please manually terminate the processes and retry"
    exit 1
}

# Backup configuration file
backup_config() {
    if [ ! -f "$STORAGE_FILE" ]; then
        log_warn "Configuration file does not exist, skipping backup"
        return 0
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/storage.json.backup_$(date +%Y%m%d_%H%M%S)"
    
    if cp "$STORAGE_FILE" "$backup_file"; then
        chmod 644 "$backup_file"
        chown "$CURRENT_USER" "$backup_file"
        log_info "Configuration backed up to: $backup_file"
    else
        log_error "Backup failed"
        exit 1
    fi
}

# Generate random ID
generate_random_id() {
    # Generate a 32-byte (64 hexadecimal characters) random number
    openssl rand -hex 32
}

# Generate random UUID
generate_uuid() {
    # Use uuidgen to generate UUID on Linux
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Alternative: Use /proc/sys/kernel/random/uuid
        if [ -f /proc/sys/kernel/random/uuid ]; then
            cat /proc/sys/kernel/random/uuid
        else
            # Last resort: Use openssl to generate
            openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'
        fi
    fi
}

# Modify existing file
modify_or_add_config() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    if [ ! -f "$file" ]; then
        log_error "File does not exist: $file"
        return 1
    fi
    
    # Ensure file is writable
    chmod 644 "$file" || {
        log_error "Unable to modify file permissions: $file"
        return 1
    }
    
    # Create temporary file
    local temp_file=$(mktemp)
    
    # Check if key exists
    if grep -q "\"$key\":" "$file"; then
        # Key exists, perform replacement
        sed "s/\"$key\":[[:space:]]*\"[^\"]*\"/\"$key\": \"$value\"/" "$file" > "$temp_file" || {
            log_error "Failed to modify configuration: $key"
            rm -f "$temp_file"
            return 1
        }
    else
        # Key does not exist, add new key-value pair
        sed "s/}$/,\n    \"$key\": \"$value\"\n}/" "$file" > "$temp_file" || {
            log_error "Failed to add configuration: $key"
            rm -f "$temp_file"
            return 1
        }
    fi
    
    # Check if temporary file is empty
    if [ ! -s "$temp_file" ]; then
        log_error "Generated temporary file is empty"
        rm -f "$temp_file"
        return 1
    fi
    
    # Use cat to replace original file content
    cat "$temp_file" > "$file" || {
        log_error "Unable to write to file: $file"
        rm -f "$temp_file"
        return 1
    }
    
    rm -f "$temp_file"
    
    # Restore file permissions
    chmod 444 "$file"
    
    return 0
}

# Generate new configuration
generate_new_config() {
    echo
    log_warn "Machine code reset option"
    
    reset_choice="1"
    
    # Log for debugging
    echo "[INPUT_DEBUG] Machine code reset option selected: $reset_choice" >> "$LOG_FILE"
    
    if [ "$reset_choice" = "1" ]; then
        log_info "You chose to reset the machine code"
        
        if [ -f "$STORAGE_FILE" ]; then
            log_info "Existing configuration file found: $STORAGE_FILE"
            
            backup_config
            
            local new_device_id=$(generate_uuid)
            local new_machine_id="auth0|user_$(openssl rand -hex 16)"
            
            log_info "Setting new device and machine IDs..."
            log_debug "New device ID: $new_device_id"
            log_debug "New machine ID: $new_machine_id"
            
            if modify_or_add_config "deviceId" "$new_device_id" "$STORAGE_FILE" && \
               modify_or_add_config "machineId" "$new_machine_id" "$STORAGE_FILE"; then
                log_info "Configuration file successfully modified"
            else
                log_error "Failed to modify configuration file"
            fi
        else
            log_warn "Configuration file not found, skipping ID modification"
        fi
    else
        log_info "You chose not to reset the machine code, only JS files will be modified"
        
        if [ -f "$STORAGE_FILE" ]; then
            log_info "Existing configuration file found: $STORAGE_FILE"
            backup_config
        else
            log_warn "Configuration file not found, skipping ID modification"
        fi
    fi
    
    echo
    log_info "Configuration processing complete"
}

# Find Cursor JS files
find_cursor_js_files() {
    log_info "Searching for Cursor JS files..."
    
    local js_files=()
    local found=false
    
    # If resource directory is found, search within it
    if [ -n "$CURSOR_RESOURCES" ]; then
        log_debug "Searching for JS files in resource directory: $CURSOR_RESOURCES"
        
        # Recursively search for specific JS files in resource directory
        local js_patterns=(
            "*/extensionHostProcess.js"
            "*/main.js"
            "*/cliProcessMain.js"
            "*/app/out/vs/workbench/api/node/extensionHostProcess.js"
            "*/app/out/main.js"
            "*/app/out/vs/code/node/cliProcessMain.js"
        )
        
        for pattern in "${js_patterns[@]}"; do
            local files=$(find "$CURSOR_RESOURCES" -path "$pattern" -type f 2>/dev/null)
            if [ -n "$files" ]; then
                while read -r file; do
                    log_info "Found JS file: $file"
                    js_files+=("$file")
                    found=true
                done <<< "$files"
            fi
        done
    fi
    
    # If not found, try searching in /usr and $HOME directories
    if [ "$found" = false ]; then
        log_warn "No JS files found in resource directory, attempting to search in other directories..."
        
        # Search in system directories, limit depth to avoid long searches
        local search_dirs=(
            "/usr/lib/cursor"
            "/usr/share/cursor"
            "/opt/cursor"
            "$HOME/.config/Cursor"
            "$HOME/.local/share/cursor"
        )
        
        for dir in "${search_dirs[@]}"; do
            if [ -d "$dir" ]; then
                log_debug "Searching directory: $dir"
                local files=$(find "$dir" -name "*.js" -type f -exec grep -l "IOPlatformUUID\|x-cursor-checksum" {} \; 2>/dev/null)
                if [ -n "$files" ]; then
                    while read -r file; do
                        log_info "Found JS file: $file"
                        js_files+=("$file")
                        found=true
                    done <<< "$files"
                fi
            fi
        done
    fi
    
    if [ "$found" = false ]; then
        log_error "No modifiable JS files found"
        return 1
    fi
    
    # Save found files to global variable
    CURSOR_JS_FILES=("${js_files[@]}")
    log_info "Found ${#CURSOR_JS_FILES[@]} JS files to modify"
    return 0
}

# Modify Cursor JS files
modify_cursor_js_files() {
    log_info "Starting to modify Cursor JS files..."
    
    # First, find the JS files to modify
    if ! find_cursor_js_files; then
        log_error "Unable to find modifiable JS files"
        return 1
    fi
    
    local modified_count=0
    
    for file in "${CURSOR_JS_FILES[@]}"; do
        log_info "Processing file: $file"
        
        # Create file backup
        local backup_file="${file}.backup_$(date +%Y%m%d%H%M%S)"
        if ! cp "$file" "$backup_file"; then
            log_error "Unable to create file backup: $file"
            continue
        fi
        
        # Ensure file is writable
        chmod 644 "$file" || {
            log_error "Unable to modify file permissions: $file"
            continue
        }
        
        # Check file content and make appropriate modifications
        if grep -q 'i.header.set("x-cursor-checksum' "$file"; then
            log_debug "Found x-cursor-checksum setting code"
            
            # Perform specific replacement
            if sed -i 's/i\.header\.set("x-cursor-checksum",e===void 0?`${p}${t}`:`${p}${t}\/${e}`)/i.header.set("x-cursor-checksum",e===void 0?`${p}${t}`:`${p}${t}\/${p}`)/' "$file"; then
                log_info "Successfully modified x-cursor-checksum setting code"
                ((modified_count++))
            else
                log_error "Failed to modify x-cursor-checksum setting code"
                # Restore backup
                cp "$backup_file" "$file"
            fi
        elif grep -q "IOPlatformUUID" "$file"; then
            log_debug "Found IOPlatformUUID keyword"
            
            # Try different replacement patterns
            if grep -q "function a\$" "$file" && ! grep -q "return crypto.randomUUID()" "$file"; then
                if sed -i 's/function a\$(t){switch/function a\$(t){return crypto.randomUUID(); switch/' "$file"; then
                    log_debug "Successfully injected randomUUID call into a\$ function"
                    ((modified_count++))
                else
                    log_error "Failed to modify a\$ function"
                    cp "$backup_file" "$file"
                fi
            elif grep -q "async function v5" "$file" && ! grep -q "return crypto.randomUUID()" "$file"; then
                if sed -i 's/async function v5(t){let e=/async function v5(t){return crypto.randomUUID(); let e=/' "$file"; then
                    log_debug "Successfully injected randomUUID call into v5 function"
                    ((modified_count++))
                else
                    log_error "Failed to modify v5 function"
                    cp "$backup_file" "$file"
                fi
            else
                # General injection method
                if ! grep -q "// Cursor ID Modifier Tool Injection" "$file"; then
                    local inject_code="
// Cursor ID Modifier Tool Injection - $(date +%Y%m%d%H%M%S)
// Random Device ID Generator Injection - $(date +%s)
const randomDeviceId_$(date +%s) = () => {
    try {
        return require('crypto').randomUUID();
    } catch (e) {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
            const r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        });
    }
};
"
                    # Inject code at the beginning of the file
                    echo "$inject_code" > "${file}.new"
                    cat "$file" >> "${file}.new"
                    mv "${file}.new" "$file"
                    
                    # Replace call points
                    sed -i 's/await v5(!1)/randomDeviceId_'"$(date +%s)"'()/g' "$file"
                    sed -i 's/a\$(t)/randomDeviceId_'"$(date +%s)"'()/g' "$file"
                    
                    log_debug "Completed general modification"
                    ((modified_count++))
                else
                    log_info "File already contains custom injection code, skipping modification"
                fi
            fi
        else
            # No keywords found, try general method
            if ! grep -q "return crypto.randomUUID()" "$file" && ! grep -q "// Cursor ID Modifier Tool Injection" "$file"; then
                # Try other key functions
                if grep -q "function t\$()" "$file" || grep -q "async function y5" "$file"; then
                    # Modify MAC address retrieval function
                    if grep -q "function t\$()" "$file"; then
                        sed -i 's/function t\$(){/function t\$(){return "00:00:00:00:00:00";/' "$file"
                    fi
                    
                    # Modify device ID retrieval function
                    if grep -q "async function y5" "$file"; then
                        sed -i 's/async function y5(t){/async function y5(t){return crypto.randomUUID();/' "$file"
                    fi
                    
                    ((modified_count++))
                else
                    # Most general injection method
                    local new_uuid=$(generate_uuid)
                    local machine_id="auth0|user_$(openssl rand -hex 16)"
                    local device_id=$(generate_uuid)
                    local mac_machine_id=$(openssl rand -hex 32)
                    
                    local inject_universal_code="
// Cursor ID Modifier Tool Injection - $(date +%Y%m%d%H%M%S)
// Global Intercept Device Identifier - $(date +%s)
const originalRequire_$(date +%s) = require;
require = function(module) {
    const result = originalRequire_$(date +%s)(module);
    if (module === 'crypto' && result.randomUUID) {
        const originalRandomUUID_$(date +%s) = result.randomUUID;
        result.randomUUID = function() {
            return '$new_uuid';
        };
    }
    return result;
};

// Override all possible system ID retrieval functions
global.getMachineId = function() { return '$machine_id'; };
global.getDeviceId = function() { return '$device_id'; };
global.macMachineId = '$mac_machine_id';
"
                    # Replace variables
                    inject_universal_code=${inject_universal_code//\$new_uuid/$new_uuid}
                    inject_universal_code=${inject_universal_code//\$machine_id/$machine_id}
                    inject_universal_code=${inject_universal_code//\$device_id/$device_id}
                    inject_universal_code=${inject_universal_code//\$mac_machine_id/$mac_machine_id}
                    
                    # Inject code at the beginning of the file
                    echo "$inject_universal_code" > "${file}.new"
                    cat "$file" >> "${file}.new"
                    mv "${file}.new" "$file"
                    
                    log_debug "Completed most general injection"
                    ((modified_count++))
                fi
            else
                log_info "File has already been modified, skipping modification"
            fi
        fi
        
        # Restore file permissions
        chmod 444 "$file"
    done
    
    if [ "$modified_count" -eq 0 ]; then
        log_error "Failed to successfully modify any JS files"
        return 1
    fi
    
    log_info "Successfully modified $modified_count JS files"
    return 0
}

# Disable auto-update
disable_auto_update() {
    log_info "Disabling Cursor auto-update..."
    
    # Find possible update configuration files
    local update_configs=(
        "$CURSOR_CONFIG_DIR/update-config.json"
        "$HOME/.local/share/cursor/update-config.json"
        "/opt/cursor/resources/app-update.yml"
    )
    
    local disabled=false
    
    for config in "${update_configs[@]}"; do
        if [ -f "$config" ]; then
            log_info "Found update configuration file: $config"
            
            # Backup and clear configuration file
            cp "$config" "${config}.bak" 2>/dev/null
            echo '{"autoCheck": false, "autoDownload": false}' > "$config"
            chmod 444 "$config"
            
            log_info "Disabled update configuration file: $config"
            disabled=true
        fi
    done
    
    # Try finding updater executable and disable it
    local updater_paths=(
        "$HOME/.config/Cursor/updater"
        "/opt/cursor/updater"
        "/usr/lib/cursor/updater"
    )
    
    for updater in "${updater_paths[@]}"; do
        if [ -f "$updater" ] || [ -d "$updater" ]; then
            log_info "Found updater: $updater"
            if [ -f "$updater" ]; then
                mv "$updater" "${updater}.bak" 2>/dev/null
            else
                touch "${updater}.disabled"
            fi
            
            log_info "Disabled updater: $updater"
            disabled=true
        fi
    done
    
    if [ "$disabled" = false ]; then
        log_warn "No update configuration files or updaters found"
    else
        log_info "Successfully disabled auto-update"
    fi
}

# New: General menu selection function
# Parameters: 
# $1 - Prompt message
# $2 - Option array, format "Option1|Option2|Option3"
# $3 - Default option index (starting from 0)
# Returns: Selected option index (starting from 0)
select_menu_option() {
    local prompt="$1"
    IFS='|' read -ra options <<< "$2"
    local default_index=${3:-0}
    local selected_index=$default_index
    local key_input
    local cursor_up='\033[A'
    local cursor_down='\033[B'
    local enter_key=$'\n'
    
    # Save cursor position
    tput sc
    
    # Display prompt message
    echo -e "$prompt"
    
    # Display menu for the first time
    for i in "${!options[@]}"; do
        if [ $i -eq $selected_index ]; then
            echo -e " ${GREEN}►${NC} ${options[$i]}"
        else
            echo -e "   ${options[$i]}"
        fi
    done
    
    # Loop to handle keyboard input
    while true; do
        # Read single key
        read -rsn3 key_input
        
        # Detect key
        case "$key_input" in
            # Up arrow key
            $'\033[A')
                if [ $selected_index -gt 0 ]; then
                    ((selected_index--))
                fi
                ;;
            # Down arrow key
            $'\033[B')
                if [ $selected_index -lt $((${#options[@]}-1)) ]; then
                    ((selected_index++))
                fi
                ;;
            # Enter key
            "")
                echo # New line
                log_info "You selected: ${options[$selected_index]}"
                return $selected_index
                ;;
        esac
        
        # Restore cursor position
        tput rc
        
        # Redisplay menu
        for i in "${!options[@]}"; do
            if [ $i -eq $selected_index ]; then
                echo -e " ${GREEN}►${NC} ${options[$i]}"
            else
                echo -e "   ${options[$i]}"
            fi
        done
    done
}

# Main function
main() {
    if [[ $(uname) != "Linux" ]]; then
        log_error "This script only supports Linux systems"
        exit 1
    fi
    
    initialize_log
    log_info "Script started..."
    
    log_info "System information: $(uname -a)"
    log_info "Current user: $CURRENT_USER"
    log_cmd_output "lsb_release -a 2>/dev/null || cat /etc/*release 2>/dev/null || cat /etc/issue" "System version information"
    
    clear
    echo -e "
    ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ 
   ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
   ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
   ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
   ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
    ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝
    "
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}   Cursor Linux Startup Tool     ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    echo -e "${YELLOW}[Important Note]${NC} This tool prioritizes modifying JS files for safer and more reliable operation"
    echo
    
    check_permissions
    find_cursor_path
    find_cursor_resources
    check_and_kill_cursor
    backup_config
    generate_new_config
    
    log_info "Starting to modify Cursor JS files..."
    if modify_cursor_js_files; then
        log_info "JS files successfully modified!"
    else
        log_warn "JS file modification failed, but configuration file modification may have succeeded"
        log_warn "If Cursor still prompts that the device is disabled after restarting, please rerun this script"
    fi
    
    disable_auto_update
    
    log_info "Please restart Cursor to apply the new configuration"
    
    echo
    echo -e "${GREEN}================================${NC}"
    echo -e "${YELLOW}  Follow the public account 【AI Pancake Roll】 to exchange more Cursor tips and AI knowledge (script is free, follow the account to join the group for more tips and experts) ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo
    
    log_info "Script execution completed"
    echo "========== Cursor ID Modifier Tool Log End $(date) ==========" >> "$LOG_FILE"
    
    echo
    log_info "Detailed log saved to: $LOG_FILE"
    echo "If you encounter issues, please provide this log file to the developer for troubleshooting"
    echo
}

main
