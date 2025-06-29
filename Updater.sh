#!/bin/bash


#Solo de Ejemplo!!!!!!! Actualmente Nadie sube a git sus addons.
set -e

# ====== CONFIGURACION ======
DOWNLOAD_PATH="./minecraft_packages"  # Ruta donde descargar los archivos
CHECK_DATES=true                      # true para verificar fechas - false para descargar siempre
GITHUB_TOKEN=""                       

# Lista de repositorios 
REPOSITORIES=(
  "owner/repo-name"
  "another-owner/repo-name"
  # Agregar mas repositorios aqui
)


FILE_EXTENSIONS=("mcpack" "mcaddon" "mcworld")



create_download_dir() {
  if [[ ! -d "$DOWNLOAD_PATH" ]]; then
    echo "📁 Creando directorio $DOWNLOAD_PATH"
    mkdir -p "$DOWNLOAD_PATH"
  fi
}

check_need_download() {
  local remote_date="$1"
  local local_file="$2"
  local source_name="$3"
  
  if [[ "$CHECK_DATES" != "true" ]]; then
    echo "⏭️ Verificacion de fechas desactivada"
    return 0  # Descargar siempre
  fi
  
  if [[ -f "$local_file" ]]; then
    LOCAL_DATE=$(date -r "$local_file" -Iseconds)
    echo "📁 Local: $LOCAL_DATE"
    
    REMOTE_TIMESTAMP=$(date -d "$remote_date" +%s)
    LOCAL_TIMESTAMP=$(date -d "$LOCAL_DATE" +%s)
    
    if [[ $LOCAL_TIMESTAMP -ge $REMOTE_TIMESTAMP ]]; then
      echo "✅ $local_file ya actualizado ($source_name)"
      return 1  # No descargar
    else
      echo "📥 Version nueva disponible ($source_name)"
      return 0 
    fi
  else
    echo "📁 Archivo local no encontrado"
    return 0  
  fi
}

