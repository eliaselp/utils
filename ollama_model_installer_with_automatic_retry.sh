#!/bin/bash
# down_install_safe.sh - Descarga modelos Ollama en carpeta relativa y copia segura a Ollama
# Versión modificada - Implementa la lógica completa de 'ollama pull' y 'ollama create'
# Basado en el código fuente oficial de ollama
# FIX: Usa el template original del manifiesto para habilitar tools (FIM para Qwen2.5-Coder)

set -e

# Colores para output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Funciones de logging
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# CONFIGURACIÓN
# =============================================================================

OLLAMA_MODELS="${OLLAMA_MODELS:-$HOME/.ollama/models}"
USER_AGENT="ollama/0.0.0 (linux amd64) go/1.21.0"

# =============================================================================
# UTILIDADES
# =============================================================================

# Calcular SHA256 de un archivo
sha256_file() {
    local file="$1"
    sha256sum "$file" | cut -d' ' -f1
}

# Obtener tamaño de archivo
file_size() {
    local file="$1"
    stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
}

# Formatear tamaño humano
human_size() {
    local bytes="$1"
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        echo "${bytes}B"
    fi
}

# Verificar integridad de blob
verify_blob() {
    local expected_digest="$1"
    local blob_path="$2"
    
    if [[ ! -f "$blob_path" ]]; then
        print_error "Blob no existe: $blob_path"
        return 1
    fi
    
    local computed_digest="sha256:$(sha256_file "$blob_path")"
    
    if [[ "$computed_digest" != "$expected_digest" ]]; then
        print_error "DIGEST MISMATCH"
        print_error "  Esperado: $expected_digest"
        print_error "  Obtenido: $computed_digest"
        rm -f "$blob_path"
        return 1
    fi
    
    print_success "Verificación OK: ${expected_digest:7:12}"
    return 0
}

