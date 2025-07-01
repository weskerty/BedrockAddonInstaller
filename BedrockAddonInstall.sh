#!/bin/bash


# Config
# Ubicacion donde existan las carpetas resource_packs y behavior_packs
MinecraftPath="/opt/minecraft-bedrock-server" 

# Ubicacion de los nuevos AddOns.
AddOnsPath="Descargas/AddOns"


UUID="True"













































RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


LOG_FILE=""
TEMP_COUNTER=0


# Detectar sistema 
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
        # Convertir barras MinGW # No es necesario
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
    
    # Truncar 
    if [[ ${#clean_message} -gt 100 ]]; then
        clean_message="${clean_message:0:97}..."
    fi
    
    echo "$timestamp - $clean_message" >> "$LOG_FILE"
}

# dependencias
check_dependencies() {
    local missing_deps=()
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v unzip &> /dev/null; then
        missing_deps+=("unzip")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "${RED}Error: Dependencias faltantes: ${missing_deps[*]}${NC}"
        log "${YELLOW}Instala las dependencias faltantes:${NC}"
        log "${YELLOW}  - Windows/MinGW: desde Chocolatey o Winget ${NC}"
        exit 1
    fi
}

# directorio temporal 
create_temp_dir() {
    TEMP_COUNTER=$((TEMP_COUNTER + 1))
    local temp_name="temp_${$}_${TEMP_COUNTER}_$(date +%s)"
    echo "$temp_name"
}

# temporal
cleanup_temp() {
    local temp_dir="$1"
    if [[ -d "$temp_dir" ]]; then
        rm -rf "$temp_dir" 2>/dev/null || true
    fi
}

# Leer JSON 
read_json_value() {
    local json_file="$1"
    local key_path="$2"
    
    if [[ ! -f "$json_file" ]]; then
        echo ""
        return
    fi
    
    local value=$(jq -r "$key_path // empty" "$json_file" 2>/dev/null || echo "")
    
    if [[ "$value" == "null" || "$value" == "" ]]; then
        echo ""
    else
        echo "$value"
    fi
}

# nombre de carpeta 11 caracteres
generate_folder_name() {
    local name="$1"
    
    # Limpiar caracteres especiales
    local clean_name=$(echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    if [[ ${#clean_name} -gt 11 ]]; then
        clean_name="${clean_name:0:11}"
    fi
    
    if [[ -z "$clean_name" ]]; then
        clean_name="addon_$(date +%s | tail -c 6)"
    fi
    
    echo "$clean_name"
}

# permisos Linux
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
        log "${GREEN}Permisos aplicados a: $(basename "$target_path")${NC}"
    fi
}

initialize() {
    local os_type=$(detect_os)
    
    MinecraftPath=$(normalize_path "$MinecraftPath")
    AddOnsPath=$(normalize_path "$AddOnsPath")
    
    LOG_FILE="$AddOnsPath/addon-updater.log"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Minecraft AddOn Installer/Updater Started ($os_type)" > "$LOG_FILE"
    
    log "${BLUE}=== Minecraft AddOn Installer/Updater ===${NC}"
    log "${BLUE}Sistema: $os_type${NC}"
    log "${BLUE}MinecraftPath: $MinecraftPath${NC}"
    log "${BLUE}AddOnsPath: $AddOnsPath${NC}"
    
    check_dependencies
    
    if [[ ! -d "$MinecraftPath" ]]; then
        log "${RED}Error: MinecraftPath no existe: $MinecraftPath${NC}"
        exit 1
    fi
    
    if [[ ! -d "$AddOnsPath" ]]; then
        log "${RED}Error: AddOnsPath no existe: $AddOnsPath${NC}"
        exit 1
    fi
    
    # Obtener de permisos Linux
    if [[ "$os_type" == "linux" ]]; then
        minecraft_owner=$(stat -c "%U" "$MinecraftPath" 2>/dev/null || echo "")
        minecraft_group=$(stat -c "%G" "$MinecraftPath" 2>/dev/null || echo "")
        minecraft_perms=$(stat -c "%a" "$MinecraftPath" 2>/dev/null || echo "")
        if [[ -n "$minecraft_owner" ]]; then
            log "${BLUE}Propietario: $minecraft_owner:$minecraft_group ($minecraft_perms)${NC}"
        fi
    fi
}

# Extraer 
extract_mcaddon_files() {
    log "${YELLOW}=== Paso 1: Extrayendo archivos .mcaddon ===${NC}"
    
    cd "$AddOnsPath" || exit 1
    
    local mcaddon_count=0
    
    for mcaddon in *.mcaddon; do
        if [[ ! -f "$mcaddon" ]]; then
            continue
        fi
        
        log "${BLUE}Extrayendo: $(basename "$mcaddon")${NC}"
        
        local temp_dir=$(create_temp_dir)
        
        if unzip -q "$mcaddon" -d "$temp_dir" 2>/dev/null; then

            find "$temp_dir" -name "*.mcpack" -exec mv {} . \; 2>/dev/null || true
            
            cleanup_temp "$temp_dir"
            rm "$mcaddon"
            ((mcaddon_count++))
            
            log "${GREEN}✓ Procesado: $(basename "$mcaddon")${NC}"
        else
            log "${RED}✗ Error al extraer: $(basename "$mcaddon")${NC}"
            cleanup_temp "$temp_dir"
        fi
    done
    
    log "${GREEN}Total .mcaddon procesados: $mcaddon_count${NC}"
}

map_existing_uuids() {
    log "${YELLOW}=== Paso 2: Mapeando UUIDs existentes ===${NC}"
    
    declare -g -A existing_uuids
    local registry_file="$AddOnsPath/installed_packs_registry.txt"
    
    {
        echo "# Registro de Packs - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# TIPO|UUID|NOMBRE|CARPETA|RUTA"
    } > "$registry_file"
    
    local total_mapped=0
    
    if [[ -d "$MinecraftPath/behavior_packs" ]]; then
        for pack_dir in "$MinecraftPath/behavior_packs"/*; do
            if [[ -d "$pack_dir" && -f "$pack_dir/manifest.json" ]]; then
                local uuid=$(read_json_value "$pack_dir/manifest.json" '.header.uuid')
                local name=$(read_json_value "$pack_dir/manifest.json" '.header.name')
                
                if [[ -n "$uuid" ]]; then
                    existing_uuids["$uuid"]="$pack_dir"
                    local short_name=$(generate_folder_name "$name")
                    echo "BP|$uuid|$short_name|$(basename "$pack_dir")|$pack_dir" >> "$registry_file"
                    log "${BLUE}UUID mapeado (BP): $uuid -> $(basename "$pack_dir")${NC}"
                    ((total_mapped++))
                fi
            fi
        done
    fi
    
    if [[ -d "$MinecraftPath/resource_packs" ]]; then
        for pack_dir in "$MinecraftPath/resource_packs"/*; do
            if [[ -d "$pack_dir" && -f "$pack_dir/manifest.json" ]]; then
                local uuid=$(read_json_value "$pack_dir/manifest.json" '.header.uuid')
                local name=$(read_json_value "$pack_dir/manifest.json" '.header.name')
                
                if [[ -n "$uuid" ]]; then
                    existing_uuids["$uuid"]="$pack_dir"
                    local short_name=$(generate_folder_name "$name")
                    echo "RP|$uuid|$short_name|$(basename "$pack_dir")|$pack_dir" >> "$registry_file"
                    log "${BLUE}UUID mapeado (RP): $uuid -> $(basename "$pack_dir")${NC}"
                    ((total_mapped++))
                fi
            fi
        done
    fi
    
    log "${GREEN}Total UUIDs mapeados: $total_mapped${NC}"
    log "${GREEN}Registro: $(basename "$registry_file")${NC}"
}

process_mcpack_files() {
    log "${YELLOW}=== Paso 3: Procesando archivos .mcpack ===${NC}"
    
    local mcpack_count=0
    local installed_count=0
    local updated_count=0
    
    for mcpack in *.mcpack; do
        if [[ ! -f "$mcpack" ]]; then
            continue
        fi
        
        log "${BLUE}Procesando: $(basename "$mcpack")${NC}"
        
        local temp_dir=$(create_temp_dir)
        
        if ! unzip -q "$mcpack" -d "$temp_dir" 2>/dev/null; then
            log "${RED}✗ Error al extraer: $(basename "$mcpack")${NC}"
            cleanup_temp "$temp_dir"
            continue
        fi
        
        local manifest_file=$(find "$temp_dir" -name "manifest.json" -type f 2>/dev/null | head -1)
        if [[ -z "$manifest_file" ]]; then
            log "${RED}✗ No se encontró manifest.json en: $(basename "$mcpack")${NC}"
            cleanup_temp "$temp_dir"
            continue
        fi
        
        # Leer manifest
        local uuid=$(read_json_value "$manifest_file" '.header.uuid')
        local name=$(read_json_value "$manifest_file" '.header.name')
        local is_resource=$(read_json_value "$manifest_file" '.modules[]? | select(.type == "resources") | .type')
        
        if [[ -z "$uuid" ]]; then
            log "${RED}✗ UUID no encontrado en: $(basename "$mcpack")${NC}"
            cleanup_temp "$temp_dir"
            continue
        fi
        
        if [[ -z "$name" ]]; then
            name="addon_$(date +%s | tail -c 6)"
        fi
        
        local pack_type
        local base_dest_dir
        
        if [[ "$is_resource" == "resources" ]]; then
            pack_type="RP"
            base_dest_dir="$MinecraftPath/resource_packs"
            log "${BLUE}Tipo: Resource Pack${NC}"
        else
            pack_type="BP"
            base_dest_dir="$MinecraftPath/behavior_packs"
            log "${BLUE}Tipo: Behavior Pack${NC}"
        fi
        
        local folder_name=$(generate_folder_name "$name")
        local dest_dir
        
        if [[ -n "${existing_uuids[$uuid]}" ]]; then
            dest_dir="${existing_uuids[$uuid]}"
            log "${YELLOW}Actualizando: $(basename "$dest_dir")${NC}"
            rm -rf "$dest_dir"
            ((updated_count++))
        else
            dest_dir="$base_dest_dir/$folder_name"
            log "${GREEN}Instalando nuevo: $folder_name${NC}"
            ((installed_count++))
        fi
        
        mkdir -p "$(dirname "$dest_dir")"
        
        if mv "$temp_dir" "$dest_dir"; then
            apply_permissions "$dest_dir"
            rm "$mcpack"
            
            log "${GREEN}✓ Pack procesado: $folder_name ($pack_type)${NC}"
            log "${GREEN}  UUID: ${uuid:0:8}...${NC}"
            log "${GREEN}  Destino: $(basename "$dest_dir")${NC}"
            
            ((mcpack_count++))
        else
            log "${RED}✗ Error al mover pack: $(basename "$mcpack")${NC}"
            cleanup_temp "$temp_dir"
        fi
    done
    
    # resumen
    log "${YELLOW}=== Resumen Final ===${NC}"
    log "${GREEN}Archivos .mcpack procesados: $mcpack_count${NC}"
    log "${GREEN}Packs nuevos instalados: $installed_count${NC}"
    log "${GREEN}Packs actualizados: $updated_count${NC}"
    
    if [[ $mcpack_count -eq 0 ]]; then
        log "${YELLOW}No se encontraron archivos para procesar${NC}"
    fi
}

main() {
    initialize
    extract_mcaddon_files
    map_existing_uuids
    process_mcpack_files
    
    log "${BLUE}=== Proceso completado ===${NC}"
    log "${BLUE}Log: $(basename "$LOG_FILE")${NC}"
}

main "$@"
