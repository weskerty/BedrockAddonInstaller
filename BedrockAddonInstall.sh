#!/bin/bash

# Config
#Ubicacion del Juego o Server
MinecraftPath="C:\Users\Admin\AppData\Local\Packages\Microsoft.MinecraftUWP_8wekyb3d8bbwe\LocalState\games\com.mojang"

#Ubicacion de los AddOns
AddOnsPath="D:\Usuarios\mr\Descargas\AddOns"

#Nombre de la Carpeta de Mundos
WorldsFolder="minecraftWorlds"

#Por si Falle la Deteccion de Versiones
CHECK_VERSIONS=true





A1="=== Minecraft AddOn Installer/Updater ==="
A2="System:"
A3="MinecraftPath:"
A4="AddOnsPath:"
A5="TempDir:"
A6="Error: Missing dependencies:"
A7="Install missing dependencies from package manager"
A8="Error: MinecraftPath does not exist:"
A9="Error: AddOnsPath does not exist:"
A10="=== Mapping existing UUIDs ==="
A11="# Pack Registry -"
A12="# TYPE|UUID|NAME|FOLDER|PATH"
A13="# Unidentified Packs -"
A14="# TYPE|FOLDER|REASON|PATH"
A15="BP Missing manifest:"
A16="BP Missing UUID:"
A17="RP Missing manifest:"
A18="RP Missing UUID:"
A19="Behavior Packs:"
A20="Resource Packs:"
A21="Unidentified packs: BP="
A22="Details saved to:"
A23="=== Extracting compressed files ==="
A24="Extracted:"
A25="Error extracting:"
A26="Extracted - MCAddons:"
A27="MCPacks:"
A28="Zips:"
A29="=== Extracting nested files ==="
A30="Nested extraction completed in"
A31="rounds"
A32="FAILED: No UUID in"
A33="FAILED: Error copying pack:"
A34="FAILED: Copy error for"
A35="=== Processing addon packs ==="
A36="No manifest.json files found"
A37="=== PACK SUMMARY ==="
A38="Processed:"
A39="BP - Installed:"
A40="Updated:"
A41="RP - Installed:"
A42="Failed:"
A43="=== Processing .mcworld files ==="
A44="World installed:"
A45="Error moving world:"
A46="Error extracting world:"
A47="Worlds processed:"
A48="=== Process completed ==="
A49="Log:"
A50="INSTALL:"
A51="UPDATE:"
A52="SKIP: Lower version"
A53="Version check:"
A54="current"
A55="new"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE=""
TEMP_DIR=""
declare -g -A existing_uuids
declare -g -A existing_versions

declare -g bp_detected=0 bp_folders=0 rp_detected=0 rp_folders=0
declare -g mcpacks_extracted=0 mcaddons_extracted=0 zips_extracted=0
declare -g bp_installed=0 bp_updated=0 rp_installed=0 rp_updated=0
declare -g bp_skipped=0 rp_skipped=0

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
        log "${RED}$A6 ${missing_deps[*]}${NC}"
        log "${YELLOW}$A7${NC}"
        exit 1
    fi
}

cleanup_temp() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null
}


###################################

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
        gsub(/\r/, "", content)
        gsub(/\t/, "    ", content)
        gsub(/\n[ \t]*\n/, "\n", content)
        
        print content
    }
    ' "$json_file"
}

#######################################

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


#############

parse_version() {
    local version_array="$1"
    
    if [[ "$version_array" == "null" || "$version_array" == "" ]]; then
        echo "0.0.0"
        return
    fi
    
    local major=$(echo "$version_array" | jq -r '.[0] // 0' 2>/dev/null)
    local minor=$(echo "$version_array" | jq -r '.[1] // 0' 2>/dev/null)
    local patch=$(echo "$version_array" | jq -r '.[2] // 0' 2>/dev/null)
    
    echo "${major}.${minor}.${patch}"
}