# Detectar arquitectura del GGUF por magic bytes
detect_architecture_from_gguf() {
    local gguf_file="$1"
    
    if [[ ! -f "$gguf_file" ]]; then
        echo "unknown"
        return
    fi
    
    # Leer magic bytes (primeros 4 bytes)
    local magic
    magic=$(dd if="$gguf_file" bs=1 count=4 2>/dev/null | xxd -p)
    
    if [[ "$magic" != "47475546" ]]; then
        echo "unknown"
        return
    fi
    
    # Buscar arquitectura en el GGUF
    if command -v strings &>/dev/null; then
        local arch
        arch=$(strings "$gguf_file" 2>/dev/null | grep -i "qwen2\|qwen3\|llama\|mistral" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        if [[ -n "$arch" ]]; then
            echo "$arch"
            return
        fi
    fi
    
    echo "unknown"
}

# =============================================================================
# CREAR CONFIG LAYER (create.go:L816-832)
# =============================================================================

create_config_layer() {
    local layers_json="$1"
    local architecture="$2"
    
    print_info "Creando config layer..."
    
    # Extraer digests de layers
    local digests_array
    digests_array=$(echo "$layers_json" | jq -c '[.[].digest]')
    
    # Construir config.json (model/config_v2.go)
    local config_json=$(jq -n \
        --arg renderer "$architecture" \
        --arg parser "$architecture" \
        --arg format "gguf" \
        --arg family "$architecture" \
        --argjson digests "$digests_array" \
        '{
            "renderer": $renderer,
            "parser": $parser,
            "requires": "",
            "model_format": $format,
            "model_family": $family,
            "model_families": [$family],
            "model_type": "llm",
            "file_type": 15,
            "os": "linux",
            "architecture": "amd64",
            "rootfs": {
                "type": "layers",
                "diff_ids": $digests
            }
        }')
    
    # Crear blob temporal
    local config_temp=$(mktemp)
    echo "$config_json" | jq -c '.' > "$config_temp"
    
    local config_digest="sha256:$(sha256_file "$config_temp")"
    local config_size=$(file_size "$config_temp")
    
    local config_blob_path="${OLLAMA_MODELS}/blobs/${config_digest//:/-}"
    mkdir -p "$(dirname "$config_blob_path")"
    mv "$config_temp" "$config_blob_path"
    chmod 644 "$config_blob_path"
    
    print_success "  Config digest: ${config_digest:7:12}, size: $(human_size $config_size)"
    
    echo "$config_digest|$config_size"
}

# =============================================================================
# ESCRIBIR MANIFIESTO LOCAL (manifest/manifest.go:L148-173)
# =============================================================================

write_local_manifest() {
    local host="$1"
    local namespace="$2"
    local model="$3"
    local tag="$4"
    local layers_json="$5"
    local config_digest="$6"
    local config_size="$7"
    
    print_info "Escribiendo manifiesto local..."
    
    local manifest_dir="${OLLAMA_MODELS}/manifests/${host}/${namespace}/${model}"
    mkdir -p "$manifest_dir"
    
    local manifest_path="${manifest_dir}/${tag}"
    
    # Construir manifiesto final
    local manifest_json=$(jq -n \
        --arg config_digest "$config_digest" \
        --argjson config_size "$config_size" \
        --argjson layers "$layers_json" \
        '{
            "schemaVersion": 2,
            "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
            "config": {
                "mediaType": "application/vnd.docker.container.image.v1+json",
                "digest": $config_digest,
                "size": $config_size
            },
            "layers": $layers
        }')
    
    echo "$manifest_json" > "$manifest_path"
    chmod 644 "$manifest_path"
    
    print_success "Manifiesto escrito: $manifest_path"
    echo "$manifest_path"
}

# =============================================================================
# COPIAR BLOB A OLLAMA
# =============================================================================

copy_blob_to_ollama() {
    local source_blob="$1"
    local digest="$2"
    
    local dest_blob="${OLLAMA_MODELS}/blobs/${digest//:/-}"
    mkdir -p "$(dirname "$dest_blob")"
    
    if [[ ! -f "$dest_blob" ]]; then
        cp "$source_blob" "$dest_blob"
        chmod 644 "$dest_blob"
        print_success "Blob copiado: ${digest:7:12}"
    else
        print_info "Blob ya existe: ${digest:7:12}"
    fi
    
    verify_blob "$digest" "$dest_blob"
}

# =============================================================================
# PROCESAR LAYERS Y CREAR MODELO
# =============================================================================

process_layers_and_create_model() {
    local model_name="$1"
    local model_tag="$2"
    local manifest_file="$3"
    local blobs_dir="$4"
    local largest_blob_hash="$5"
    
    print_info "Procesando layers y creando modelo..."
    
    # Extraer layers del manifiesto original
    local layers_json
    layers_json=$(jq -c '.layers' "$manifest_file")
    
    local num_layers
    num_layers=$(echo "$layers_json" | jq 'length')
    print_info "Total layers: $num_layers"
    
    # ============================================================
    # EXTRAER TEMPLATE ORIGINAL DEL MANIFIESTO (CRÍTICO PARA TOOLS)
    # ============================================================
    local original_template=""
    if command -v jq &>/dev/null; then
        original_template=$(jq -r '.config.template // empty' "$manifest_file" 2>/dev/null)
        if [[ "$original_template" == "null" ]] || [[ -z "$original_template" ]]; then
            original_template=""
        fi
    fi
    
    # Copiar cada blob a la ubicación de Ollama
    local processed_layers="[]"
    local layer_idx=0
    local has_template_layer=false
    local has_system_layer=false
    
    while IFS= read -r layer; do
        local digest size media_type
        digest=$(echo "$layer" | jq -r '.digest')
        size=$(echo "$layer" | jq -r '.size // 0')
        media_type=$(echo "$layer" | jq -r '.mediaType // "unknown"')
        
        layer_idx=$((layer_idx + 1))
        
        # Detectar si es capa de template o system
        if [[ "$media_type" == "application/vnd.ollama.image.template" ]]; then
            has_template_layer=true
        fi
        if [[ "$media_type" == "application/vnd.ollama.image.system" ]]; then
            has_system_layer=true
        fi
        
        print_info "Procesando layer $layer_idx: $media_type"
        
        local blob_hash="${digest#sha256:}"
        local source_blob="${blobs_dir}/sha256-${blob_hash}"
        
        if [[ ! -f "$source_blob" ]]; then
            print_error "Blob no encontrado: $source_blob"
            return 1
        fi
        
        copy_blob_to_ollama "$source_blob" "$digest"
        
        processed_layers=$(echo "$processed_layers" | jq --arg d "$digest" --argjson s "$size" --arg m "$media_type" \
            '. + [{"mediaType": $m, "digest": $d, "size": $s}]')
        
    done < <(echo "$layers_json" | jq -c '.[]')
    
    # ============================================================
    # CREAR CAPA DE TEMPLATE CON EL CONTENIDO ORIGINAL (FIM)
    # ============================================================
    # Esto es CRÍTICO para que Qwen2.5-Coder tenga tools
    if [[ -n "$original_template" ]] && [[ "$has_template_layer" == "false" ]]; then
        print_info "Creando capa de template con el template original del manifiesto (soporte FIM/tools)..."
        
        local template_temp=$(mktemp)
        echo -n "$original_template" > "$template_temp"
        local template_digest="sha256:$(sha256_file "$template_temp")"
        local template_size=$(file_size "$template_temp")
        
        local template_blob_path="${OLLAMA_MODELS}/blobs/${template_digest//:/-}"
        mkdir -p "$(dirname "$template_blob_path")"
        mv "$template_temp" "$template_blob_path"
        chmod 644 "$template_blob_path"
        
        # Insertar la capa de template al principio (orden importante)
        processed_layers=$(echo "$processed_layers" | jq --arg d "$template_digest" --argjson s "$template_size" --arg m "application/vnd.ollama.image.template" \
            '[$d] as $d | [$s] as $s | [$m] as $m | . as $layers | [$layers[0]] + [{"mediaType": $m[0], "digest": $d[0], "size": $s[0]}] + $layers[1:]')
        
        print_success "  Template layer creada: ${template_digest:7:12}"
        print_info "  Template content (primeros 200 chars): ${original_template:0:200}..."
    else
        print_info "Template layer ya existe o no se encontró template original"
    fi
    
    # Detectar arquitectura del modelo GGUF
    local model_blob="${blobs_dir}/sha256-${largest_blob_hash}"
    local architecture
    architecture=$(detect_architecture_from_gguf "$model_blob")
    print_info "Arquitectura detectada: $architecture"
    
    # Crear config layer
    local config_result
    config_result=$(create_config_layer "$processed_layers" "$architecture")
    local config_digest="${config_result%%|*}"
    local config_size="${config_result#*|}"
    
    # Escribir manifiesto local
    local host="registry.ollama.ai"
    local namespace="library"
    
    write_local_manifest "$host" "$namespace" "$model_name" "$model_tag" "$processed_layers" "$config_digest" "$config_size"
    
    # Calcular tamaño total
    local total_size=$config_size
    while IFS= read -r layer; do
        local size
        size=$(echo "$layer" | jq -r '.size // 0')
        total_size=$((total_size + size))
    done < <(echo "$processed_layers" | jq -c '.[]')
    
    print_success "========================================"
    print_success "Modelo creado exitosamente!"
    print_success "Nombre: ${model_name}:${model_tag}"
    print_success "Tamaño total: $(human_size $total_size)"
    print_success "========================================"
}

# =============================================================================
# REGISTRAR MODELO EN OLLAMA (ollama create)
# =============================================================================

register_model_with_ollama() {
    local model_name="$1"
    local model_tag="$2"
    local largest_blob_hash="$3"
    local manifest_file="$4"

    print_info "Registrando modelo en la base de datos de Ollama..."

    local model_blob="${OLLAMA_MODELS}/blobs/sha256-${largest_blob_hash}"

    if [[ ! -f "$model_blob" ]]; then
        print_error "Blob del modelo no encontrado: $model_blob"
        return 1
    fi

    # =============================================================================
    # EXTRAER TEMPLATE Y SYSTEM ORIGINALES DEL MANIFIESTO DESCARGADO
    # =============================================================================
    # Esto es CRÍTICO para preservar la capacidad 'tools'

    local template_blob_path=""
    local system_blob_path=""

    # Buscar template en layers
    if command -v jq &>/dev/null; then
        local template_digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.template") | .digest' "$manifest_file" 2>/dev/null)
        if [[ -n "$template_digest" ]]; then
            template_blob_path="${OLLAMA_MODELS}/blobs/${template_digest//:/-}"
        fi

        # Buscar system en layers
        local system_digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.system") | .digest' "$manifest_file" 2>/dev/null)
        if [[ -n "$system_digest" ]]; then
            system_blob_path="${OLLAMA_MODELS}/blobs/${system_digest//:/-}"
        fi
    fi

    # Crear Modelfile temporal PRESERVANDO el template y system originales
    local temp_modelfile=$(mktemp)

    # Escribir FROM
    echo "FROM $model_blob" > "$temp_modelfile"

    # Agregar template original si existe (CRÍTICO para tools)
    if [[ -n "$template_blob_path" ]] && [[ -f "$template_blob_path" ]]; then
        echo "TEMPLATE \"\"\"" >> "$temp_modelfile"
        cat "$template_blob_path" >> "$temp_modelfile"
        echo "\"\"\"" >> "$temp_modelfile"
        print_info "Template original preservado ($(wc -c < "$template_blob_path") bytes)"
    fi

    # Agregar system original si existe, sino usar el default
    if [[ -n "$system_blob_path" ]] && [[ -f "$system_blob_path" ]]; then
        echo "SYSTEM \"\"\"" >> "$temp_modelfile"
        cat "$system_blob_path" >> "$temp_modelfile"
        echo "\"\"\"" >> "$temp_modelfile"
        print_info "System original preservado"
    else
        echo 'SYSTEM """Eres un asistente útil, respetuoso y honesto."""' >> "$temp_modelfile"
    fi

    # Agregar parámetros
    cat >> "$temp_modelfile" << 'PARAMS'
PARAMETER num_ctx 8192
PARAMETER temperature 0.7
PARAMETER top_p 0.9
PARAMETER top_k 40
PARAMETER num_predict 2048
PARAMETER repeat_penalty 1.1
PARAMS
    
    # Eliminar modelo existente si existe
    if ollama list 2>/dev/null | grep -q "^${model_name}:${model_tag}[[:space:]]"; then
        print_warning "Modelo existente encontrado, eliminando..."
        ollama rm "${model_name}:${model_tag}" 2>/dev/null || true
    fi
    
    # Crear el modelo (esto registra en la base de datos de Ollama)
    print_info "Ejecutando ollama create..."
    if ollama create "${model_name}:${model_tag}" -f "$temp_modelfile"; then
        print_success "Modelo registrado exitosamente en Ollama"
        rm -f "$temp_modelfile"
        return 0
    else
        print_error "Error al registrar el modelo"
        rm -f "$temp_modelfile"
        return 1
    fi
}

# =============================================================================
# USO
# =============================================================================

show_usage() { 
    echo "Uso: $0 <nombre-modelo> <tag>"
    echo "Ejemplo: $0 qwen2.5-coder 7b"
    exit 1
}

# Validar argumentos
if [ $# -ne 2 ]; then
    print_error "Se requieren 2 argumentos"
    show_usage
fi

MODEL_NAME="$1"
MODEL_TAG="$2"
REGISTRY="https://registry.ollama.ai"

# Rutas absolutas basadas en el directorio actual
BASE_DIR="$(pwd)/downloads"
MODEL_DIR="${BASE_DIR}/${MODEL_NAME}"
TAG_DIR="${MODEL_DIR}/${MODEL_TAG}"
BLOBS_DIR="${TAG_DIR}/blobs"
WORK_DIR="${TAG_DIR}"

# Nombre local sanitizado para Ollama
SANITIZED_NAME=$(echo "${MODEL_NAME}_${MODEL_TAG}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')
LOCAL_MODEL_NAME="${SANITIZED_NAME}"

print_info "Descargando ${MODEL_NAME}:${MODEL_TAG} en $WORK_DIR"

# Crear directorios
mkdir -p "$WORK_DIR" "$BLOBS_DIR"
cd "$WORK_DIR"
print_success "Estructura de directorios creada: $WORK_DIR"

# -------------------------------
# 1. Descargar manifiesto
# -------------------------------
MANIFEST_FILE="manifest.json"
MANIFEST_URL="${REGISTRY}/v2/library/${MODEL_NAME}/manifests/${MODEL_TAG}"

if [ ! -f "$MANIFEST_FILE" ]; then
    print_info "Descargando manifiesto desde: $MANIFEST_URL"
    wget -c --progress=bar:force --user-agent="Mozilla/5.0" --max-redirect=10 "$MANIFEST_URL" -O "$MANIFEST_FILE"
    print_success "Manifiesto descargado"
else
    print_success "Manifiesto ya existe"
fi

if [ ! -s "$MANIFEST_FILE" ]; then
    print_error "Manifiesto vacío o inválido"
    exit 1
fi

# -------------------------------
# 2. Extraer blobs
# -------------------------------
print_info "Extrayendo blobs..."
BLOBS_LIST="blobs_hashes.txt"

if command -v jq &> /dev/null; then
    jq -r '.config.digest, .layers[].digest' "$MANIFEST_FILE" 2>/dev/null | grep -v null | sed 's/^sha256://' > "$BLOBS_LIST"
else
    grep -o '"digest":"sha256:[^"]*"' "$MANIFEST_FILE" | sed 's/"digest":"sha256://' | tr -d '"' > "$BLOBS_LIST"
fi

TOTAL_BLOBS=$(wc -l < "$BLOBS_LIST")
print_success "Se encontraron $TOTAL_BLOBS blobs"
print_info "Blobs a descargar:"
cat "$BLOBS_LIST" | while read hash; do echo "  - sha256:$hash"; done

# -------------------------------
# 3. Descargar blobs robustamente
# -------------------------------
print_info "Descargando blobs..."
CURRENT=0
FAILED=0
LOG_FILE="download.log"

while read BLOB_HASH; do
    CURRENT=$((CURRENT+1))
    BLOB_FILE="${BLOBS_DIR}/sha256-${BLOB_HASH}"
    BLOB_URL="${REGISTRY}/v2/library/${MODEL_NAME}/blobs/sha256:${BLOB_HASH}"
    
    print_info "[$CURRENT/$TOTAL_BLOBS] Descargando/Reanudando: sha256:${BLOB_HASH:0:16}..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Blob $CURRENT/$TOTAL_BLOBS: $BLOB_HASH" >> "$LOG_FILE"
    
    if [ -f "$BLOB_FILE" ]; then
        if command -v jq &> /dev/null; then
            EXPECTED_SIZE=$(jq -r ".layers[] | select(.digest == \"sha256:${BLOB_HASH}\") | .size // empty" "$MANIFEST_FILE" 2>/dev/null)
            ACTUAL_SIZE=$(stat -c%s "$BLOB_FILE" 2>/dev/null || stat -f%z "$BLOB_FILE" 2>/dev/null)
            if [ -n "$EXPECTED_SIZE" ] && [ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]; then
                print_success "Blob $CURRENT/$TOTAL_BLOBS ya existe y está completo (${ACTUAL_SIZE} bytes)"
                continue
            elif [ -n "$EXPECTED_SIZE" ]; then
                print_warning "Blob incompleto: ${ACTUAL_SIZE}/${EXPECTED_SIZE} bytes, reanudando..."
            fi
        fi
    fi
    
    mkdir -p "$(dirname "$BLOB_FILE")"
    
    if wget -c --progress=bar:force --timeout=30 --tries=5 --retry-connrefused \
        "$BLOB_URL" -O "$BLOB_FILE" 2>&1; then
        
        if command -v jq &> /dev/null; then
            EXPECTED_SIZE=$(jq -r ".layers[] | select(.digest == \"sha256:${BLOB_HASH}\") | .size // empty" "$MANIFEST_FILE" 2>/dev/null)
            ACTUAL_SIZE=$(stat -c%s "$BLOB_FILE" 2>/dev/null || stat -f%z "$BLOB_FILE" 2>/dev/null)
            if [ -n "$EXPECTED_SIZE" ] && [ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]; then
                print_success "Blob $CURRENT/$TOTAL_BLOBS completado y verificado (${ACTUAL_SIZE} bytes)"
            else
                print_warning "Blob $CURRENT/$TOTAL_BLOBS descargado pero tamaño no verificado"
            fi
        else
            print_success "Blob $CURRENT/$TOTAL_BLOBS descargado/reanudado"
        fi
    else
        print_error "Error descargando blob $BLOB_HASH"
        FAILED=$((FAILED+1))
        echo "[ERROR] Falló descarga de $BLOB_HASH" >> "$LOG_FILE"
    fi
    
    sleep 1
done < "$BLOBS_LIST"

if [ $FAILED -gt 0 ]; then
    print_error "$FAILED blobs fallaron. Reintenta el script"
    exit 1
fi
print_success "Todos los blobs descargados correctamente"

# -------------------------------
# 4. Identificar el blob del modelo (el más grande)
# -------------------------------
print_info "Identificando el blob del modelo (el más grande)..."

LARGEST_BLOB_FILE=$(ls -S "${BLOBS_DIR}/sha256-"* 2>/dev/null | head -1)

if [ -z "$LARGEST_BLOB_FILE" ]; then
    print_error "No se encontraron blobs en ${BLOBS_DIR}"
    exit 1
fi

LARGEST_BLOB_HASH=$(basename "$LARGEST_BLOB_FILE" | sed 's/^sha256-//')
LARGEST_BLOB_SIZE=$(stat -c%s "$LARGEST_BLOB_FILE" 2>/dev/null || stat -f%z "$LARGEST_BLOB_FILE" 2>/dev/null)
LARGEST_BLOB_SIZE_HUMAN=$(numfmt --to=iec --suffix=B "$LARGEST_BLOB_SIZE" 2>/dev/null || echo "${LARGEST_BLOB_SIZE} bytes")

print_success "Blob del modelo identificado: sha256-${LARGEST_BLOB_HASH:0:16}... (tamaño: ${LARGEST_BLOB_SIZE_HUMAN})"

# -------------------------------
# 5. Crear directorios necesarios en Ollama
# -------------------------------
mkdir -p "${OLLAMA_MODELS}/blobs"
mkdir -p "${OLLAMA_MODELS}/manifests"

# -------------------------------
# 6. Procesar layers y crear modelo
# -------------------------------
process_layers_and_create_model "$MODEL_NAME" "$MODEL_TAG" "$MANIFEST_FILE" "$BLOBS_DIR" "$LARGEST_BLOB_HASH"

# -------------------------------
# 7. Registrar modelo en Ollama (IMPORTANTE para que ollama show funcione)
# -------------------------------
register_model_with_ollama "$MODEL_NAME" "$MODEL_TAG" "$LARGEST_BLOB_HASH" "$MANIFEST_FILE"

# -------------------------------
# 8. Verificar que el modelo tiene tools
# -------------------------------
echo ""
print_info "Verificando capacidades del modelo..."

if ollama show "${MODEL_NAME}:${MODEL_TAG}" 2>/dev/null | grep -q "tools"; then
    print_success "✅ TOOLS HABILITADAS correctamente!"
else
    print_warning "⚠️  Tools no detectadas en ollama show"
    print_info "Verifica manualmente con: ollama show ${MODEL_NAME}:${MODEL_TAG}"
    print_info "También puedes ver el Modelfile con: ollama show ${MODEL_NAME}:${MODEL_TAG} --modelfile"
fi

# -------------------------------
# 9. Crear README
# -------------------------------
README_FILE="README.md"
cat > "$README_FILE" << EOF
# Modelo: ${MODEL_NAME}:${MODEL_TAG}
- Nombre del modelo: ${MODEL_NAME}:${MODEL_TAG}
- Blobs descargados: ${TOTAL_BLOBS}
- Blob del modelo: sha256-${LARGEST_BLOB_HASH} (${LARGEST_BLOB_SIZE_HUMAN})
- Ubicación manifiesto: ${OLLAMA_MODELS}/manifests/registry.ollama.ai/library/${MODEL_NAME}/${MODEL_TAG}
- Ejecutar: ollama run ${MODEL_NAME}:${MODEL_TAG}
EOF

print_success "README creado: $README_FILE"
print_success "¡Modelo listo en Ollama!"
echo ""
print_info "Para ejecutar: ollama run ${MODEL_NAME}:${MODEL_TAG}"
