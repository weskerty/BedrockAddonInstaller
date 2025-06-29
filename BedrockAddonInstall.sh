#!/bin/bash

# Config
# Ubicacion de Minecraft o Server donde existan las carpetas resource_packs y behavior_packs
MinecraftPath="/opt/minecraft-bedrock-server" 

# Ubicacion de los nuevos AddOns. Donde guardas los .mcpack .mcaddon 
AddOnsPath="Descargas/AddOns"

# 
UUID="True"

























RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

# 
log() {
    local message="$1"
    echo -e "$message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | sed 's/\x1b\[[0-9;]*m//g' >> "$AddOnsPath/addon-updater.log"
}

echo "$(date '+%Y-%m-%d %H:%M:%S') - Minecraft AddOn Updater Started" > "$AddOnsPath/addon-updater.log"

log "${BLUE}=== Minecraft AddOn Updater ===${NC}"
log "${BLUE}MinecraftPath: $MinecraftPath${NC}"
log "${BLUE}AddOnsPath: $AddOnsPath${NC}"

# Obtener permisos y propietario del directorio de Minecraft
if [[ -d "$MinecraftPath" ]]; then
    minecraft_owner=$(stat -c "%U" "$MinecraftPath")
    minecraft_group=$(stat -c "%G" "$MinecraftPath")
    minecraft_perms=$(stat -c "%a" "$MinecraftPath")
    log "${BLUE}Minecraft directory owner: $minecraft_owner:$minecraft_group${NC}"
    log "${BLUE}Minecraft directory permissions: $minecraft_perms${NC}"
else
    log "${RED}Error: MinecraftPath no existe: $MinecraftPath${NC}"
    exit 1
fi

if [[ ! -d "$AddOnsPath" ]]; then
    log "${RED}Error: AddOnsPath no existe: $AddOnsPath${NC}"
    exit 1
fi


apply_permissions() {
    local target_path="$1"
    if [[ -e "$target_path" ]]; then
        chown -R "$minecraft_owner:$minecraft_group" "$target_path"
        chmod -R "$minecraft_perms" "$target_path"
        log "${GREEN}Permisos aplicados a: $target_path${NC}"
    fi
}

cd "$AddOnsPath" || exit 1

# Extraer todos los .mcaddon
log "${YELLOW}=== Paso 1: Extrayendo archivos .mcaddon ===${NC}"
mcaddon_count=0
for mcaddon in *.mcaddon; do
    if [[ -f "$mcaddon" ]]; then
        log "${BLUE}Extrayendo: $mcaddon${NC}"
        unzip -q "$mcaddon" -d "temp_extract_$$" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            # Mover archivos .mcpack al directorio principal
            find "temp_extract_$$" -name "*.mcpack" -exec mv {} . \;
            rm -rf "temp_extract_$$"
            rm "$mcaddon"
            ((mcaddon_count++))
            log "${GREEN}✓ Extraido y eliminado: $mcaddon${NC}"
        else
            log "${RED}✗ Error al extraer: $mcaddon${NC}"
            rm -rf "temp_extract_$$"
        fi
    fi
done
log "${GREEN}Total .mcaddon procesados: $mcaddon_count${NC}"

# Paso 2: Mapear UUIDs existentes
log "${YELLOW}=== Paso 2: Mapeando UUIDs existentes ===${NC}"
declare -A existing_uuids

# Crear archivo de registro de UUIDs
registry_file="$AddOnsPath/installed_packs_registry.txt"
echo "# Registro de Packs Instalados - $(date '+%Y-%m-%d %H:%M:%S')" > "$registry_file"
echo "# Formato: TIPO|UUID|NOMBRE|CARPETA|RUTA" >> "$registry_file"

