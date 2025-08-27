#!/usr/bin/env bash
# =======================================================
# BackupWindows.sh — Backup de disco Windows montado (Linux)
# =======================================================
# Objetivo:
#   - Rodar no Linux e fazer backup de um SSD/HD com Windows montado.
#   - Selecionar arquivos de usuários/pastas conhecidas via config YAML.
#   - Gerar manifest JSON (tokenizado) + inventário de softwares do Windows.
#   - Compactar (7z preferencial; fallback ZIP) e calcular SHA-256 do pacote.
#   - Rotação por keep_last / max_age_days.
#
# Dependências (libs locais):
#   src/Lib/Logging.sh
#   src/Lib/Paths.sh
#   src/Lib/Compression.sh
#   src/Lib/Hashing.sh
#   src/Lib/Manifest.sh
#   src/Lib/Inventory.sh
#
# Requisitos externos:
#   - Opcional: yq (parse YAML mais robusto), jq (validações/relatórios)
#   - 7z/7zz (preferível) ou zip/unzip
#   - hivexregedit (opcional p/ inventário via Registro)
#
# Segurança:
#   - Suporte a criptografia 7z: BACKUP_ENCRYPTION=1 + BACKUP_PASSWORD no ambiente.
#   - Se config apontar password_env, a senha será lida desse env e NUNCA logada.
# =======================================================

set -euo pipefail

# ---------- Caminhos base ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/Lib"

# ---------- Import de libs ----------
# shellcheck disable=SC1091
source "$LIB_DIR/Logging.sh"
source "$LIB_DIR/Paths.sh"
source "$LIB_DIR/Compression.sh"
source "$LIB_DIR/Hashing.sh"
source "$LIB_DIR/Manifest.sh"
source "$LIB_DIR/Inventory.sh"

# ---------- Parâmetros ----------
CONFIG_PATH="${1:-$SCRIPT_DIR/../config/backup.config.yaml}"
DRY_RUN=false
FORCE=false
LOG_DEST=""
WIN_MOUNT_OVERRIDE=""
NO_INVENTORY=0

print_help() {
  cat <<EOF
Uso: $0 [config.yaml] [--dry-run] [--force] [--log-file <arquivo>] [--win-mount <pasta>] [--no-inventory]
Opções:
  --dry-run              Simula (não copia/compacta); mostra estatísticas.
  --force                Prossegue mesmo com avisos (ex.: rotação/limpezas).
  --log-file <arquivo>   Grava log detalhado no arquivo indicado.
  --win-mount <pasta>    Sobrescreve WIN_MOUNT da config/ambiente.
  --no-inventory         Não coletar inventário de softwares.
  -h, --help             Ajuda.
Exemplo:
  WIN_MOUNT=/media/win BACKUP_ENCRYPTION=1 BACKUP_PASSWORD='***' \\
  $0 ../config/backup.config.yaml --log-file /var/log/winbackup.log
EOF
}

parse_args() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --force)   FORCE=true; shift ;;
      --log-file) LOG_DEST="${2:?}"; shift 2 ;;
      --win-mount) WIN_MOUNT_OVERRIDE="${2:?}"; shift 2 ;;
      --no-inventory) NO_INVENTORY=1; shift ;;
      -h|--help) print_help; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ ${#args[@]} -gt 0 ]]; then
    CONFIG_PATH="${args[0]}"
  fi
}

# ---------- Leitura de configuração ----------
# Fallback simples quando não há yq disponível
_cfg_scalar() {
  local key="$1" file="$2"
  if command -v yq >/dev/null 2>&1; then
    yq e "$key" "$file"
  else
    local pat="${key#.}"
    awk -v k="^${pat}:" '$0 ~ k { sub(/^[^:]+:[[:space:]]*/,""); print; exit }' "$file"
  fi
}

_cfg_list() {
  local key="$1" file="$2"
  if command -v yq >/dev/null 2>&1; then
    yq e "$key[]" "$file" 2>/dev/null | sed '/^null$/d' || true
  else
    local pat="${key#.}"
    awk -v k="^${pat}:" '
      f==0 && $0 ~ k { f=1; next }
      f==1 {
        if ($0 ~ /^[^[:space:]-]/) exit
        if ($0 ~ /^[[:space:]]*-[[:space:]]+/) { sub(/^[[:space:]]*-[[:space:]]+/,""); print }
      }' "$file" || true
  fi
}

# Variáveis carregadas da config
BACKUP_ROOT=""
KEEP_LAST=0
MAX_AGE_DAYS=0
BK_PREFIX="winbackup"
ENCRYPTION_ENABLED="false"
ENCRYPTION_ENV_VAR=""

