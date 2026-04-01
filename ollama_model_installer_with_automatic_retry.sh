#!/bin/bash
# down_install_safe.sh - Descarga modelos Ollama en carpeta relativa y copia segura a Ollama
# Versión modificada - Elimina run_model.sh y crea modelo directamente en Ollama

set -e

# Colores para output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Funciones de logging
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Uso
show_usage() { echo "Uso: $0 <nombre-modelo> <tag>"; exit 1; }

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

# Guardar el directorio actual para referencias posteriores
CURRENT_DIR="$(pwd)"

while read BLOB_HASH; do
    CURRENT=$((CURRENT+1))
    # Usar ruta absoluta para el blob
    BLOB_FILE="${BLOBS_DIR}/sha256-${BLOB_HASH}"
    BLOB_URL="${REGISTRY}/v2/library/${MODEL_NAME}/blobs/sha256:${BLOB_HASH}"
    
    print_info "[$CURRENT/$TOTAL_BLOBS] Descargando/Reanudando: sha256:${BLOB_HASH:0:16}..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Blob $CURRENT/$TOTAL_BLOBS: $BLOB_HASH" >> "$LOG_FILE"
    
    # Verificar si el archivo ya existe y parece completo
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
    
    # Asegurar que el directorio existe
    mkdir -p "$(dirname "$BLOB_FILE")"
    
    # Descargar con wget -c
    if wget -c --progress=bar:force --timeout=30 --tries=5 --retry-connrefused \
        "$BLOB_URL" -O "$BLOB_FILE" 2>&1; then
        
        # Verificar tamaño después
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
# 4. Generar Modelfile
# -------------------------------
FIRST_BLOB=$(head -1 "$BLOBS_LIST")
MODELFILE="Modelfile"

if command -v jq &> /dev/null; then
    TEMPLATE=$(jq -r '.config.template // empty' "$MANIFEST_FILE" 2>/dev/null)
    PARAMETERS=$(jq -r '.config.parameters // empty' "$MANIFEST_FILE" 2>/dev/null)
    SYSTEM=$(jq -r '.config.system // empty' "$MANIFEST_FILE" 2>/dev/null)
else
    TEMPLATE=""; PARAMETERS=""; SYSTEM=""
fi

cat > "$MODELFILE" << EOF
# Modelfile para ${MODEL_NAME}:${MODEL_TAG}
FROM ./blobs/sha256-${FIRST_BLOB}
EOF

[ -n "$TEMPLATE" ] && [ "$TEMPLATE" != "null" ] && cat >> "$MODELFILE" << EOF
TEMPLATE """${TEMPLATE}"""
EOF

[ -n "$SYSTEM" ] && [ "$SYSTEM" != "null" ] && cat >> "$MODELFILE" << EOF
SYSTEM """${SYSTEM}"""
EOF

[ -n "$PARAMETERS" ] && [ "$PARAMETERS" != "null" ] && cat >> "$MODELFILE" << EOF
${PARAMETERS}
EOF

print_success "Modelfile generado: $MODELFILE"

# Crear enlace simbólico a blobs
BLOBS_LINK="blobs"
[ ! -L "$BLOBS_LINK" ] && ln -s "blobs" "$BLOBS_LINK" && print_info "Enlace simbólico creado: $BLOBS_LINK -> blobs"