# Mapear behavior_packs
for pack_dir in "$MinecraftPath/behavior_packs"/*; do
    if [[ -d "$pack_dir" && -f "$pack_dir/manifest.json" ]]; then
        uuid=$(jq -r '.header.uuid // empty' "$pack_dir/manifest.json" 2>/dev/null)
        name=$(jq -r '.header.name // empty' "$pack_dir/manifest.json" 2>/dev/null)
        if [[ -n "$uuid" && "$uuid" != "null" ]]; then
            existing_uuids["$uuid"]="$pack_dir"
            echo "BP|$uuid|$name|$(basename "$pack_dir")|$pack_dir" >> "$registry_file"
            log "${BLUE}UUID mapeado (BP): $uuid -> $(basename "$pack_dir")${NC}"
        fi
    fi
done

# Mapear resource_packs
for pack_dir in "$MinecraftPath/resource_packs"/*; do
    if [[ -d "$pack_dir" && -f "$pack_dir/manifest.json" ]]; then
        uuid=$(jq -r '.header.uuid // empty' "$pack_dir/manifest.json" 2>/dev/null)
        name=$(jq -r '.header.name // empty' "$pack_dir/manifest.json" 2>/dev/null)
        if [[ -n "$uuid" && "$uuid" != "null" ]]; then
            existing_uuids["$uuid"]="$pack_dir"
            echo "RP|$uuid|$name|$(basename "$pack_dir")|$pack_dir" >> "$registry_file"
            log "${BLUE}UUID mapeado (RP): $uuid -> $(basename "$pack_dir")${NC}"
        fi
    fi
done

log "${GREEN}Total UUIDs mapeados: ${#existing_uuids[@]}${NC}"
log "${GREEN}Registro guardado en: $registry_file${NC}"

# Paso 3: Procesar archivos .mcpack
log "${YELLOW}=== Paso 3: Procesando archivos .mcpack ===${NC}"
mcpack_count=0
installed_count=0
updated_count=0

for mcpack in *.mcpack; do
    if [[ -f "$mcpack" ]]; then
        log "${BLUE}Procesando: $mcpack${NC}"
        
        # Crear directorio temporal para extraer
        temp_dir="temp_pack_$$_$mcpack_count"
        mkdir "$temp_dir"
        
        # Extraer .mcpack
        unzip -q "$mcpack" -d "$temp_dir" 2>/dev/null
        if [[ $? -ne 0 ]]; then
            log "${RED}✗ Error al extraer: $mcpack${NC}"
            rm -rf "$temp_dir"
            continue
        fi
        
        # Buscar manifest.json
        manifest_file=$(find "$temp_dir" -name "manifest.json" -type f | head -1)
        if [[ -z "$manifest_file" ]]; then
            log "${RED}✗ No se encontro manifest.json en: $mcpack${NC}"
            rm -rf "$temp_dir"
            continue
        fi
        
        # Leer datos del manifest
        uuid=$(jq -r '.header.uuid // empty' "$manifest_file" 2>/dev/null)
        name=$(jq -r '.header.name // empty' "$manifest_file" 2>/dev/null)
        is_resource=$(jq -r '.modules[]? | select(.type == "resources") | .type' "$manifest_file" 2>/dev/null)
        
        if [[ -z "$uuid" || "$uuid" == "null" ]]; then
            log "${RED}✗ UUID no encontrado en: $mcpack${NC}"
            rm -rf "$temp_dir"
            continue
        fi
        
        if [[ -z "$name" || "$name" == "null" ]]; then
            log "${RED}✗ Nombre no encontrado en: $mcpack${NC}"
            rm -rf "$temp_dir"
            continue
        fi
        
        # Determinar tipo y directorio destino
        if [[ "$is_resource" == "resources" ]]; then
            pack_type="RP"
            base_dest_dir="$MinecraftPath/resource_packs"
            log "${BLUE}Tipo: Resource Pack${NC}"
        else
            pack_type="BP"
            base_dest_dir="$MinecraftPath/behavior_packs"
            log "${BLUE}Tipo: Behavior Pack${NC}"
        fi
        
        # Generar nombre de carpeta (primeras 11 letras)
        folder_name="${name:0:11}"
        
        # Verificar si es actualizacion
        if [[ -n "${existing_uuids[$uuid]}" ]]; then
            # Es actualizacion
            dest_dir="${existing_uuids[$uuid]}"
            log "${YELLOW}Actualizando pack existente: $(basename "$dest_dir")${NC}"
            rm -rf "$dest_dir"
            ((updated_count++))
        else
            # Es instalacion nueva
            dest_dir="$base_dest_dir/$folder_name"
            log "${GREEN}Instalando nuevo pack: $folder_name${NC}"
            ((installed_count++))
        fi
        
        # Mover archivos extraidos al destino
        mkdir -p "$(dirname "$dest_dir")"
        mv "$temp_dir" "$dest_dir"
        
        # Aplicar permisos y propietario
        apply_permissions "$dest_dir"
        
        # Eliminar .mcpack procesado
        rm "$mcpack"
        
        log "${GREEN}✓ Pack procesado: $name ($pack_type)${NC}"
        log "${GREEN}  UUID: $uuid${NC}"
        log "${GREEN}  Destino: $dest_dir${NC}"
        
        ((mcpack_count++))
    fi
done

# Resumen final
log "${YELLOW}=== Resumen Final ===${NC}"
log "${GREEN}Archivos .mcaddon extraidos: $mcaddon_count${NC}"
log "${GREEN}Archivos .mcpack procesados: $mcpack_count${NC}"
log "${GREEN}Packs nuevos instalados: $installed_count${NC}"
log "${GREEN}Packs actualizados: $updated_count${NC}"

if [[ $mcpack_count -eq 0 && $mcaddon_count -eq 0 ]]; then
    log "${YELLOW}No se encontraron archivos .mcpack o .mcaddon para procesar${NC}"
fi

log "${BLUE}=== Proceso completado ===${NC}"
log "${BLUE}Log guardado en: $AddOnsPath/addon-updater.log${NC}"
