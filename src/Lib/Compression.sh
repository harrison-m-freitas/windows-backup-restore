#!/usr/bin/env bash
# =======================================================
# src/Lib/Compression.sh — Compressão/Extração (Linux)
# =======================================================
# Propósito:
#   Fornecer compressão preferencial 7-Zip (LZMA2, -mx=9, -mmt, sólido)
#   com fallback ZIP. Extração compatível (.7z/.zip). Suporte opcional
#   a criptografia via env: BACKUP_ENCRYPTION=1 + BACKUP_PASSWORD.
#
# Funções públicas:
#   - detect_7z                               # ecoa '7z' ou '7zz' se existir
#   - compress_with_7z <src_dir> <dest.7z>   # compacta diretório
#   - compress_with_zip <src_dir> <dest.zip> # fallback zip -9
#   - extract_with_7z <arquivo.7z> <dest>    # extrai 7z
#   - extract_with_zip <arquivo.zip> <dest>  # extrai zip
#   - test_archive <arquivo>                 # verifica integridade do arquivo
#   - list_archive <arquivo>                 # lista conteúdo
#
# Notas:
#   * Nunca imprime a senha em claro. Usa máscara "****" nos logs.
#   * Não cria diretório pai do destino? Cria automaticamente.
#   * Aceita tanto '7z' quanto '7zz' (p7zip vs 7zip-j).
#   * Requer Logging.sh (log_info/log_warn/log_error).
# =======================================================

set -euo pipefail

# shellcheck disable=SC1091
if ! command -v log_info >/dev/null 2>&1; then
  # Carrega o logger se este módulo for usado isoladamente
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$THIS_DIR/Logging.sh" ]] && source "$THIS_DIR/Logging.sh"
fi

# -------------------- Utilidades internas --------------------

detect_7z() {
  if command -v 7z >/dev/null 2>&1; then echo "7z"; return 0; fi
  if command -v 7zz >/dev/null 2>&1; then echo "7zz"; return 0; fi
  return 1
}

_mask_pwd() {
  [[ -n "${BACKUP_PASSWORD:-}" ]] && echo "****" || echo ""
}

_build_7z_pwd_args() {
  # Só aplica se BACKUP_ENCRYPTION=1; valida senha.
  if [[ "${BACKUP_ENCRYPTION:-0}" == "1" ]]; then
    if [[ -z "${BACKUP_PASSWORD:-}" ]]; then
      log_error "BACKUP_ENCRYPTION=1 informado, mas BACKUP_PASSWORD está vazio."
      exit 2
    fi
    # Importante: em 7z, -p<SENHA> (sem espaço); -mhe=on cifra nomes.
    echo "-p${BACKUP_PASSWORD} -mhe=on"
  else
    echo ""
  fi
}

_cpu_threads() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    echo 0  # 0 = auto p/ 7z -mmt
  fi
}

# -------------------- Compressão --------------------

compress_with_7z() {
  local src_dir="$1"
  local dest_archive="$2"
  local sevenz
  sevenz="$(detect_7z)" || { log_error "7-Zip não encontrado (instale p7zip-full)."; return 3; }

  [[ -d "$src_dir" ]] || { log_error "Diretório fonte inexistente: $src_dir"; return 1; }
  mkdir -p "$(dirname "$dest_archive")"

  local pwd_args threads
  pwd_args="$(_build_7z_pwd_args)"
  threads="$(_cpu_threads)"

  log_info "Compactando (7z) '$src_dir' → '$dest_archive' (senha: $(_mask_pwd))"
  (
    cd "$src_dir"
    # -t7z  : formato 7z
    # -mx=9 : máxima compressão
    # -mmt=N: threads (0=auto)
    # -ms=on: sólido
    # -slp  : segue symlinks como links
    # -bb0  : menos verboso
    # shellcheck disable=SC2086
    "$sevenz" a -t7z -mx=9 -mmt="$threads" -ms=on -slp -bb0 $pwd_args -- "$dest_archive" ./ > /dev/null
  )
  log_info "Gerado: $dest_archive"
}

compress_with_7z_list() {
  local list_file="$1"
  local dest="$2"
  log_info "Compactando com 7z (lista: $list_file → $dest)"
  if [[ -n "${BACKUP_ENCRYPTION:-}" && "$BACKUP_ENCRYPTION" -eq 1 && -n "${BACKUP_PASSWORD:-}" ]]; then
    7z a -t7z -mx=9 -mmt=on -ms=on -mhe=on -p"$BACKUP_PASSWORD" -- "$dest" @"$list_file"
  else
    7z a -t7z -mx=9 -mmt=on -ms=on -- "$dest" @"$list_file"
  fi
}

compress_with_zip() {
  local src_dir="$1"
  local dest_archive="$2"

  command -v zip >/dev/null 2>&1 || { log_error "'zip' não encontrado (instale 'zip')."; return 3; }
  [[ -d "$src_dir" ]] || { log_error "Diretório fonte inexistente: $src_dir"; return 1; }
  mkdir -p "$(dirname "$dest_archive")"

  if [[ "${BACKUP_ENCRYPTION:-0}" == "1" ]]; then
    log_warn "Criptografia ZIP é fraca. Recomenda-se 7z. Prosseguindo SEM criptografia no zip."
  fi

  log_info "Compactando (zip) '$src_dir' → '$dest_archive'"
  (
    cd "$src_dir"
    zip -r -9 -q -- "$dest_archive" ./   # -9 máx. compressão
  )
  log_info "Gerado: $dest_archive"
}

compress_with_zip_list() {
  local list_file="$1"
  local dest="$2"
  log_info "Compactando com zip (lista: $list_file → $dest)"
  # zip não aceita @listfile direto, então usamos xargs
  xargs -a "$list_file" zip -r -9 "$dest"
}

