#!/usr/bin/env bash
# =======================================================
# RestoreWindows.sh — Restaura backup para disco Windows montado (Linux)
# =======================================================
# Objetivo:
#   - Rodar no Linux e restaurar um backup gerado pelo BackupWindows.sh
#     para um SSD/HD com Windows montado.
#   - Suporta: .7z/.zip ou diretório de staging já extraído.
#   - Resolve {{Tokens}} → caminhos reais no alvo (WIN_MOUNT), com
#     opção de mapear usuários (ex.: --user-map Old:New).
#   - Dry-run, verificação de manifest/hashes, controle de overwrite.
#
# Estrutura esperada do pacote/diretório:
#   <root>/
#     manifest.json
#     files/<token_path>                # conteúdo real
#     InstalledSoftware*.{json,md}      # inventário (informativo)
#     backup_meta.json / backup.config.effective.yaml
#
# Dependências (libs locais):
#   src/Lib/Logging.sh
#   src/Lib/Paths.sh
#   src/Lib/Compression.sh
#   src/Lib/Hashing.sh
#   src/Lib/Manifest.sh
#
# Requisitos externos:
#   - jq (obrigatório para ler manifest.json)
#   - 7z/7zz (para extrair .7z) ou unzip (para .zip)
#
# Segurança:
#   - Se o pacote for 7z cifrado: export BACKUP_PASSWORD e BACKUP_ENCRYPTION=1.
# =======================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/Lib"

# ---------- Import de libs ----------
# shellcheck disable=SC1091
source "$LIB_DIR/Logging.sh"
source "$LIB_DIR/Paths.sh"
source "$LIB_DIR/Compression.sh"
source "$LIB_DIR/Hashing.sh"
source "$LIB_DIR/Manifest.sh"

# ---------- Parâmetros ----------
ARCHIVE_OR_DIR=""
CONFIG_PATH="${SCRIPT_DIR}/../config/backup.config.yaml"
WIN_MOUNT_OVERRIDE=""
DRY_RUN=false
FORCE=false
ASSUME_YES=false
VERIFY_ONLY=false
SKIP_VERIFY=false
KEEP_EXTRACTED=false
CHECK_ARCHIVE_HASH=false
LOG_DEST=""
ONLY_USER=""
ONLY_FOLDER=""
declare -A USER_MAP=()   # old_user -> new_user


print_help() {
  cat <<EOF
Uso: $0 --source <arquivo.7z|arquivo.zip|diretorio> [opções]
Opções:
  --source <path>         Pacote .7z/.zip gerado no backup ou diretório já extraído.
  --config <config.yaml>  Usado para resolver WIN_MOUNT e defaults (padrão: ${CONFIG_PATH}).
  --win-mount <dir>       Sobrescreve WIN_MOUNT (ex.: /media/WIN).
  --only-user <nome>      Restaura apenas arquivos desse usuário.
  --only-folder <nome>    Restaura apenas uma pasta conhecida (ex.: Documents).
  --user-map A:B          Mapeia usuário de origem (A) para destino (B). Pode repetir.
  --dry-run               Simula sem escrever no disco.
  --force                 Sobrescreve arquivos existentes sem perguntar.
  --assume-yes            Assume 'sim' para prompts não críticos (criação de diretórios).
  --verify-only           Apenas valida manifest/hashes, sem copiar.
  --skip-verify           Pula validação de manifest/hashes antes de copiar.
  --check-archive-hash    Se existir <arquivo>.sha256, valida o pacote antes de extrair.
  --keep-extracted        Mantém pasta temporária extraída.
  --log-file <arquivo>    Grava log detalhado nesse arquivo.
  -h, --help              Ajuda.

Exemplos:
  WIN_MOUNT=/media/win BACKUP_ENCRYPTION=1 BACKUP_PASSWORD='***' \\
    $0 --source /backups/winbackup_20250827_120000.7z --log-file /var/log/restore.log

  $0 --source /tmp/restore_root --win-mount /media/WIN --user-map Harrison:Admin
EOF
}

parse_args() {
  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --source)            ARCHIVE_OR_DIR="${args[$((i+1))]}"; i=$((i+2)) ;;
      --config)            CONFIG_PATH="${args[$((i+1))]}"; i=$((i+2)) ;;
      --win-mount)         WIN_MOUNT_OVERRIDE="${args[$((i+1))]}"; i=$((i+2)) ;;
      --user-map)
        local m="${args[$((i+1))]}"; [[ "$m" == *:* ]] || { log_error "--user-map requer formato Old:New"; exit 2; }
        USER_MAP["${m%%:*}"]="${m##*:}"
        i=$((i+2))
        ;;
      --only-user) ONLY_USER="${args[$((i+1))]}"; i=$((i+2));;
      --only-folder) ONLY_FOLDER="${args[$((i+1))]}"; i=$((i+2));;
      --dry-run)           DRY_RUN=true; i=$((i+1)) ;;
      --force)             FORCE=true; i=$((i+1)) ;;
      --assume-yes)        ASSUME_YES=true; i=$((i+1)) ;;
      --verify-only)       VERIFY_ONLY=true; i=$((i+1)) ;;
      --skip-verify)       SKIP_VERIFY=true; i=$((i+1)) ;;
      --check-archive-hash)CHECK_ARCHIVE_HASH=true; i=$((i+1)) ;;
      --keep-extracted)    KEEP_EXTRACTED=true; i=$((i+1)) ;;
      --log-file)          LOG_DEST="${args[$((i+1))]}"; i=$((i+2)) ;;
      -h|--help)           print_help; exit 0 ;;
      *) log_error "Parâmetro desconhecido: ${args[$i]}"; exit 2 ;;
    esac
  done
  [[ -n "$ARCHIVE_OR_DIR" ]] || { log_error "Obrigatório informar --source"; exit 2; }
}