load_config() {
  [[ -f "$CONFIG_PATH" ]] || { log_error "Config não encontrada: $CONFIG_PATH"; exit 2; }
  log_info "Carregando config: $CONFIG_PATH"

  BACKUP_ROOT="$(_cfg_scalar '.backup_root' "$CONFIG_PATH" | sed 's/"//g')"
  [[ -z "$BACKUP_ROOT" ]] && { log_error "backup_root ausente na config."; exit 2; }

  KEEP_LAST="$(_cfg_scalar '.rotation.keep_last' "$CONFIG_PATH" | sed 's/"//g')"
  [[ -z "$KEEP_LAST" ]] && KEEP_LAST=0

  MAX_AGE_DAYS="$(_cfg_scalar '.rotation.max_age_days' "$CONFIG_PATH" | sed 's/"//g')"
  [[ -z "$MAX_AGE_DAYS" ]] && MAX_AGE_DAYS=0

  ENCRYPTION_ENABLED="$(_cfg_scalar '.encryption.enabled' "$CONFIG_PATH" | sed 's/"//g' | tr 'A-Z' 'a-z')"
  ENCRYPTION_ENV_VAR="$(_cfg_scalar '.encryption.password_env' "$CONFIG_PATH" | sed 's/"//g')"

  local cfg_prefix="$(_cfg_scalar '.rotation.prefix' "$CONFIG_PATH" | sed 's/"//g')"
  [[ -n "$cfg_prefix" && "$cfg_prefix" != "null" ]] && BK_PREFIX="$cfg_prefix"

  mkdir -p "$BACKUP_ROOT"
  log_info "backup_root: $BACKUP_ROOT | keep_last: $KEEP_LAST | max_age_days: $MAX_AGE_DAYS"

  # WIN_MOUNT
  if [[ -n "$WIN_MOUNT_OVERRIDE" ]]; then
    export WIN_MOUNT="$WIN_MOUNT_OVERRIDE"
  fi
  init_win_mount "$CONFIG_PATH"

  # Log
  if [[ -n "$LOG_DEST" ]]; then
    log_init "$LOG_DEST"
    log_info "Log em: $LOG_DEST"
  fi

  # Criptografia 7z (opcional)
  if [[ "$ENCRYPTION_ENABLED" == "true" ]]; then
    export BACKUP_ENCRYPTION=1
    if [[ -n "$ENCRYPTION_ENV_VAR" ]]; then
      # Não logar valor
      if [[ -n "${!ENCRYPTION_ENV_VAR:-}" ]]; then
        export BACKUP_PASSWORD="${!ENCRYPTION_ENV_VAR}"
        log_info "Criptografia habilitada (senha via env: $ENCRYPTION_ENV_VAR)."
      else
        log_error "encryption.enabled=true mas variável $ENCRYPTION_ENV_VAR não está definida no ambiente."
        exit 2
      fi
    else
      # Permite BACKUP_PASSWORD já exportada manualmente
      if [[ -z "${BACKUP_PASSWORD:-}" ]]; then
        log_error "encryption.enabled=true e sem password_env. Exporte BACKUP_PASSWORD manualmente."
        exit 2
      fi
      log_info "Criptografia habilitada (senha via BACKUP_PASSWORD)."
    fi
  else
    export BACKUP_ENCRYPTION=0
  fi
}

# ---------- Preparação ----------
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
ABS_LIST_FILE="$(mktemp -t abslist_XXXX.txt)"
MANIFEST_FILE="$(mktemp -t manifest_XXXX.json)"
ARCHIVE_PATH=""
STATS_TOTAL_FILES=0
STATS_TOTAL_BYTES=0

prepare_workdirs() {
  STAGING_DIR="$BACKUP_ROOT/${BK_PREFIX}_${TIMESTAMP}"
  ABS_LIST_FILE="$STAGING_DIR/.files_abs.list"
  mkdir -p "$STAGING_DIR/files"
  log_info "Staging: $STAGING_DIR"
}