# -------------------------------
# 5. Copiar todo a Ollama
# -------------------------------
OLLAMA_DIR="$HOME/.ollama/models/${LOCAL_MODEL_NAME}"
mkdir -p "$OLLAMA_DIR"
cp -r "$WORK_DIR"/* "$OLLAMA_DIR/"
print_success "Modelo copiado a Ollama: $OLLAMA_DIR"

# -------------------------------
# 6. Crear el modelo en Ollama (similar a crear_modelo.sh)
# -------------------------------
print_info "Creando modelo en Ollama..."

# Obtener el primer blob (el principal del modelo)
MODEL_BLOB="${OLLAMA_DIR}/blobs/sha256-${FIRST_BLOB}"

# Verificar que existe el modelo
if [ ! -f "$MODEL_BLOB" ]; then
    print_error "No se encuentra el modelo en $MODEL_BLOB"
    exit 1
fi

MODEL_SIZE=$(du -h "$MODEL_BLOB" | cut -f1)
print_success "Modelo encontrado (tamaño: $MODEL_SIZE)"

# Crear Modelfile temporal con configuración optimizada
TEMP_MODELFILE="/tmp/Modelfile-${SANITIZED_NAME}"

print_info "Creando Modelfile optimizado..."

# Intentar extraer información del manifiesto original
if command -v jq &> /dev/null; then
    ORIGINAL_TEMPLATE=$(jq -r '.config.template // empty' "$MANIFEST_FILE" 2>/dev/null)
    ORIGINAL_SYSTEM=$(jq -r '.config.system // empty' "$MANIFEST_FILE" 2>/dev/null)
    ORIGINAL_PARAMETERS=$(jq -r '.config.parameters // empty' "$MANIFEST_FILE" 2>/dev/null)
else
    ORIGINAL_TEMPLATE=""; ORIGINAL_SYSTEM=""; ORIGINAL_PARAMETERS=""
fi

# Crear Modelfile con configuración mejorada
cat > "$TEMP_MODELFILE" << EOF
# Modelo ${MODEL_NAME}:${MODEL_TAG}
FROM ${MODEL_BLOB}

# Parámetros optimizados
PARAMETER temperature 0.7
PARAMETER top_p 0.9
PARAMETER top_k 40
PARAMETER num_ctx 8192
PARAMETER num_predict 2048
PARAMETER repeat_penalty 1.1
EOF

# Añadir template si existe en el manifiesto original
if [ -n "$ORIGINAL_TEMPLATE" ] && [ "$ORIGINAL_TEMPLATE" != "null" ]; then
    cat >> "$TEMP_MODELFILE" << EOF

# Template extraído del manifiesto
TEMPLATE """${ORIGINAL_TEMPLATE}"""
EOF
else
    # Template genérico para modelos tipo Qwen/Llama
    cat >> "$TEMP_MODELFILE" << EOF

# Template genérico (ajustable según el modelo)
TEMPLATE """{{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{- end }}<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
"""
EOF
fi

# Añadir sistema si existe en el manifiesto
if [ -n "$ORIGINAL_SYSTEM" ] && [ "$ORIGINAL_SYSTEM" != "null" ]; then
    cat >> "$TEMP_MODELFILE" << EOF

# Sistema extraído del manifiesto
SYSTEM """${ORIGINAL_SYSTEM}"""
EOF
else
    cat >> "$TEMP_MODELFILE" << EOF

# Mensaje del sistema por defecto
SYSTEM """Eres un asistente útil, respetuoso y honesto."""
EOF
fi

# Añadir parámetros extra si existen
if [ -n "$ORIGINAL_PARAMETERS" ] && [ "$ORIGINAL_PARAMETERS" != "null" ]; then
    cat >> "$TEMP_MODELFILE" << EOF

# Parámetros adicionales del manifiesto
${ORIGINAL_PARAMETERS}
EOF
fi

print_success "Modelfile creado en $TEMP_MODELFILE"

# Crear el modelo en Ollama
print_info "Ejecutando 'ollama create'..."

# Usar el nombre original del modelo (sin sufijo -local) para el comando ollama
FINAL_MODEL_NAME="${MODEL_NAME}:${MODEL_TAG}"

ollama create "$FINAL_MODEL_NAME" -f "$TEMP_MODELFILE"

if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}   ¡Modelo creado exitosamente!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${BLUE}Nombre del modelo:${NC} $FINAL_MODEL_NAME"
    echo -e "${BLUE}Archivos almacenados en:${NC} $OLLAMA_DIR"
    echo -e "\n${YELLOW}Para ejecutar el modelo:${NC}"
    echo -e "  ollama run $FINAL_MODEL_NAME"
    echo -e "\n${YELLOW}Para probar con un prompt:${NC}"
    echo -e "  ollama run $FINAL_MODEL_NAME '¿Cuál es la capital de Francia?'"
    echo -e "\n${YELLOW}Para listar todos tus modelos:${NC}"
    echo -e "  ollama list"
else
    print_error "No se pudo crear el modelo"
    exit 1
fi

# -------------------------------
# 7. Crear README
# -------------------------------
README_FILE="README.md"
cat > "$README_FILE" << EOF
# Modelo: ${MODEL_NAME}:${MODEL_TAG}
- Nombre del modelo en Ollama: ${FINAL_MODEL_NAME}
- Blobs: ${TOTAL_BLOBS}
- Carpeta de archivos: ${OLLAMA_DIR}
- Ejecutar: ollama run ${FINAL_MODEL_NAME}
EOF
print_success "README creado: $README_FILE"

print_success "¡Descarga completa y modelo listo en Ollama!"