# ---------- Config / WIN_MOUNT ----------
_cfg_scalar() {
  local key="$1" file="$2"
  if command -v yq >/dev/null 2>&1; then
    yq e "$key" "$file"
  else
    local pat="${key#.}"
    awk -v k="^${pat}:" '$0 ~ k { sub(/^[^:]+:[[:space:]]*/,""); print; exit }' "$file"
  fi
}

load_env_and_mount() {
  if [[ -n "$WIN_MOUNT_OVERRIDE" ]]; then
    export WIN_MOUNT="$WIN_MOUNT_OVERRIDE"
  fi
  init_win_mount "$CONFIG_PATH"   # valida e informa
  if [[ -n "$LOG_DEST" ]]; then
    log_init "$LOG_DEST"
    log_info "Log em: $LOG_DEST"
  fi
  command -v jq >/dev/null 2>&1 || { log_error "jq é obrigatório para restaurar (instale jq)."; exit 2; }
}

# ---------- Extração / Raiz do pacote ----------
RESTORE_ROOT=""
EXTRACT_TMP=""
detect_root_from_dir() {
  local d="$1"
  if [[ -f "$d/manifest.json" && -d "$d/files" ]]; then RESTORE_ROOT="$d"; return 0; fi
  local sub
  sub="$(find "$d" -maxdepth 2 -type f -name manifest.json -printf '%h\n' 2>/dev/null | head -n1 || true)"
  [[ -n "$sub" && -d "$sub/files" ]] && RESTORE_ROOT="$sub" && return 0
  return 1
}

extract_if_needed() {
  if [[ -d "$ARCHIVE_OR_DIR" ]]; then
    log_info "Fonte é diretório: $ARCHIVE_OR_DIR"
    detect_root_from_dir "$ARCHIVE_OR_DIR" || { log_error "Estrutura inválida. Espera-se manifest.json e files/"; exit 2; }
    return 0
  fi

  [[ -f "$ARCHIVE_OR_DIR" ]] || { log_error "Arquivo não encontrado: $ARCHIVE_OR_DIR"; exit 2; }

  # (opcional) confere hash do pacote
  if [[ "$CHECK_ARCHIVE_HASH" == true && -f "${ARCHIVE_OR_DIR}.sha256" ]]; then
    log_info "Verificando hash do pacote…"
    local expected cur
    expected="$(awk '{print $1}' "${ARCHIVE_OR_DIR}.sha256" | head -n1)"
    cur="$(sha256_of "$ARCHIVE_OR_DIR")"
    if [[ "$expected" != "$cur" ]]; then
      log_error "Hash do pacote divergente. Esperado=$expected Obtido=$cur"
      exit 1
    fi
    log_info "Hash do pacote OK."
  fi

  EXTRACT_TMP="$(mktemp -d -t winrestore_XXXX)"
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY] Extração seria feita para: $EXTRACT_TMP"
    RESTORE_ROOT="$EXTRACT_TMP"  # marcar um root simulado
    return 0
  fi

  case "$ARCHIVE_OR_DIR" in
    *.7z) extract_with_7z "$ARCHIVE_OR_DIR" "$EXTRACT_TMP" ;;
    *.zip) extract_with_zip "$ARCHIVE_OR_DIR" "$EXTRACT_TMP" ;;
    *) log_error "Formato não suportado: $ARCHIVE_OR_DIR"; exit 2 ;;
  esac

  detect_root_from_dir "$EXTRACT_TMP" || { log_error "Pacote extraído sem manifest/files válidos."; exit 2; }
  log_info "Conteúdo extraído em: $RESTORE_ROOT"
}

cleanup_extract_tmp() {
  [[ -n "$EXTRACT_TMP" && -d "$EXTRACT_TMP" ]] || return 0
  [[ "$KEEP_EXTRACTED" == true || "$DRY_RUN" == true ]] || {log_info "Mantendo pasta extraída: $EXTRACT_TMP"; return 0;}
  rm -rf "$EXTRACT_TMP" || true
}