# ---------- Seleção de arquivos a partir da config (Paths.sh) ----------
collect_abs_file_list() {
  log_info "Selecionando arquivos do Windows montado (config)…"
  resolve_file_set_from_config "$CONFIG_PATH" > "$ABS_LIST_FILE" || true
  local total_bytes=0

  if [[ ! -s "$ABS_LIST_FILE" ]]; then
    log_warn "Nenhum arquivo selecionado. Verifique includes.known_folders / users."
  fi

  if [[ -s "$ABS_LIST_FILE" ]]; then
    STATS_TOTAL_FILES=$(wc -l < "$ABS_LIST_FILE")
    total_bytes=$(xargs -a "$ABS_LIST_FILE" stat -c '%s' 2>/dev/null | awk '{s+=$1} END{print s}')
  fi
  STATS_TOTAL_BYTES=$total_bytes
  log_info "Arquivos: ${STATS_TOTAL_FILES:-0} | Tamanho total ≈ $(numfmt --to=iec $total_bytes)B"
}

check_space_backup() {
  local free_bytes
  free_bytes=$(df -PB1 "$BACKUP_ROOT" | awk 'NR==2{print $4}')
  log_info "Espaço livre em $BACKUP_ROOT: $(numfmt --to=iec $free_bytes)B"
  if (( free_bytes < STATS_TOTAL_BYTES )); then
    log_error "Espaço insuficiente: necessário ≥ $(numfmt --to=iec $STATS_TOTAL_BYTES)B"
    [[ "$FORCE" == true ]] || exit 1
  fi
}


# ---------- Manifest ----------
write_manifest() {
  log_info "Gerando manifest: $manifest"
  if [[ "$DRY_RUN" == true ]]; then
    log_debug "[DRY] criaria manifest a partir da lista de absolutos."
    return 0
  fi
  create_manifest "$MANIFEST_FILE" < "$ABS_LIST_FILE"
}

# ---------- Inventário ----------
write_inventory() {
  [[ "$NO_INVENTORY" -eq 1 ]] && { log_info "Inventário desabilitado (--no-inventory)."; return 0; }
  if [[ "$DRY_RUN" == true ]]; then
    log_debug "[DRY] coletaria inventário em `/tmp/inventory.json` e `/tmp/inventory.md`"
    return 0
  fi
  collect_inventory_windows_mounted "/tmp/inventory.json" "/tmp/inventory.md"
}

# ---------- Compactação ----------
compress_backup() {
  local has7z=0; detect_7z >/dev/null 2>&1 && has7z=1
  if [[ "$has7z" == "1" ]]; then ARCHIVE_PATH="$BACKUP_ROOT/${BK_PREFIX}_${TIMESTAMP}.7z"
  else ARCHIVE_PATH="$BACKUP_ROOT/${BK_PREFIX}_${TIMESTAMP}.zip"; fi

  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY] Criaria arquivo: $ARCHIVE_PATH"
    return 0
  fi

  if [[ "$has7z" == "1" ]]; then
    compress_with_7z_list "$ABS_LIST_FILE" "$ARCHIVE_PATH"
    7z u "$ARCHIVE_PATH" "$MANIFEST_FILE" "/tmp/inventory.json" "/tmp/inventory.md" "$CONFIG_PATH"
  else
    compress_with_zip "$STAGING_DIR" "$ARCHIVE_PATH"
  fi

  # Hash do arquivo compactado
  local hash_file="${ARCHIVE_PATH}.sha256"
  local h
  h="$(sha256_of "$ARCHIVE_PATH")"
  echo "${h}  $(basename "$ARCHIVE_PATH")" > "$hash_file"
  log_info "SHA-256 do pacote: $h (salvo em $(basename "$hash_file"))"
}

# ---------- Rotação ----------
rotate_backups() {
  log_info "Aplicando rotação em $BACKUP_ROOT (keep_last=$KEEP_LAST, max_age_days=$MAX_AGE_DAYS)…"
  mapfile -t packs < <(ls -1t "$BACKUP_ROOT"/${BK_PREFIX}_*.7z "$BACKUP_ROOT"/${BK_PREFIX}_*.zip 2>/dev/null || true)
  if (( ${#packs[@]} > KEEP_LAST )); then
    local to_del=("${packs[@]:$KEEP_LAST}")
    for p in "${to_del[@]}"; do rm -f "$p" "$p.sha256"; done
  fi
}

# ---------- Main ----------
main() {
  parse_args "$@"
  log_set_level "${LOG_LEVEL:-INFO}"
  [[ -n "$LOG_DEST" ]] && log_init "$LOG_DEST"

  load_config
  collect_abs_file_list
  check_space_backup

  [[ "$DRY_RUN" == true ]] && {log_warn "[DRY-RUN] Simulação — nada será copiado/compactado/removido."; exit 0;}

  write_manifest
  write_inventory
  compress_backup
  rotate_backups

  log_info "Backup concluído: $ARCHIVE_PATH"
}

main "$@"
