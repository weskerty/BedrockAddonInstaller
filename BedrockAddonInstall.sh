#!/bin/bash

# Config
#Ubicacion del Juego o Server
MinecraftPath="C:\Users\Admin\AppData\Local\Packages\Microsoft.MinecraftUWP_8wekyb3d8bbwe\LocalState\games\com.mojang"

#Ubicacion de los AddOns
AddOnsPath="D:\Usuarios\mr\Descargas\AddOns"

#Nombre de la Carpeta de Mundos
WorldsFolder="minecraftWorlds"





















UUID="True"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE=""
TEMP_COUNTER=0
declare -g -A existing_uuids
TEMP_DIR=""

declare -g bp_detected=0
declare -g bp_folders=0
declare -g rp_detected=0
declare -g rp_folders=0

declare -g mcpacks_extracted=0
declare -g mcaddons_extracted=0
declare -g zips_extracted=0
declare -g mcworlds_processed=0

declare -g bp_installed=0
declare -g bp_updated=0
declare -g rp_installed=0
declare -g rp_updated=0

detect_os() {
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
        echo "windows"
    else
        echo "linux"
    fi
}

normalize_path() {
    local path="$1"
    local os_type=$(detect_os)
    
    if [[ "$os_type" == "windows" ]]; then
        echo "$path" | sed 's|\\|/|g'
    else
        echo "$path"
    fi
}

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "$message"
    
    local clean_message=$(echo "$message" | sed 's/\x1b\[[0-9;]*m//g')
    
    if [[ ${#clean_message} -gt 100 ]]; then
        clean_message="${clean_message:0:97}..."
    fi
    
    echo "$timestamp - $clean_message" >> "$LOG_FILE"
}

check_dependencies() {
    local missing_deps=()
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v unzip &> /dev/null; then
        missing_deps+=("unzip")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "${RED}Error: Missing dependencies: ${missing_deps[*]}${NC}"
        log "${YELLOW}Install missing dependencies:${NC}"
        log "${YELLOW}  - Windows/MinGW: from Chocolatey or Winget ${NC}"
        exit 1
    fi
}

cleanup_temp() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
        log "${BLUE}Temporary directory cleaned${NC}"
    fi
}

clean_json_content() {
    local json_file="$1"
    
    if [[ ! -f "$json_file" ]]; then
        echo ""
        return 1
    fi
    
    local os_type=$(detect_os)
    
    if [[ "$os_type" == "windows" ]]; then
        cat "$json_file" | tr -d '\000-\037\177-\237' | tr -d '\r' | tr -d '\0'
    else
        cat "$json_file" | sed 's/[[:cntrl:]]//g' | tr -d '\r\0' 2>/dev/null || cat "$json_file" | tr -d '\000-\037\177-\237' | tr -d '\r' | tr -d '\0'
    fi
}

read_json_value() {
    local json_file="$1"
    local key_path="$2"
    
    if [[ ! -f "$json_file" ]]; then
        echo ""
        return 1
    fi
    
    local value=$(jq -r "$key_path // empty" "$json_file" 2>/dev/null || echo "")
    
    if [[ "$value" == "null" || "$value" == "" ]]; then
        local cleaned_json=$(clean_json_content "$json_file")
        if [[ -n "$cleaned_json" ]]; then
            value=$(echo "$cleaned_json" | jq -r "$key_path // empty" 2>/dev/null || echo "")
        fi
    fi
    
    if [[ "$value" == "null" || "$value" == "" ]]; then
        echo ""
        return 1
    else
        echo "$value"
        return 0
    fi
}

generate_folder_name() {
    local name="$1"
    
    local clean_name=$(echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    if [[ -z "$clean_name" ]]; then
        clean_name="addon_$(date +%s | tail -c 6)"
    fi
    
    echo "$clean_name"
}

generate_world_folder_name() {
    local name="$1"
    
    local clean_name=$(echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    if [[ -z "$clean_name" ]]; then
        clean_name="world_$(date +%s | tail -c 6)"
    fi
    
    echo "$clean_name"
}

apply_permissions() {
    local target_path="$1"
    local os_type=$(detect_os)
    
    if [[ "$os_type" == "linux" && -e "$target_path" ]]; then
        if [[ -n "$minecraft_owner" && -n "$minecraft_group" ]]; then
            chown -R "$minecraft_owner:$minecraft_group" "$target_path" 2>/dev/null || true
        fi
        if [[ -n "$minecraft_perms" ]]; then
            chmod -R "$minecraft_perms" "$target_path" 2>/dev/null || true
        fi
        log "${GREEN}Permissions applied to: $(basename "$target_path")${NC}"
    fi
}

initialize() {
    local os_type=$(detect_os)
    
    MinecraftPath=$(normalize_path "$MinecraftPath")
    AddOnsPath=$(normalize_path "$AddOnsPath")
    TEMP_DIR="$AddOnsPath/Temp"
    
    LOG_FILE="$AddOnsPath/addon-updater.log"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Minecraft AddOn Installer/Updater Started ($os_type)" > "$LOG_FILE"
    
    log "${BLUE}=== Minecraft AddOn Installer/Updater ===${NC}"
    log "${BLUE}System: $os_type${NC}"
    log "${BLUE}MinecraftPath: $MinecraftPath${NC}"
    log "${BLUE}AddOnsPath: $AddOnsPath${NC}"
    log "${BLUE}WorldsFolder: $WorldsFolder${NC}"
    log "${BLUE}TempDir: $TEMP_DIR${NC}"
    
    check_dependencies
    
    if [[ ! -d "$MinecraftPath" ]]; then
        log "${RED}Error: MinecraftPath does not exist: $MinecraftPath${NC}"
        exit 1
    fi
    
    if [[ ! -d "$AddOnsPath" ]]; then
        log "${RED}Error: AddOnsPath does not exist: $AddOnsPath${NC}"
        exit 1
    fi
    
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    mkdir -p "$TEMP_DIR"
    
    if [[ "$os_type" == "linux" ]]; then
        minecraft_owner=$(stat -c "%U" "$MinecraftPath" 2>/dev/null || echo "")
        minecraft_group=$(stat -c "%G" "$MinecraftPath" 2>/dev/null || echo "")
        minecraft_perms=$(stat -c "%a" "$MinecraftPath" 2>/dev/null || echo "")
        if [[ -n "$minecraft_owner" ]]; then
            log "${BLUE}Owner: $minecraft_owner:$minecraft_group ($minecraft_perms)${NC}"
        fi
    fi
    
    trap cleanup_temp EXIT
}

map_existing_uuids() {
    log "${YELLOW}=== Mapping existing UUIDs ===${NC}"
    
    local registry_file="$AddOnsPath/installed_packs_registry.txt"
    
    {
        echo "# Pack Registry - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# TYPE|UUID|NAME|FOLDER|PATH"
    } > "$registry_file"
    
    if [[ -d "$MinecraftPath/behavior_packs" ]]; then
        for pack_dir in "$MinecraftPath/behavior_packs"/*; do
            if [[ -d "$pack_dir" ]]; then
                ((bp_folders++))
                if [[ -f "$pack_dir/manifest.json" ]]; then
                    local uuid=$(read_json_value "$pack_dir/manifest.json" '.header.uuid')
                    local name=$(read_json_value "$pack_dir/manifest.json" '.header.name')
                    
                    if [[ -n "$uuid" ]]; then
                        existing_uuids["$uuid"]="$pack_dir"
                        local short_name=$(generate_folder_name "$name")
                        echo "BP|$uuid|$short_name|$(basename "$pack_dir")|$pack_dir" >> "$registry_file"
                        ((bp_detected++))
                    fi
                fi
            fi
        done
    fi
    
    if [[ -d "$MinecraftPath/resource_packs" ]]; then
        for pack_dir in "$MinecraftPath/resource_packs"/*; do
            if [[ -d "$pack_dir" ]]; then
                ((rp_folders++))
                if [[ -f "$pack_dir/manifest.json" ]]; then
                    local uuid=$(read_json_value "$pack_dir/manifest.json" '.header.uuid')
                    local name=$(read_json_value "$pack_dir/manifest.json" '.header.name')
                    
                    if [[ -n "$uuid" ]]; then
                        existing_uuids["$uuid"]="$pack_dir"
                        local short_name=$(generate_folder_name "$name")
                        echo "RP|$uuid|$short_name|$(basename "$pack_dir")|$pack_dir" >> "$registry_file"
                        ((rp_detected++))
                    fi
                fi
            fi
        done
    fi
    
    log "${GREEN}=== UUID MAPPING SUMMARY ===${NC}"
    log "${GREEN}Behavior Packs:${NC}"
    log "${GREEN}  Detected: $bp_detected${NC}"
    log "${GREEN}  Folders: $bp_folders${NC}"
    log "${GREEN}Resource Packs:${NC}"
    log "${GREEN}  Detected: $rp_detected${NC}"
    log "${GREEN}  Folders: $rp_folders${NC}"
    log "${GREEN}Registry: $(basename "$registry_file")${NC}"
}

extract_all_compressed() {
    log "${YELLOW}=== Extracting all compressed files ===${NC}"
    
    cd "$AddOnsPath" || exit 1
    
    for file in *.mcaddon *.mcpack *.zip; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file" | sed 's/\.[^.]*$//')
            local extract_dir="$TEMP_DIR/$base_name"
            local extension="${file##*.}"
            
            mkdir -p "$extract_dir"
            
            if unzip -q "$file" -d "$extract_dir" 2>/dev/null; then
                log "${GREEN}Extracted: $(basename "$file")${NC}"
                rm "$file"
                
                case "$extension" in
                    "mcaddon") ((mcaddons_extracted++)) ;;
                    "mcpack") ((mcpacks_extracted++)) ;;
                    "zip") ((zips_extracted++)) ;;
                esac
            else
                log "${RED}Error extracting: $(basename "$file")${NC}"
                rmdir "$extract_dir" 2>/dev/null || true
            fi
        fi
    done
    
    log "${GREEN}=== EXTRACTION SUMMARY ===${NC}"
    log "${GREEN}MCAddons: $mcaddons_extracted${NC}"
    log "${GREEN}MCPacks: $mcpacks_extracted${NC}"
    log "${GREEN}Zips: $zips_extracted${NC}"
}

extract_nested_compressed() {
    log "${YELLOW}=== Extracting nested compressed files ===${NC}"
    
    local rounds=0
    local max_rounds=5
    
    while [[ $rounds -lt $max_rounds ]]; do
        local found_compressed=false
        ((rounds++))
        
        log "${BLUE}Round $rounds - Searching for nested compressed files${NC}"
        
        while IFS= read -r -d '' compressed_file; do
            found_compressed=true
            local dir_path=$(dirname "$compressed_file")
            local base_name=$(basename "$compressed_file" | sed 's/\.[^.]*$//')
            local extract_dir="$dir_path/$base_name"
            
            mkdir -p "$extract_dir"
            
            if unzip -q "$compressed_file" -d "$extract_dir" 2>/dev/null; then
                log "${GREEN}Extracted nested: $(basename "$compressed_file")${NC}"
                rm "$compressed_file"
            else
                log "${RED}Error extracting nested: $(basename "$compressed_file")${NC}"
                rmdir "$extract_dir" 2>/dev/null || true
            fi
        done < <(find "$TEMP_DIR" -name "*.zip" -o -name "*.mcpack" -o -name "*.mcaddon" -type f -print0 2>/dev/null)
        
        if [[ "$found_compressed" == false ]]; then
            log "${GREEN}No more nested compressed files found${NC}"
            break
        fi
    done
    
    if [[ $rounds -eq $max_rounds ]]; then
        log "${YELLOW}Maximum extraction rounds reached${NC}"
    fi
}

find_all_manifests() {
    find "$TEMP_DIR" -name "manifest.json" -type f 2>/dev/null
}

process_single_pack() {
    local manifest_file="$1"
    local pack_root=$(dirname "$manifest_file")
    
    local uuid=$(read_json_value "$manifest_file" '.header.uuid')
    local name=$(read_json_value "$manifest_file" '.header.name')
    local is_resource=$(read_json_value "$manifest_file" '.modules[]? | select(.type == "resources") | .type')
    
    if [[ -z "$uuid" ]]; then
        log "${YELLOW}Warning: No UUID found in $manifest_file${NC}"
        return 1
    fi
    
    if [[ -z "$name" ]]; then
        name="addon_$(date +%s | tail -c 6)"
    fi
    
    local pack_type
    local base_dest_dir
    
    if [[ "$is_resource" == "resources" ]]; then
        pack_type="RP"
        base_dest_dir="$MinecraftPath/resource_packs"
    else
        pack_type="BP"
        base_dest_dir="$MinecraftPath/behavior_packs"
    fi
    
    local folder_name=$(generate_folder_name "$name")
    local dest_dir
    local action
    
    if [[ -n "${existing_uuids[$uuid]}" ]]; then
        dest_dir="${existing_uuids[$uuid]}"
        action="UPDATE"
        rm -rf "$dest_dir"
    else
        dest_dir="$base_dest_dir/$folder_name"
        
        local counter=1
        local original_dest="$dest_dir"
        while [[ -d "$dest_dir" ]]; do
            dest_dir="${original_dest}_${counter}"
            ((counter++))
        done
        
        action="INSTALL"
    fi
    
    mkdir -p "$(dirname "$dest_dir")"
    
    if cp -r "$pack_root" "$dest_dir"; then
        apply_permissions "$dest_dir"
        
        log "${GREEN}$action: $(basename "$dest_dir") ($pack_type)${NC}"
        log "${GREEN}  UUID: $uuid${NC}"
        log "${GREEN}  Name: $name${NC}"
        
        if [[ "$pack_type" == "BP" ]]; then
            if [[ "$action" == "INSTALL" ]]; then
                ((bp_installed++))
            else
                ((bp_updated++))
            fi
        else
            if [[ "$action" == "INSTALL" ]]; then
                ((rp_installed++))
            else
                ((rp_updated++))
            fi
        fi
        
        return 0
    else
        log "${RED}Error installing pack: $name${NC}"
        return 1
    fi
}

process_all_packs() {
    log "${YELLOW}=== Processing all addon packs ===${NC}"
    
    local processed_count=0
    local total_count=0
    local failed_count=0
    
    local manifests_found=()
    while IFS= read -r manifest_file; do
        if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
            manifests_found+=("$manifest_file")
        fi
    done < <(find "$TEMP_DIR" -name "manifest.json" -type f 2>/dev/null)
    
    total_count=${#manifests_found[@]}
    
    if [[ $total_count -eq 0 ]]; then
        log "${YELLOW}No manifest.json files found in extracted addons${NC}"
        return
    fi
    
    for manifest_file in "${manifests_found[@]}"; do
        if [[ ! -r "$manifest_file" ]]; then
            log "${RED}Cannot read manifest: $manifest_file${NC}"
            ((failed_count++))
            continue
        fi
        
        local cleaned_json=$(clean_json_content "$manifest_file")
        if [[ -z "$cleaned_json" ]] || ! echo "$cleaned_json" | jq empty 2>/dev/null; then
            if ! jq empty "$manifest_file" 2>/dev/null; then
                log "${RED}Invalid JSON in manifest: $manifest_file${NC}"
                ((failed_count++))
                continue
            fi
        fi
        
        if process_single_pack "$manifest_file"; then
            ((processed_count++))
        else
            ((failed_count++))
        fi
    done
    
    log "${GREEN}=== PACK PROCESSING SUMMARY ===${NC}"
    log "${GREEN}Files processed: $total_count${NC}"
    log "${GREEN}Behavior Packs:${NC}"
    log "${GREEN}  Detected: $((bp_installed + bp_updated))${NC}"
    log "${GREEN}  Installed: $bp_installed${NC}"
    log "${GREEN}  Updated: $bp_updated${NC}"
    log "${GREEN}Resource Packs:${NC}"
    log "${GREEN}  Detected: $((rp_installed + rp_updated))${NC}"
    log "${GREEN}  Installed: $rp_installed${NC}"
    log "${GREEN}  Updated: $rp_updated${NC}"
    if [[ $failed_count -gt 0 ]]; then
        log "${RED}Failed to process: $failed_count${NC}"
    fi
}

extract_mcworld_files() {
    log "${YELLOW}=== Processing .mcworld files ===${NC}"
    
    cd "$AddOnsPath" || exit 1
    
    local mcworld_count=0
    local worlds_dir="$MinecraftPath/$WorldsFolder"
    
    if [[ ! -d "$worlds_dir" ]]; then
        mkdir -p "$worlds_dir"
        log "${BLUE}Creating worlds directory: $worlds_dir${NC}"
    fi
    
    for mcworld in *.mcworld; do
        if [[ ! -f "$mcworld" ]]; then
            continue
        fi
        
        log "${BLUE}Extracting world: $(basename "$mcworld")${NC}"
        
        local temp_world_dir="$TEMP_DIR/world_$(date +%s)_$$"
        mkdir -p "$temp_world_dir"
        
        if unzip -q "$mcworld" -d "$temp_world_dir" 2>/dev/null; then
            local levelname_file=$(find "$temp_world_dir" -name "levelname.txt" -type f 2>/dev/null | head -1)
            local world_name=""
            
            if [[ -f "$levelname_file" ]]; then
                world_name=$(cat "$levelname_file" 2>/dev/null | head -1)
            fi
            
            if [[ -z "$world_name" ]]; then
                world_name=$(basename "$mcworld" .mcworld)
            fi
            
            local folder_name=$(generate_world_folder_name "$world_name")
            local dest_dir="$worlds_dir/$folder_name"
            
            local counter=1
            local original_dest="$dest_dir"
            while [[ -d "$dest_dir" ]]; do
                dest_dir="${original_dest}_${counter}"
                ((counter++))
            done
            
            if mv "$temp_world_dir" "$dest_dir"; then
                apply_permissions "$dest_dir"
                rm "$mcworld"
                
                log "${GREEN}World installed: $(basename "$dest_dir")${NC}"
                log "${GREEN}  Name: $world_name${NC}"
                log "${GREEN}  Location: $dest_dir${NC}"
                
                ((mcworld_count++))
            else
                log "${RED}Error moving world: $(basename "$mcworld")${NC}"
                rm -rf "$temp_world_dir"
            fi
        else
            log "${RED}Error extracting world: $(basename "$mcworld")${NC}"
            rm -rf "$temp_world_dir"
        fi
    done
    
    log "${GREEN}Total .mcworld processed: $mcworld_count${NC}"
}

main() {
    initialize
    map_existing_uuids
    extract_all_compressed
    extract_nested_compressed
    process_all_packs
    extract_mcworld_files
    
    log "${BLUE}=== Process completed ===${NC}"
    log "${BLUE}Log: $(basename "$LOG_FILE")${NC}"
}

main "$@"
