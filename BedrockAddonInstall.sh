#!/bin/bash

# Config
#Ubicacion del Juego o Server
MinecraftPath="C:\Users\Admin\AppData\Local\Packages\Microsoft.MinecraftUWP_8wekyb3d8bbwe\LocalState\games\com.mojang"

#Ubicacion de los AddOns
AddOnsPath="D:\Usuarios\mr\Descargas\AddOns"

#Nombre de la Carpeta de Mundos
WorldsFolder="minecraftWorlds"

































###############################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE=""
TEMP_DIR=""
declare -g -A existing_uuids

declare -g bp_detected=0 bp_folders=0 rp_detected=0 rp_folders=0
declare -g mcpacks_extracted=0 mcaddons_extracted=0 zips_extracted=0
declare -g bp_installed=0 bp_updated=0 rp_installed=0 rp_updated=0

detect_os() {
    [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]] && echo "windows" || echo "linux"
}

normalize_path() {
    local path="$1"
    [[ "$(detect_os)" == "windows" ]] && echo "$path" | sed 's|\\|/|g' || echo "$path"
}

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "$message"
    
    local clean_message=$(echo "$message" | sed 's/\x1b\[[0-9;]*m//g')
    [[ ${#clean_message} -gt 100 ]] && clean_message="${clean_message:0:97}..."
    
    echo "$timestamp - $clean_message" >> "$LOG_FILE"
}

check_dependencies() {
    local missing_deps=()
    
    command -v jq &> /dev/null || missing_deps+=("jq")
    command -v unzip &> /dev/null || missing_deps+=("unzip")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "${RED}Error: Missing dependencies: ${missing_deps[*]}${NC}"
        log "${YELLOW}Install missing dependencies from package manager${NC}"
        exit 1
    fi
}

cleanup_temp() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null
}

clean_json_in_memory() {
    local json_file="$1"
    
    awk '
    {
        line = $0
        result = ""
        in_string = 0
        escaped = 0
        i = 1
        
        while (i <= length(line)) {
            char = substr(line, i, 1)
            
            if (escaped) {
                result = result char
                escaped = 0
                i++
                continue
            }
            
            if (char == "\\") {
                escaped = 1
                result = result char
                i++
                continue
            }
            
            if (char == "\"") {
                in_string = !in_string
                result = result char
                i++
                continue
            }
            
            if (!in_string && char == "/" && i < length(line) && substr(line, i+1, 1) == "/") {
                # Found comment outside string, ignore rest of line
                break
            }
            
            result = result char
            i++
        }
        
        content = content result "\n"
    }
    END {
        result = ""
        in_string = 0
        escaped = 0
        i = 1
        
        while (i <= length(content)) {
            char = substr(content, i, 1)
            
            if (escaped) {
                result = result char
                escaped = 0
                i++
                continue
            }
            
            if (char == "\\") {
                escaped = 1
                result = result char
                i++
                continue
            }
            
            if (char == "\"") {
                in_string = !in_string
                result = result char
                i++
                continue
            }
            
            if (!in_string && char == "/" && i < length(content) && substr(content, i+1, 1) == "*") {
                # Found start of multi-line comment, skip until */
                i += 2
                while (i <= length(content)) {
                    if (substr(content, i, 1) == "*" && i < length(content) && substr(content, i+1, 1) == "/") {
                        i += 2
                        break
                    }
                    i++
                }
                continue
            }
            
            result = result char
            i++
        }
        
        content = result
        
        gsub(/,[ \t\n\r]*([}\]])/, "\\1", content)
        
        # Remove empty lines and normalize whitespace
        gsub(/\r/, "", content)
        gsub(/\t/, "    ", content)
        gsub(/\n[ \t]*\n/, "\n", content)
        
        print content
    }
    ' "$json_file"
}

read_json_value() {
    local json_file="$1"
    local key_path="$2"
    
    [[ ! -f "$json_file" ]] && return 1
    
    local value=$(jq -r "$key_path // empty" "$json_file" 2>/dev/null)
    
    if [[ "$value" == "null" || "$value" == "" ]]; then
        local cleaned_content=$(clean_json_in_memory "$json_file")
        if [[ -n "$cleaned_content" ]]; then
            value=$(echo "$cleaned_content" | jq -r "$key_path // empty" 2>/dev/null)
        fi
    fi
    
    [[ "$value" == "null" || "$value" == "" ]] && return 1
    
    echo "$value"
}