download_from_artifacts() {
  local repo="$1"
  local downloaded=false
  
  echo "🔧 Buscando artifacts en $repo..."
  
  if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "⚠️ GITHUB_TOKEN no configurado, saltando artifacts"
    return 1
  fi
  
  ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/$repo/actions/artifacts?per_page=20" 2>/dev/null || echo "")
  
  if [[ -z "$ARTIFACTS_JSON" ]]; then
    echo "⚠️ No se pudo obtener artifacts de $repo"
    return 1
  fi
  

  VALID_ARTIFACTS=$(echo "$ARTIFACTS_JSON" | jq -r '
    [.artifacts[] | select(.expired == false)] |
    sort_by(.created_at) | reverse
  ' 2>/dev/null || echo "[]")
  
  if [[ "$VALID_ARTIFACTS" == "[]" ]]; then
    echo "⚠️ No hay artifacts validos en $repo"
    return 1
  fi
  

  echo "$VALID_ARTIFACTS" | jq -c '.[]' | while read -r artifact; do
    ARTIFACT_ID=$(echo "$artifact" | jq -r '.id')
    ARTIFACT_DATE=$(echo "$artifact" | jq -r '.created_at')
    ARTIFACT_NAME=$(echo "$artifact" | jq -r '.name')
    WORKFLOW_SHA=$(echo "$artifact" | jq -r '.workflow_run.head_sha[0:7]')
    
    echo "🔧 Procesando artifact: $ARTIFACT_NAME (ID=$ARTIFACT_ID, SHA=$WORKFLOW_SHA)"
    

    local should_download=false
    for ext in "${FILE_EXTENSIONS[@]}"; do
      if [[ "$ARTIFACT_NAME" =~ $ext ]]; then
        should_download=true
        break
      fi
    done
    
    if [[ "$should_download" == "true" ]]; then
      local_file="$DOWNLOAD_PATH/${ARTIFACT_NAME}.zip"
      
      if check_need_download "$ARTIFACT_DATE" "$local_file" "artifact"; then
        echo "⬇️ Descargando artifact $ARTIFACT_NAME..."
        
        if curl -L -s -H "Authorization: token $GITHUB_TOKEN" \
          "https://api.github.com/repos/$repo/actions/artifacts/$ARTIFACT_ID/zip" \
          -o "$local_file"; then
          echo "✅ $ARTIFACT_NAME descargado como ZIP"
          downloaded=true
        else
          echo "❌ Error al descargar artifact $ARTIFACT_ID"
        fi
      fi
    fi
  done
  
  return 0
}

download_from_releases() {
  local repo="$1"
  local downloaded=false
  
  echo "🌐 Buscando releases en $repo..."
  
  RELEASE_JSON=$(curl -s "https://api.github.com/repos/$repo/releases?per_page=10" || echo "")
  
  if [[ -z "$RELEASE_JSON" ]]; then
    echo "❌ No se pudo obtener releases de $repo"
    return 1
  fi
  

  echo "$RELEASE_JSON" | jq -c '.[]' | while read -r release; do
    RELEASE_DATE=$(echo "$release" | jq -r '.published_at')
    TAG_NAME=$(echo "$release" | jq -r '.tag_name')
    PRERELEASE=$(echo "$release" | jq -r '.prerelease')
    
    echo "📦 Procesando release: $TAG_NAME (Prerelease: $PRERELEASE, $RELEASE_DATE)"
    

    ASSETS=$(echo "$release" | jq -c '.assets[]')
    
    if [[ -n "$ASSETS" ]]; then
      echo "$ASSETS" | while read -r asset; do
        ASSET_NAME=$(echo "$asset" | jq -r '.name')
        ASSET_URL=$(echo "$asset" | jq -r '.browser_download_url')
        

        for ext in "${FILE_EXTENSIONS[@]}"; do
          if [[ "$ASSET_NAME" =~ \.$ext$ ]]; then
            local_file="$DOWNLOAD_PATH/$ASSET_NAME"
            
            if check_need_download "$RELEASE_DATE" "$local_file" "release"; then
              echo "⬇️ Descargando $ASSET_NAME desde release..."
              
              if curl -L -s --show-progress -o "$local_file" "$ASSET_URL"; then
                echo "✅ $ASSET_NAME descargado desde release"
                downloaded=true
              else
                echo "❌ Error al descargar $ASSET_NAME"
              fi
            fi
            break
          fi
        done
      done
    fi
  done
  
  return 0
}

process_repository() {
  local repo="$1"
  echo ""
  echo "🎯 Procesando repositorio: $repo"
  echo "=================================="
  
  local success=false
  

  if [[ -n "$GITHUB_TOKEN" ]] && download_from_artifacts "$repo"; then
    success=true
  fi
  

  if download_from_releases "$repo"; then
    success=true
  fi
  
  if [[ "$success" == "false" ]]; then
    echo "⚠️ No se pudieron obtener archivos de $repo"
  fi
}



echo "🚀 Iniciando descarga de paquetes Minecraft..."
echo "📂 Ruta de descarga: $DOWNLOAD_PATH"
echo "🔍 Extensiones: ${FILE_EXTENSIONS[*]}"
echo "⏰ Verificar fechas: $CHECK_DATES"
echo "🏢 Repositorios: ${#REPOSITORIES[@]}"

create_download_dir

if [[ ${#REPOSITORIES[@]} -eq 0 ]]; then
  echo "❌ No hay repositorios configurados"
  exit 1
fi


for repo in "${REPOSITORIES[@]}"; do
  if [[ -n "$repo" && "$repo" != *"/"* ]]; then
    echo "⚠️ Saltando repositorio mal formateado: $repo"
    continue
  fi
  
  process_repository "$repo"
done

echo ""
echo "🎉 Proceso completado!"
echo "📁 Archivos guardados en: $DOWNLOAD_PATH"