# -------------------- Extração --------------------

extract_with_7z() {
  local archive="$1"
  local dest_dir="$2"
  local sevenz
  sevenz="$(detect_7z)" || { log_error "7-Zip não encontrado para extração."; return 3; }

  [[ -f "$archive" ]] || { log_error "Arquivo não encontrado: $archive"; return 1; }
  mkdir -p "$dest_dir"

  local pwd_args
  pwd_args="$(_build_7z_pwd_args)"

  log_info "Extraindo (7z) '$archive' → '$dest_dir' (senha: $(_mask_pwd))"
  # -y: assume yes; -aos: não sobrescrever existentes; -bb0: silencioso
  # shellcheck disable=SC2086
  "$sevenz" x -y -aos -o"$dest_dir" -bb0 $pwd_args -- "$archive" > /dev/null
  log_info "Extração concluída."
}

extract_with_zip() {
  local archive="$1"
  local dest_dir="$2"

  command -v unzip >/dev/null 2>&1 || { log_error "'unzip' não encontrado (instale 'unzip')."; return 3; }
  [[ -f "$archive" ]] || { log_error "Arquivo não encontrado: $archive"; return 1; }
  mkdir -p "$dest_dir"

  if [[ "${BACKUP_ENCRYPTION:-0}" == "1" && -n "${BACKUP_PASSWORD:-}" ]]; then
    log_info "Extraindo (zip) '$archive' → '$dest_dir' (senha: $(_mask_pwd))"
    unzip -q -o -P "$BACKUP_PASSWORD" "$archive" -d "$dest_dir"
  else
    log_info "Extraindo (zip) '$archive' → '$dest_dir'"
    unzip -q -o "$archive" -d "$dest_dir"
  fi

  log_info "Extração concluída."
}

# -------------------- Verificação/Inspeção --------------------

test_archive() {
  # Verifica integridade do arquivo (.7z usa 't'; .zip usa 'unzip -tqq')
  local archive="$1"
  [[ -f "$archive" ]] || { log_error "Arquivo não encontrado: $archive"; return 1; }

  case "$archive" in
    *.7z)
      local sevenz pwd_args
      sevenz="$(detect_7z)" || { log_error "7-Zip não encontrado para teste."; return 3; }
      pwd_args="$(_build_7z_pwd_args)"
      log_info "Testando integridade (7z) '$archive' (senha: $(_mask_pwd))"
      # shellcheck disable=SC2086
      "$sevenz" t -bb0 $pwd_args -- "$archive" > /dev/null
      ;;
    *.zip)
      command -v unzip >/dev/null 2>&1 || { log_error "'unzip' não encontrado para teste."; return 3; }
      log_info "Testando integridade (zip) '$archive'"
      if [[ "${BACKUP_ENCRYPTION:-0}" == "1" && -n "${BACKUP_PASSWORD:-}" ]]; then
        unzip -tqq -P "$BACKUP_PASSWORD" "$archive" >/dev/null
      else
        unzip -tqq "$archive" >/dev/null
      fi
      ;;
    *)
      log_error "Formato não suportado para teste: $archive"
      return 2
      ;;
  esac
  log_info "Arquivo OK: $archive"
}

list_archive() {
  local archive="$1"
  [[ -f "$archive" ]] || { log_error "Arquivo não encontrado: $archive"; return 1; }

  case "$archive" in
    *.7z)
      local sevenz pwd_args
      sevenz="$(detect_7z)" || { log_error "7-Zip não encontrado para listar."; return 3; }
      pwd_args="$(_build_7z_pwd_args)"
      log_info "Listando conteúdo (7z): $archive"
      # shellcheck disable=SC2086
      "$sevenz" l -bb0 $pwd_args -- "$archive"
      ;;
    *.zip)
      command -v unzip >/dev/null 2>&1 || { log_error "'unzip' não encontrado para listar."; return 3; }
      log_info "Listando conteúdo (zip): $archive"
      unzip -l "$archive"
      ;;
    *)
      log_error "Formato não suportado para listagem: $archive"
      return 2
      ;;
  esac
}

# -------------------- Execução direta (teste rápido) --------------------
# Exemplos:
#   BACKUP_ENCRYPTION=1 BACKUP_PASSWORD='minha_senha' ./Compression.sh test.7z /tmp/dir
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sub="${1:-}"
  case "$sub" in
    c7z)  # compress 7z
      src="${2:?src_dir}"; out="${3:?dest.7z}"; compress_with_7z "$src" "$out" ;;
    czp)  # compress zip
      src="${2:?src_dir}"; out="${3:?dest.zip}"; compress_with_zip "$src" "$out" ;;
    e7z)  # extract 7z
      arc="${2:?arquivo.7z}"; dst="${3:?dest_dir}"; extract_with_7z "$arc" "$dst" ;;
    ezp)  # extract zip
      arc="${2:?arquivo.zip}"; dst="${3:?dest_dir}"; extract_with_zip "$arc" "$dst" ;;
    t)    # test archive
      arc="${2:?arquivo}"; test_archive "$arc" ;;
    l)    # list archive
      arc="${2:?arquivo}"; list_archive "$arc" ;;
    *)
      echo "Uso:"
      echo "  $0 c7z <src_dir> <dest.7z>"
      echo "  $0 czp <src_dir> <dest.zip>"
      echo "  $0 e7z <arquivo.7z> <dest_dir>"
      echo "  $0 ezp <arquivo.zip> <dest_dir>"
      echo "  $0 t   <arquivo>"
      echo "  $0 l   <arquivo>"
      exit 0
      ;;
  esac
fi