generate_folder_name() {
    local name="$1"
    local clean_name=$(echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g')
    [[ -z "$clean_name" ]] && clean_name="addon_$(date +%s | tail -c 6)"
    echo "$clean_name"
}

apply_permissions() {
    local target_path="$1"
    
    if [[ "$(detect_os)" == "linux" && -e "$target_path" ]]; then
        [[ -n "$minecraft_owner" && -n "$minecraft_group" ]] && chown -R "$minecraft_owner:$minecraft_group" "$target_path" 2>/dev/null
        [[ -n "$minecraft_perms" ]] && chmod -R "$minecraft_perms" "$target_path" 2>/dev/null
    fi
}

find_manifest_recursive() {
    local base_dir="$1"
    local max_depth=2
    
    find "$base_dir" -maxdepth $max_depth -name "manifest.json" -type f 2>/dev/null
}

initialize() {
    local os_type=$(detect_os)
    
    MinecraftPath=$(normalize_path "$MinecraftPath")
    AddOnsPath=$(normalize_path "$AddOnsPath")
    TEMP_DIR="$AddOnsPath/Temp"
    LOG_FILE="$AddOnsPath/addon-updater.log"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Minecraft AddOn Installer/Updater Started ($os_type)" > "$LOG_FILE"
    
    log "${BLUE}=== Minecraft AddOn Installer/Updater ===${NC}"
    log "${BLUE}System: $os_type | MinecraftPath: $MinecraftPath${NC}"
    log "${BLUE}AddOnsPath: $AddOnsPath | TempDir: $TEMP_DIR${NC}"
    
    check_dependencies
    
    [[ ! -d "$MinecraftPath" ]] && { log "${RED}Error: MinecraftPath does not exist: $MinecraftPath${NC}"; exit 1; }
    [[ ! -d "$AddOnsPath" ]] && { log "${RED}Error: AddOnsPath does not exist: $AddOnsPath${NC}"; exit 1; }
    
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    if [[ "$os_type" == "linux" ]]; then
        minecraft_owner=$(stat -c "%U" "$MinecraftPath" 2>/dev/null)
        minecraft_group=$(stat -c "%G" "$MinecraftPath" 2>/dev/null)
        minecraft_perms=$(stat -c "%a" "$MinecraftPath" 2>/dev/null)
    fi
    
    trap cleanup_temp EXIT
}

map_existing_uuids() {
    log "${YELLOW}=== Mapping existing UUIDs ===${NC}"
    
    local registry_file="$AddOnsPath/installed_packs_registry.txt"
    local unidentified_file="$AddOnsPath/unidentified_packs.txt"
    
    {
        echo "# Pack Registry - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# TYPE|UUID|NAME|FOLDER|PATH"
    } > "$registry_file"
    
    {
        echo "# Unidentified Packs - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# TYPE|FOLDER|REASON|PATH"
    } > "$unidentified_file"
    
    if [[ -d "$MinecraftPath/behavior_packs" ]]; then
        for pack_dir in "$MinecraftPath/behavior_packs"/*; do
            [[ ! -d "$pack_dir" ]] && continue
            ((bp_folders++))
            
            local manifests=($(find_manifest_recursive "$pack_dir"))
            
            if [[ ${#manifests[@]} -eq 0 ]]; then
                echo "BP|$(basename "$pack_dir")|NO_MANIFEST|$pack_dir" >> "$unidentified_file"
                log "${YELLOW}BP Missing manifest: $(basename "$pack_dir")${NC}"
                continue
            fi
            
            local found_valid=false
            for manifest in "${manifests[@]}"; do
                local uuid=$(read_json_value "$manifest" '.header.uuid')
                local name=$(read_json_value "$manifest" '.header.name')
                
                if [[ -n "$uuid" ]]; then
                    existing_uuids["$uuid"]="$(dirname "$manifest")"
                    local short_name=$(generate_folder_name "$name")
                    echo "BP|$uuid|$short_name|$(basename "$pack_dir")|$(dirname "$manifest")" >> "$registry_file"
                    ((bp_detected++))
                    found_valid=true
                    break
                fi
            done
            
            if [[ "$found_valid" == false ]]; then
                echo "BP|$(basename "$pack_dir")|NO_UUID|$pack_dir" >> "$unidentified_file"
                log "${YELLOW}BP Missing UUID: $(basename "$pack_dir")${NC}"
            fi
        done
    fi
    
    if [[ -d "$MinecraftPath/resource_packs" ]]; then
        for pack_dir in "$MinecraftPath/resource_packs"/*; do
            [[ ! -d "$pack_dir" ]] && continue
            ((rp_folders++))
            
            local manifests=($(find_manifest_recursive "$pack_dir"))
            
            if [[ ${#manifests[@]} -eq 0 ]]; then
                echo "RP|$(basename "$pack_dir")|NO_MANIFEST|$pack_dir" >> "$unidentified_file"
                log "${YELLOW}RP Missing manifest: $(basename "$pack_dir")${NC}"
                continue
            fi
            
            local found_valid=false
            for manifest in "${manifests[@]}"; do
                local uuid=$(read_json_value "$manifest" '.header.uuid')
                local name=$(read_json_value "$manifest" '.header.name')
                
                if [[ -n "$uuid" ]]; then
                    existing_uuids["$uuid"]="$(dirname "$manifest")"
                    local short_name=$(generate_folder_name "$name")
                    echo "RP|$uuid|$short_name|$(basename "$pack_dir")|$(dirname "$manifest")" >> "$registry_file"
                    ((rp_detected++))
                    found_valid=true
                    break
                fi
            done
            
            if [[ "$found_valid" == false ]]; then
                echo "RP|$(basename "$pack_dir")|NO_UUID|$pack_dir" >> "$unidentified_file"
                log "${YELLOW}RP Missing UUID: $(basename "$pack_dir")${NC}"
            fi
        done
    fi
    
    log "${GREEN}Behavior Packs: $bp_detected/$bp_folders | Resource Packs: $rp_detected/$rp_folders${NC}"
    
    local bp_missing=$((bp_folders - bp_detected))
    local rp_missing=$((rp_folders - rp_detected))
    
    if [[ $bp_missing -gt 0 || $rp_missing -gt 0 ]]; then
        log "${YELLOW}Unidentified packs: BP=$bp_missing, RP=$rp_missing${NC}"
        log "${YELLOW}Details saved to: $(basename "$unidentified_file")${NC}"
    fi
}

extract_all_compressed() {
    log "${YELLOW}=== Extracting compressed files ===${NC}"
    
    cd "$AddOnsPath" || exit 1
    
    for file in *.mcaddon *.mcpack *.zip; do
        [[ ! -f "$file" ]] && continue
        
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
            rmdir "$extract_dir" 2>/dev/null
        fi
    done
    
    log "${GREEN}Extracted - MCAddons: $mcaddons_extracted | MCPacks: $mcpacks_extracted | Zips: $zips_extracted${NC}"
}

extract_nested_compressed() {
    log "${YELLOW}=== Extracting nested files ===${NC}"
    
    local rounds=0
    local max_rounds=5
    
    while [[ $rounds -lt $max_rounds ]]; do
        local found_compressed=false
        ((rounds++))
        
        while IFS= read -r -d '' compressed_file; do
            found_compressed=true
            local dir_path=$(dirname "$compressed_file")
            local base_name=$(basename "$compressed_file" | sed 's/\.[^.]*$//')
            local extract_dir="$dir_path/$base_name"
            
            mkdir -p "$extract_dir"
            
            if unzip -q "$compressed_file" -d "$extract_dir" 2>/dev/null; then
                rm "$compressed_file"
            else
                rmdir "$extract_dir" 2>/dev/null
            fi
        done < <(find "$TEMP_DIR" -name "*.zip" -o -name "*.mcpack" -o -name "*.mcaddon" -type f -print0 2>/dev/null)
        
        [[ "$found_compressed" == false ]] && break
    done
    
    log "${GREEN}Nested extraction completed in $rounds rounds${NC}"
}

process_single_pack() {
    local manifest_file="$1"
    local pack_root=$(dirname "$manifest_file")
    
    local uuid=$(read_json_value "$manifest_file" '.header.uuid')
    local name=$(read_json_value "$manifest_file" '.header.name')
    local is_resource=$(read_json_value "$manifest_file" '.modules[]? | select(.type == "resources") | .type')
    
    if [[ -z "$uuid" ]]; then
        log "${RED}FAILED: No UUID in $(basename "$manifest_file")${NC}"
        echo "FAILED|NO_UUID|$(basename "$pack_root")|$pack_root" >> "$AddOnsPath/installation_failures.txt"
        return 1
    fi
    
    [[ -z "$name" ]] && name="addon_$(date +%s | tail -c 6)"
    
    local pack_type base_dest_dir
    if [[ "$is_resource" == "resources" ]]; then
        pack_type="RP"
        base_dest_dir="$MinecraftPath/resource_packs"
    else
        pack_type="BP"
        base_dest_dir="$MinecraftPath/behavior_packs"
    fi
    
    local folder_name=$(generate_folder_name "$name")
    local dest_dir action
    
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
        
        log "${GREEN}$action: $(basename "$dest_dir") ($pack_type) - $name${NC}"
        
        if [[ "$pack_type" == "BP" ]]; then
            [[ "$action" == "INSTALL" ]] && ((bp_installed++)) || ((bp_updated++))
        else
            [[ "$action" == "INSTALL" ]] && ((rp_installed++)) || ((rp_updated++))
        fi
        
        return 0
    else
        log "${RED}FAILED: Error copying pack: $name${NC}"
        echo "FAILED|COPY_ERROR|$(basename "$pack_root")|$pack_root|$dest_dir" >> "$AddOnsPath/installation_failures.txt"
        return 1
    fi
}

process_all_packs() {
    log "${YELLOW}=== Processing addon packs ===${NC}"
    
    local processed_count=0 failed_count=0
    local manifests_found=()
    
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" && -f "$manifest_file" ]] && manifests_found+=("$manifest_file")
    done < <(find "$TEMP_DIR" -name "manifest.json" -type f 2>/dev/null)
    
    local total_count=${#manifests_found[@]}
    
    if [[ $total_count -eq 0 ]]; then
        log "${YELLOW}No manifest.json files found${NC}"
        return
    fi
    
    for manifest_file in "${manifests_found[@]}"; do
        if process_single_pack "$manifest_file"; then
            ((processed_count++))
        else
            ((failed_count++))
        fi
    done
    
    log "${GREEN}=== PACK SUMMARY ===${NC}"
    log "${GREEN}Processed: $processed_count/$total_count${NC}"
    log "${GREEN}BP - Installed: $bp_installed | Updated: $bp_updated${NC}"
    log "${GREEN}RP - Installed: $rp_installed | Updated: $rp_updated${NC}"
    [[ $failed_count -gt 0 ]] && log "${RED}Failed: $failed_count${NC}"
}

extract_mcworld_files() {
    log "${YELLOW}=== Processing .mcworld files ===${NC}"
    
    cd "$AddOnsPath" || exit 1
    
    local mcworld_count=0
    local worlds_dir="$MinecraftPath/$WorldsFolder"
    
    [[ ! -d "$worlds_dir" ]] && mkdir -p "$worlds_dir"
    
    for mcworld in *.mcworld; do
        [[ ! -f "$mcworld" ]] && continue
        
        local temp_world_dir="$TEMP_DIR/world_$(date +%s)_$$"
        mkdir -p "$temp_world_dir"
        
        if unzip -q "$mcworld" -d "$temp_world_dir" 2>/dev/null; then
            local world_name=""
            local levelname_file=$(find "$temp_world_dir" -name "levelname.txt" -type f 2>/dev/null | head -1)
            
            [[ -f "$levelname_file" ]] && world_name=$(cat "$levelname_file" 2>/dev/null | head -1)
            [[ -z "$world_name" ]] && world_name=$(basename "$mcworld" .mcworld)
            
            local folder_name=$(generate_folder_name "$world_name")
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
                
                log "${GREEN}World installed: $(basename "$dest_dir") - $world_name${NC}"
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
    
    log "${GREEN}Worlds processed: $mcworld_count${NC}"
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