check_space_restore() {
  local manifest="$RESTORE_ROOT/manifest.json"
  [[ -f "$manifest" ]] || { log_error "Manifest não encontrado"; exit 2; }
  local total_restore
  total_restore=$(jq '[.[].size] | add' "$manifest")
  if [[ -n "$ONLY_USER" ]]; then
    total_restore=$(jq --arg u "$ONLY_USER" '[.[] | select(.user==$u) | .size] | add' "$manifest")
  fi
  if [[ -n "$ONLY_FOLDER" ]]; then
    total_restore=$(jq --arg f "$ONLY_FOLDER" '[.[] | select(.known_folder==$f) | .size] | add' "$manifest")
  fi
  total_restore=${total_restore:-0}
  local free_bytes
  free_bytes=$(df -PB1 "$WIN_MOUNT" | awk 'NR==2{print $4}')
  log_info "Espaço livre em $WIN_MOUNT: $(numfmt --to=iec $free_bytes)B"
  log_info "Necessário restaurar: $(numfmt --to=iec $total_restore)B"
  if (( free_bytes < total_restore )); then
    log_error "Espaço insuficiente no destino"
    [[ "$FORCE" == true ]] || exit 1
  fi
}

# ---------- Verificação do manifest/hashes ----------
validate_before_copy() {
  if [[ "$SKIP_VERIFY" == true ]]; then
    log_warn "Validação de manifest/hashes foi ignorada (--skip-verify)."
    return 0
  fi
  local man="$RESTORE_ROOT/manifest.json"
  validate_manifest_hashes "$man" "$RESTORE_ROOT"
}

# ---------- User map / resolução de destino ----------
_map_user() {
  local old="$1"
  if [[ -n "${USER_MAP[$old]+_}" ]]; then
    echo "${USER_MAP[$old]}"
  else
    echo "$old"
  fi
}

resolve_target_abs() {
  # $1 token_path ; $2 old_user
  local token_path="$1"
  local old_user="$2"
  local new_user; new_user="$(_map_user "$old_user")"
  map_token_to_abs_path "$token_path" "$new_user"
}

# ---------- Copiador preservando timestamps ----------
_copy_file_preserve() {
  # $1 src ; $2 dst
  local src="$1" dst="$2"
  local dst_dir; dst_dir="$(dirname "$dst")"

  if [[ "$DRY_RUN" == true ]]; then
    log_debug "[DRY] criaria dir: $dst_dir (se necessário)"
    log_debug "[DRY] copiaria: $src → $dst"
    return 0
  fi

  if [[ ! -d "$dst_dir" ]]; then
    if [[ "$ASSUME_YES" == true || "$FORCE" == true ]]; then
      mkdir -p "$dst_dir"
    else
      read -r -p "Criar diretório '$dst_dir'? [y/N] " ans
      [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { log_warn "Pasta ignorada: $dst_dir"; return 0; }
      mkdir -p "$dst_dir"
    fi
  fi

  if [[ -f "$dst" && "$FORCE" != true ]]; then
    log_warn "Arquivo existe e --force não foi usado. Pulando: $dst"
    return 0
  fi

  # cp -p preserva timestamps e modo; em NTFS montado no Linux manterá mtime.
  cp -p -- "$src" "$dst"
}

# ---------- Aplicar restauração ----------
apply_restore() {
  local manifest="$RESTORE_ROOT/manifest.json"
  local files_root="$RESTORE_ROOT/files"
  local filter='.[]'
  [[ -n "$ONLY_USER" ]] && filter="$filter | select(.user==\"$ONLY_USER\")"
  [[ -n "$ONLY_FOLDER" ]] && filter="$filter | select(.known_folder==\"$ONLY_FOLDER\")"
  [[ -f "$manifest" && -d "$files_root" ]] || { log_error "manifest.json ou files/ ausente(s) em $RESTORE_ROOT"; exit 2; }

  # Itera manifest e restaura cada arquivo
  # Campos: token_path, user
  local total=0 ok=0 skip=0
  jq -r "$filter | [.token_path, .user] | @tsv" -- "$manifest" | \
  while IFS=$'\t' read -r token_path old_user; do
    ((total++)) || true
    local src dst
    src="$files_root/$token_path"
    dst="$(resolve_target_abs "$token_path" "$old_user")"

    if [[ ! -f "$src" ]]; then
      log_warn "Fonte ausente no pacote: $src (pulando)"
      ((skip++)) || true
      continue
    fi
    _copy_file_preserve "$src" "$dst" && ((ok++)) || true
  done

  log_info "Restauração concluída. Total: $total | Copiados: $ok | Pulados: $skip"
}

# ---------- Fluxo principal ----------
main() {
  parse_args "$@"
  [[ -n "$LOG_DEST" ]] && log_init "$LOG_DEST"
  load_env_and_mount
  extract_if_needed
  validate_before_copy

  check_space_restore

  if [[ "$VERIFY_ONLY" == true ]]; then
    log_info "--verify-only: finalizando após validação."
    cleanup_extract_tmp
    exit 0
  fi

  apply_restore
  cleanup_extract_tmp

  log_info "Destino do Windows: $WIN_MOUNT"
  log_info "Restauração finalizada."
}

main "$@"