compare_versions() {
    local v1="$1"
    local v2="$2"
    
    local v1_major=$(echo "$v1" | cut -d. -f1)
    local v1_minor=$(echo "$v1" | cut -d. -f2)
    local v1_patch=$(echo "$v1" | cut -d. -f3)
    
    local v2_major=$(echo "$v2" | cut -d. -f1)
    local v2_minor=$(echo "$v2" | cut -d. -f2)
    local v2_patch=$(echo "$v2" | cut -d. -f3)
    
    if [[ $v1_major -gt $v2_major ]]; then
        echo 1
    elif [[ $v1_major -lt $v2_major ]]; then
        echo -1
    elif [[ $v1_minor -gt $v2_minor ]]; then
        echo 1
    elif [[ $v1_minor -lt $v2_minor ]]; then
        echo -1
    elif [[ $v1_patch -gt $v2_patch ]]; then
        echo 1
    elif [[ $v1_patch -lt $v2_patch ]]; then
        echo -1
    else
        echo 0
    fi
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
    
    log "${BLUE}$A1${NC}"
    log "${BLUE}$A2 $os_type | $A3 $MinecraftPath${NC}"
    log "${BLUE}$A4 $AddOnsPath | $A5 $TEMP_DIR${NC}"
    
    check_dependencies
    
    [[ ! -d "$MinecraftPath" ]] && { log "${RED}$A8 $MinecraftPath${NC}"; exit 1; }
    [[ ! -d "$AddOnsPath" ]] && { log "${RED}$A9 $AddOnsPath${NC}"; exit 1; }
    
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
    log "${YELLOW}$A10${NC}"
    
    local registry_file="$AddOnsPath/installed_packs_registry.txt"
    local unidentified_file="$AddOnsPath/unidentified_packs.txt"
    
    {
        echo "# $A11 $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# $A12"
    } > "$registry_file"
    
    {
        echo "# $A13 $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# $A14"
    } > "$unidentified_file"
    
    if [[ -d "$MinecraftPath/behavior_packs" ]]; then
        for pack_dir in "$MinecraftPath/behavior_packs"/*; do
            [[ ! -d "$pack_dir" ]] && continue
            ((bp_folders++))
            
            local manifests=($(find_manifest_recursive "$pack_dir"))
            
            if [[ ${#manifests[@]} -eq 0 ]]; then
                echo "BP|$(basename "$pack_dir")|NO_MANIFEST|$pack_dir" >> "$unidentified_file"
                log "${YELLOW}$A15 $(basename "$pack_dir")${NC}"
                continue
            fi
            
            local found_valid=false
            for manifest in "${manifests[@]}"; do
                local uuid=$(read_json_value "$manifest" '.header.uuid')
                local name=$(read_json_value "$manifest" '.header.name')
                local version_array=$(read_json_value "$manifest" '.header.version')
                local version=$(parse_version "$version_array")
                
                if [[ -n "$uuid" ]]; then
                    existing_uuids["$uuid"]="$(dirname "$manifest")"
                    existing_versions["$uuid"]="$version"
                    local short_name=$(generate_folder_name "$name")
                    echo "BP|$uuid|$short_name|$(basename "$pack_dir")|$(dirname "$manifest")|$version" >> "$registry_file"
                    ((bp_detected++))
                    found_valid=true
                    break
                fi
            done
            
            if [[ "$found_valid" == false ]]; then
                echo "BP|$(basename "$pack_dir")|NO_UUID|$pack_dir" >> "$unidentified_file"
                log "${YELLOW}$A16 $(basename "$pack_dir")${NC}"
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
                log "${YELLOW}$A17 $(basename "$pack_dir")${NC}"
                continue
            fi
            
            local found_valid=false
            for manifest in "${manifests[@]}"; do
                local uuid=$(read_json_value "$manifest" '.header.uuid')
                local name=$(read_json_value "$manifest" '.header.name')
                local version_array=$(read_json_value "$manifest" '.header.version')
                local version=$(parse_version "$version_array")
                
                if [[ -n "$uuid" ]]; then
                    existing_uuids["$uuid"]="$(dirname "$manifest")"
                    existing_versions["$uuid"]="$version"
                    local short_name=$(generate_folder_name "$name")
                    echo "RP|$uuid|$short_name|$(basename "$pack_dir")|$(dirname "$manifest")|$version" >> "$registry_file"
                    ((rp_detected++))
                    found_valid=true
                    break
                fi
            done
            
            if [[ "$found_valid" == false ]]; then
                echo "RP|$(basename "$pack_dir")|NO_UUID|$pack_dir" >> "$unidentified_file"
                log "${YELLOW}$A18 $(basename "$pack_dir")${NC}"
            fi
        done
    fi
    
    log "${GREEN}$A19 $bp_detected/$bp_folders | $A20 $rp_detected/$rp_folders${NC}"
    
    local bp_missing=$((bp_folders - bp_detected))
    local rp_missing=$((rp_folders - rp_detected))
    
    if [[ $bp_missing -gt 0 || $rp_missing -gt 0 ]]; then
        log "${YELLOW}$A21$bp_missing, RP=$rp_missing${NC}"
        log "${YELLOW}$A22 $(basename "$unidentified_file")${NC}"
    fi
}

extract_all_compressed() {
    log "${YELLOW}$A23${NC}"
    
    cd "$AddOnsPath" || exit 1
    
    for file in *.mcaddon *.mcpack *.zip; do
        [[ ! -f "$file" ]] && continue
        
        local base_name=$(basename "$file" | sed 's/\.[^.]*$//')
        local extract_dir="$TEMP_DIR/$base_name"
        local extension="${file##*.}"
        
        mkdir -p "$extract_dir"
        
        if unzip -q "$file" -d "$extract_dir" 2>/dev/null; then
            log "${GREEN}$A24 $(basename "$file")${NC}"
            rm "$file"
            
            case "$extension" in
                "mcaddon") ((mcaddons_extracted++)) ;;
                "mcpack") ((mcpacks_extracted++)) ;;
                "zip") ((zips_extracted++)) ;;
            esac
        else
            log "${RED}$A25 $(basename "$file")${NC}"
            rmdir "$extract_dir" 2>/dev/null
        fi
    done
    
    log "${GREEN}$A26 $mcaddons_extracted | $A27 $mcpacks_extracted | $A28 $zips_extracted${NC}"
}

extract_nested_compressed() {
    log "${YELLOW}$A29${NC}"
    
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
    
    log "${GREEN}$A30 $rounds $A31${NC}"
}

process_single_pack() {
    local manifest_file="$1"
    local pack_root=$(dirname "$manifest_file")
    
    local uuid=$(read_json_value "$manifest_file" '.header.uuid')
    local name=$(read_json_value "$manifest_file" '.header.name')
    local is_resource=$(read_json_value "$manifest_file" '.modules[]? | select(.type == "resources") | .type')
    local version_array=$(read_json_value "$manifest_file" '.header.version')
    local new_version=$(parse_version "$version_array")
    
    if [[ -z "$uuid" ]]; then
        log "${RED}$A32 $(basename "$manifest_file")${NC}"
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
    local dest_dir action should_install=true
    
    if [[ -n "${existing_uuids[$uuid]}" ]]; then
        dest_dir="${existing_uuids[$uuid]}"
        action="UPDATE"
        
        if [[ "$CHECK_VERSIONS" == "true" ]]; then
            local current_version="${existing_versions[$uuid]}"
            local version_comparison=$(compare_versions "$new_version" "$current_version")
            
            log "${BLUE}$A53 $A54 $current_version -> $A55 $new_version${NC}"
            
            if [[ $version_comparison -lt 0 ]]; then
                log "${YELLOW}$A52 $name ($new_version < $current_version)${NC}"
                should_install=false
                
                if [[ "$pack_type" == "BP" ]]; then
                    ((bp_skipped++))
                else
                    ((rp_skipped++))
                fi
            fi
        fi
        
        [[ "$should_install" == "true" ]] && rm -rf "$dest_dir"
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
    
    if [[ "$should_install" == "false" ]]; then
        return 0
    fi
    
    mkdir -p "$(dirname "$dest_dir")"
    
    if cp -r "$pack_root" "$dest_dir"; then
        apply_permissions "$dest_dir"
        
        log "${GREEN}$A50 $(basename "$dest_dir") ($pack_type) - $name [$new_version]${NC}" 
        
        if [[ "$pack_type" == "BP" ]]; then
            [[ "$action" == "INSTALL" ]] && ((bp_installed++)) || ((bp_updated++))
        else
            [[ "$action" == "INSTALL" ]] && ((rp_installed++)) || ((rp_updated++))
        fi
        
        return 0
    else
        log "${RED}$A33 $name${NC}"
        echo "FAILED|COPY_ERROR|$(basename "$pack_root")|$pack_root|$dest_dir" >> "$AddOnsPath/installation_failures.txt"
        return 1
    fi
}

process_all_packs() {
    log "${YELLOW}$A35${NC}"
    
    local processed_count=0 failed_count=0
    local manifests_found=()
    
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" && -f "$manifest_file" ]] && manifests_found+=("$manifest_file")
    done < <(find "$TEMP_DIR" -name "manifest.json" -type f 2>/dev/null)
    
    local total_count=${#manifests_found[@]}
    
    if [[ $total_count -eq 0 ]]; then
        log "${YELLOW}$A36${NC}"
        return
    fi
    
    for manifest_file in "${manifests_found[@]}"; do
        if process_single_pack "$manifest_file"; then
            ((processed_count++))
        else
            ((failed_count++))
        fi
    done
    
    log "${GREEN}$A37${NC}"
    log "${GREEN}$A38 $processed_count/$total_count${NC}"
    log "${GREEN}$A39 $bp_installed | $A40 $bp_updated${NC}"
    log "${GREEN}$A41 $rp_installed | $A40 $rp_updated${NC}"
    
    if [[ $bp_skipped -gt 0 || $rp_skipped -gt 0 ]]; then
        log "${YELLOW}Skipped: BP=$bp_skipped | RP=$rp_skipped${NC}"
    fi
    
    [[ $failed_count -gt 0 ]] && log "${RED}$A42 $failed_count${NC}"
}

extract_mcworld_files() {
    log "${YELLOW}$A43${NC}"
    
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
                
                log "${GREEN}$A44 $(basename "$dest_dir") - $world_name${NC}"
                ((mcworld_count++))
            else
                log "${RED}$A45 $(basename "$mcworld")${NC}"
                rm -rf "$temp_world_dir"
            fi
        else
            log "${RED}$A46 $(basename "$mcworld")${NC}"
            rm -rf "$temp_world_dir"
        fi
    done
    
    log "${GREEN}$A47 $mcworld_count${NC}"
}

main() {
    initialize
    map_existing_uuids
    extract_all_compressed
    extract_nested_compressed
    process_all_packs
    extract_mcworld_files
    
    log "${BLUE}$A48${NC}"
    log "${BLUE}$A49 $(basename "$LOG_FILE")${NC}"
}

main "$@"
