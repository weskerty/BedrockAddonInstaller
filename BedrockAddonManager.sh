#!/bin/bash

# Config
MinecraftPath="/opt/minecraft-bedrock-server"
AddOnsPath="/root/Descargas/AddOns"
RegistryFile="$AddOnsPath/installed_packs_registry.txt"
WorldsFolder="worlds"
ShowUUID=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

declare -A pack_names
declare -A pack_paths
current_world=""
current_type=""
current_file=""
backup_created=false

load_pack_info() {
    pack_names=()
    pack_paths=()
    
    if [[ -f "$RegistryFile" ]]; then
        while IFS='|' read -r type uuid name folder path; do
            if [[ ! "$type" =~ ^# && -n "$uuid" && -n "$name" && -n "$path" ]]; then
                pack_names["$uuid"]="$name"
                pack_paths["$uuid"]="$path"
            fi
        done < "$RegistryFile"
    fi
}

get_pack_name() {
    local uuid="$1"
    if [[ -n "${pack_names[$uuid]}" ]]; then
        echo "${pack_names[$uuid]}"
    else
        echo "Pack Desconocido ($uuid)"
    fi
}

get_pack_path() {
    local uuid="$1"
    echo "${pack_paths[$uuid]}"
}

create_backup() {
    if [[ "$backup_created" == false ]]; then
        local bp_file="$MinecraftPath/$WorldsFolder/$current_world/world_behavior_packs.json"
        local rp_file="$MinecraftPath/$WorldsFolder/$current_world/world_resource_packs.json"
        
        [[ -f "$bp_file" ]] && cp "$bp_file" "$bp_file.backup"
        [[ -f "$rp_file" ]] && cp "$rp_file" "$rp_file.backup"
        
        backup_created=true
    fi
}

read_active_packs() {
    local file="$1"
    if [[ -f "$file" ]]; then
        jq -r '.[].pack_id' "$file" 2>/dev/null | grep -v '^null$' | grep -E '^[a-fA-F0-9-]+$'
    fi
}

get_all_packs() {
    local type="$1"
    if [[ -f "$RegistryFile" ]]; then
        grep "^$type|" "$RegistryFile" | cut -d'|' -f2
    fi
}

get_inactive_packs() {
    local type="$1"
    local active_packs=()
    local all_packs=()
    
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && active_packs+=("$uuid")
    done < <(read_active_packs "$current_file")
    
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && all_packs+=("$uuid")
    done < <(get_all_packs "$type")
    
    for pack in "${all_packs[@]}"; do
        local is_active=false
        for active in "${active_packs[@]}"; do
            if [[ "$pack" == "$active" ]]; then
                is_active=true
                break
            fi
        done
        [[ "$is_active" == false ]] && echo "$pack"
    done
}

write_packs_json() {
    local file="$1"
    shift
    local packs=("$@")
    
    echo "[" > "$file"
    for i in "${!packs[@]}"; do
        local uuid="${packs[$i]}"
        if [[ -n "$uuid" ]]; then
            echo -e "\t{" >> "$file"
            echo -e "\t\t\"pack_id\" : \"$uuid\"," >> "$file"
            echo -e "\t\t\"version\" : [ 1, 0, 0 ]" >> "$file"
            if [[ $i -eq $((${#packs[@]} - 1)) ]]; then
                echo -e "\t}" >> "$file"
            else
                echo -e "\t}," >> "$file"
            fi
        fi
    done
    echo "]" >> "$file"
}

move_pack() {
    local from_pos="$1"
    local to_pos="$2"
    
    local packs=()
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && packs+=("$uuid")
    done < <(read_active_packs "$current_file")
    
    local total_packs=${#packs[@]}
    
    if [[ $from_pos -lt 1 || $from_pos -gt $total_packs || $to_pos -lt 1 || $to_pos -gt $total_packs ]]; then
        echo -e "${RED}Posicion invalida. Rango valido: 1-$total_packs${NC}"
        return 1
    fi
    
    if [[ $from_pos -eq $to_pos ]]; then
        echo -e "${YELLOW}El pack ya esta en esa Posicion${NC}"
        return 0
    fi
    
    local from_idx=$((from_pos - 1))
    local to_idx=$((to_pos - 1))
    
    local new_packs=()
    local pack_to_move="${packs[$from_idx]}"
    
    for i in $(seq 0 $((total_packs - 1))); do
        if [[ $i -eq $to_idx ]]; then
            new_packs+=("$pack_to_move")
        fi
        if [[ $i -ne $from_idx ]]; then
            new_packs+=("${packs[$i]}")
        fi
    done
    
    write_packs_json "$current_file" "${new_packs[@]}"
    echo -e "${GREEN}Pack movido exitosamente de Posicion $from_pos a $to_pos${NC}"
}

remove_pack_from_world() {
    local pos="$1"
    
    local packs=()
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && packs+=("$uuid")
    done < <(read_active_packs "$current_file")
    
    if [[ $pos -lt 1 || $pos -gt ${#packs[@]} ]]; then
        echo -e "${RED}Posicion invalida${NC}"
        return 1
    fi
    
    local idx=$((pos - 1))
    local removed_uuid="${packs[$idx]}"
    unset packs[$idx]
    packs=("${packs[@]}")
    
    write_packs_json "$current_file" "${packs[@]}"
    echo -e "${GREEN}Pack '$(get_pack_name "$removed_uuid")' desactivado del mundo${NC}"
}

activate_pack() {
    local uuid="$1"
    local pos="$2"
    
    if [[ -z "${pack_names[$uuid]}" ]]; then
        echo -e "${RED}Error: Pack no encontrado en el registro${NC}"
        return 1
    fi
    
    local packs=()
    while IFS= read -r existing_uuid; do
        [[ -n "$existing_uuid" ]] && packs+=("$existing_uuid")
    done < <(read_active_packs "$current_file")
    
    for active_uuid in "${packs[@]}"; do
        if [[ "$active_uuid" == "$uuid" ]]; then
            echo -e "${YELLOW}El pack ya esta activo${NC}"
            return 1
        fi
    done
    
    local max_pos=$((${#packs[@]} + 1))
    
    if [[ $pos -lt 1 || $pos -gt $max_pos ]]; then
        echo -e "${RED}Posicion invalida. Rango valido: 1-$max_pos${NC}"
        return 1
    fi
    
    local new_packs=()
    local inserted=false
    
    for i in "${!packs[@]}"; do
        if [[ $((i + 1)) -eq $pos && $inserted == false ]]; then
            new_packs+=("$uuid")
            inserted=true
        fi
        new_packs+=("${packs[$i]}")
    done
    
    if [[ $inserted == false ]]; then
        new_packs+=("$uuid")
    fi
    
    write_packs_json "$current_file" "${new_packs[@]}"
    echo -e "${GREEN}Pack '$(get_pack_name "$uuid")' activado en Posicion $pos${NC}"
}

deactivate_all_packs() {
    write_packs_json "$current_file"
    echo -e "${GREEN}Todos los packs han sido desactivados${NC}"
}

activate_all_packs() {
    local pack_type="$([[ "$current_type" == "Behavior Packs" ]] && echo "BP" || echo "RP")"
    local all_packs=()
    
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && all_packs+=("$uuid")
    done < <(get_all_packs "$pack_type")
    
    if [[ ${#all_packs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No hay packs disponibles para activar${NC}"
        return 1
    fi
    
    write_packs_json "$current_file" "${all_packs[@]}"
    echo -e "${GREEN}Todos los packs han sido activados (${#all_packs[@]} packs)${NC}"
}

delete_pack_physically() {
    local uuid="$1"
    local pack_path="$(get_pack_path "$uuid")"
    
    if [[ -z "$pack_path" ]]; then
        echo -e "${RED}No se encontro la ruta del pack en el registro${NC}"
        return 1
    fi
    
    if [[ ! -d "$pack_path" ]]; then
        echo -e "${YELLOW}La ruta del pack no existe: $pack_path${NC}"
        remove_from_registry "$uuid"
        return 0
    fi
    
    rm -rf "$pack_path"
    if [[ $? -eq 0 ]]; then
        remove_from_registry "$uuid"
        echo -e "${GREEN}Pack eliminado permanentemente${NC}"
        return 0
    else
        echo -e "${RED}Error al eliminar el pack${NC}"
        return 1
    fi
}

remove_from_registry() {
    local uuid="$1"
    
    if [[ -f "$RegistryFile" ]]; then
        grep -v "|$uuid|" "$RegistryFile" > "$RegistryFile.tmp" && mv "$RegistryFile.tmp" "$RegistryFile"
        unset pack_names["$uuid"]
        unset pack_paths["$uuid"]
    fi
}

format_pack_display() {
    local uuid="$1"
    local name="$(get_pack_name "$uuid")"
    
    if [[ "$ShowUUID" == true ]]; then
        echo "$name"
        echo -e "   ${CYAN}UUID: $uuid${NC}"
    elif [[ "$name" == "Pack Desconocido"* ]]; then
        echo "$name"
    else
        echo "$name"
    fi
}

show_active_pack_menu() {
    local pack_uuid="$1"
    local pack_pos="$2"
    local pack_name="$(get_pack_name "$pack_uuid")"
    
    while true; do
        clear
        echo -e "${BLUE}=== Gestion de Pack Activo ===${NC}"
        echo -e "${YELLOW}Mundo: $current_world${NC}"
        echo -e "${YELLOW}Tipo: $current_type${NC}"
        echo -e "${CYAN}Pack: $pack_name${NC}"
        if [[ "$ShowUUID" == true ]]; then
            echo -e "${CYAN}UUID: $pack_uuid${NC}"
        fi
        echo -e "${CYAN}Posicion actual: $pack_pos${NC}"
        echo
        
        local active_count=0
        while IFS= read -r uuid; do
            [[ -n "$uuid" ]] && ((active_count++))
        done < <(read_active_packs "$current_file")
        
        echo -e "${GREEN}1)${NC} Mover a otra Posicion (1-$active_count)"
        echo -e "${YELLOW}2)${NC} Desactivar del mundo"
        echo -e "${RED}3)${NC} Eliminar permanentemente"
        echo -e "${BLUE}0)${NC} Volver"
        echo
        read -p "Selecciona una opcion: " choice
        
        case $choice in
            1)
                echo -e "${BLUE}Posiciones disponibles: 1-$active_count${NC}"
                read -p "Nueva Posicion: " new_pos
                if [[ "$new_pos" =~ ^[0-9]+$ ]]; then
                    move_pack "$pack_pos" "$new_pos"
                    read -p "Enter = Continuar"
                    return
                else
                    echo -e "${RED}Posicion invalida${NC}"
                    read -p "Enter = Continuar"
                fi
                ;;
            2)
                remove_pack_from_world "$pack_pos"
                read -p "Enter = Continuar"
                return
                ;;
            3)
                remove_pack_from_world "$pack_pos"
                if delete_pack_physically "$pack_uuid"; then
                    echo -e "${GREEN}Pack eliminado completamente${NC}"
                else
                    echo -e "${YELLOW}Pack desactivado del mundo solamente${NC}"
                fi
                read -p "Enter = Continuar"
                return
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opcion invalida${NC}"
                read -p "Enter = Continuar"
                ;;
        esac
    done
}

show_inactive_pack_menu() {
    local pack_uuid="$1"
    local pack_name="$(get_pack_name "$pack_uuid")"
    
    while true; do
        clear
        echo -e "${BLUE}=== Pack Desactivado ===${NC}"
        echo -e "${YELLOW}Mundo: $current_world${NC}"
        echo -e "${YELLOW}Tipo: $current_type${NC}"
        echo -e "${CYAN}Pack: $pack_name${NC}"
        if [[ "$ShowUUID" == true ]]; then
            echo -e "${CYAN}UUID: $pack_uuid${NC}"
        fi
        echo
        
        local active_count=0
        while IFS= read -r uuid; do
            [[ -n "$uuid" ]] && ((active_count++))
        done < <(read_active_packs "$current_file")
        
        echo -e "${GREEN}1)${NC} Activar en el mundo (posiciones: 1-$((active_count + 1)))"
        echo -e "${RED}2)${NC} Eliminar permanentemente"
        echo -e "${BLUE}0)${NC} Volver"
        echo
        read -p "Selecciona una opcion: " choice
        
        case $choice in
            1)
                echo -e "${BLUE}Posiciones disponibles: 1-$((active_count + 1))${NC}"
                read -p "Posicion para activar: " pos
                if [[ "$pos" =~ ^[0-9]+$ ]]; then
                    activate_pack "$pack_uuid" "$pos"
                    read -p "Enter = Continuar"
                    return
                else
                    echo -e "${RED}Posicion invalida${NC}"
                    read -p "Enter = Continuar"
                fi
                ;;
            2)
                if delete_pack_physically "$pack_uuid"; then
                    echo -e "${GREEN}Pack eliminado permanentemente${NC}"
                    read -p "Enter = Continuar"
                    return
                else
                    echo -e "${YELLOW}Error al eliminar${NC}"
                    read -p "Enter = Continuar"
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opcion invalida${NC}"
                read -p "Enter = Continuar"
                ;;
        esac
    done
}

show_packs_list() {
    while true; do
        clear
        echo -e "${BLUE}=== Gestion de AddOns ===${NC}"
        echo -e "${YELLOW}Mundo: $current_world${NC}"
        echo -e "${YELLOW}Tipo: $current_type${NC}"
        echo
        
        echo -e "${GREEN}=== Packs Activos ===${NC}"
        local active_packs=()
        local counter=1
        while IFS= read -r uuid; do
            if [[ -n "$uuid" ]]; then
                active_packs+=("$uuid")
                echo -e "${GREEN}$counter)${NC} $(format_pack_display "$uuid")"
                ((counter++))
            fi
        done < <(read_active_packs "$current_file")
        
        if [[ ${#active_packs[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No hay packs activos${NC}"
        fi
        
        echo
        
        echo -e "${MAGENTA}=== Packs Desactivados ===${NC}"
        local inactive_packs=()
        local d_counter=1
        local pack_type="$([[ "$current_type" == "Behavior Packs" ]] && echo "BP" || echo "RP")"
        
        while IFS= read -r uuid; do
            if [[ -n "$uuid" ]]; then
                inactive_packs+=("$uuid")
                echo -e "${MAGENTA}d$d_counter)${NC} $(format_pack_display "$uuid")"
                ((d_counter++))
            fi
        done < <(get_inactive_packs "$pack_type")
        
        if [[ ${#inactive_packs[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No hay packs desactivados${NC}"
        fi
        
        echo
        echo -e "${CYAN}a)${NC} Activar todos los packs"
        echo -e "${YELLOW}da)${NC} Desactivar todos los packs"
        echo -e "${BLUE}0)${NC} Volver al menu anterior"
        echo
        read -p "Selecciona una opcion: " choice
        
        case $choice in
            0)
                return
                ;;
            a)
                activate_all_packs
                read -p "Enter = Continuar"
                ;;
            da)
                deactivate_all_packs
                read -p "Enter = Continuar"
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#active_packs[@]} ]]; then
                    show_active_pack_menu "${active_packs[$((choice-1))]}" "$choice"
                elif [[ "$choice" =~ ^d[0-9]+$ ]]; then
                    local d_num="${choice#d}"
                    if [[ $d_num -ge 1 && $d_num -le ${#inactive_packs[@]} ]]; then
                        show_inactive_pack_menu "${inactive_packs[$((d_num-1))]}"
                    else
                        echo -e "${RED}Opcion invalida${NC}"
                        read -p "Enter = Continuar"
                    fi
                else
                    echo -e "${RED}Opcion invalida${NC}"
                    read -p "Enter = Continuar"
                fi
                ;;
        esac
    done
}

select_pack_type() {
    local world="$1"
    current_world="$world"
    create_backup
    
    while true; do
        clear
        echo -e "${BLUE}=== Seleccionar Tipo de Pack ===${NC}"
        echo -e "${YELLOW}Mundo: $world${NC}"
        echo
        echo -e "${GREEN}1)${NC} Behavior Packs"
        echo -e "${GREEN}2)${NC} Resource Packs"
        echo -e "${BLUE}0)${NC} Volver"
        echo
        read -p "Selecciona el tipo: " choice
        
        case $choice in
            1)
                current_type="Behavior Packs"
                current_file="$MinecraftPath/$WorldsFolder/$world/world_behavior_packs.json"
                if [[ ! -f "$current_file" ]]; then
                    echo "[]" > "$current_file"
                fi
                show_packs_list
                ;;
            2)
                current_type="Resource Packs"
                current_file="$MinecraftPath/$WorldsFolder/$world/world_resource_packs.json"
                if [[ ! -f "$current_file" ]]; then
                    echo "[]" > "$current_file"
                fi
                show_packs_list
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opcion invalida${NC}"
                read -p "Enter = Continuar"
                ;;
        esac
    done
}

select_world() {
    while true; do
        clear
        echo -e "${BLUE}=== Minecraft AddOn Manager ===${NC}"
        echo -e "${GREEN}Seleccionar Mundo:${NC}"
        echo
        
        local worlds=()
        local counter=1
        
        if [[ -d "$MinecraftPath/$WorldsFolder" ]]; then
            for world_dir in "$MinecraftPath/$WorldsFolder"/*; do
                if [[ -d "$world_dir" ]]; then
                    local world_name="$(basename "$world_dir")"
                    worlds+=("$world_name")
                    echo -e "${GREEN}$counter)${NC} $world_name"
                    ((counter++))
                fi
            done
        fi
        
        if [[ ${#worlds[@]} -eq 0 ]]; then
            echo -e "${RED}No se encontraron mundos en $MinecraftPath/$WorldsFolder${NC}"
            read -p "Presiona Enter para salir..."
            exit 1
        fi
        
        echo
        echo -e "${BLUE}0)${NC} Salir"
        echo
        read -p "Selecciona un mundo: " choice
        
        if [[ "$choice" == "0" ]]; then
            echo -e "${BLUE}Hasta luego!${NC}"
            exit 0
        elif [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#worlds[@]} ]]; then
            select_pack_type "${worlds[$((choice-1))]}"
        else
            echo -e "${RED}Opcion invalida${NC}"
            read -p "Enter = Continuar"
        fi
    done
}

main() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq no esta instalado. ${NC}"
        exit 1
    fi
    
    if [[ ! -d "$MinecraftPath" ]]; then
        echo -e "${RED}Error: MinecraftPath no existe: $MinecraftPath${NC}"
        exit 1
    fi
    
    if [[ ! -d "$MinecraftPath/$WorldsFolder" ]]; then
        echo -e "${RED}Error: No el directorio de mundos: $MinecraftPath/$WorldsFolder${NC}"
        exit 1
    fi
    
    if [[ ! -f "$RegistryFile" ]]; then
        echo -e "${RED}Error: No archivo de registro: $RegistryFile${NC}"
        exit 1
    fi
    
    load_pack_info
    
    echo -e "${GREEN}Packs cargados: ${#pack_names[@]}${NC}"
    
    select_world
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi