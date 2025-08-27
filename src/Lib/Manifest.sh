#!/usr/bin/env bash
# =======================================================
# src/Lib/Manifest.sh — Geração e verificação de manifest
# =======================================================
# Propósito:
#   - Gerar MANIFEST (JSON) para arquivos extraídos de um
#     Windows montado (WIN_MOUNT), tokenizando paths.
#   - Verificar integridade de um conjunto restaurado/stage
#     comparando SHA-256 e tamanhos contra o manifest.
#
# Formato do MANIFEST (top-level = array):
# [
#   {
#     "token_path": "{{Documents}}/projeto/relatorio.pdf",
#     "user": "Harrison",
#     "size": 12345,
#     "mtime": "2025-08-27T12:34:56Z",
#     "sha256": "ab...ff",
#     "origin": "Users/Harrison/Documents",   # relativo ao WIN_MOUNT (informativo)
#     "flags": []
#   },
#   ...
# ]
#
# Convenções:
#   - O diretório de staging/arq. compactado deve conter os
#     arquivos sob:  files/<token_path>
#   - A validação usa esse layout: <root_dir>/files/<token_path>
#
# Dependências:
#   - Logging.sh  (log_info/log_warn/log_error)
#   - Paths.sh    (init_win_mount, tokenize_abs_path)
#   - Hashing.sh  (sha256_of)
#   - jq (apenas no validate_manifest_hashes)
# =======================================================

set -euo pipefail

# ---------- bootstrap de libs ----------
# shellcheck disable=SC1091
if ! command -v log_info >/dev/null 2>&1; then
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$THIS_DIR/Logging.sh" ]] && source "$THIS_DIR/Logging.sh"
fi
if ! command -v tokenize_abs_path >/dev/null 2>&1; then
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$THIS_DIR/Paths.sh" ]] && source "$THIS_DIR/Paths.sh"
fi
if ! command -v sha256_of >/dev/null 2>&1; then
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$THIS_DIR/Hashing.sh" ]] && source "$THIS_DIR/Hashing.sh"
fi

# =======================================================
# Helpers
# =======================================================

# Detecta usuário a partir de um caminho absoluto sob WIN_MOUNT/Users/<user>/...
_detect_user_from_abs() {
  # $1: abs_path
  local p="$1" re
  re="^${WIN_MOUNT%/}/Users/([^/]+)/"
  if [[ "$p" =~ $re ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo ""   # desconhecido
}

# Retorna caminho relativo ao WIN_MOUNT (informativo)
_rel_from_win_mount() {
  local p="$1"
  local base="${WIN_MOUNT%/}/"
  if [[ "$p" == "$base"* ]]; then
    echo "${p#$base}"
  else
    echo "$p"
  fi
}

# ISO8601 (UTC) a partir do mtime
_mtime_iso() {
  local f="$1" epoch
  epoch="$(stat -c '%Y' -- "$f" 2>/dev/null || date +%s)"
  date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Escapa JSON simples
_json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# =======================================================
# Construção do Manifest
# =======================================================

# Emite (stdout) o objeto JSON do item correspondente ao arquivo absoluto
_manifest_item_for_abs() {
  local abs="$1"
  [[ -f "$abs" ]] || return 0

  local user token_path size mtime sha rel
  user="$(_detect_user_from_abs "$abs")"
  token_path="$(tokenize_abs_path "$abs" "$user")"
  size="$(stat -c '%s' -- "$abs" 2>/dev/null || echo 0)"
  mtime="$(_mtime_iso "$abs")"
  sha="$(sha256_of "$abs")" || sha=""
  rel="$(_rel_from_win_mount "$abs")"

  # Monta JSON do item
  printf '{'
  printf '"token_path":"%s",'  "$(echo "$token_path" | _json_escape)"
  printf '"user":"%s",'        "$(echo "$user"       | _json_escape)"
  printf '"size":%s,'          "$size"
  printf '"mtime":"%s",'       "$mtime"
  printf '"sha256":"%s",'      "$sha"
  printf '"origin":"%s",'      "$(echo "$rel" | _json_escape)"
  printf '"flags":[]'
  printf '}'
}

# Gera manifest (array JSON) a partir de uma lista de arquivos absolutos
# Uso:
#   create_manifest <out_manifest.json> <file1> <file2> ...
#   # ou:  printf "/abs/a\n/abs/b\n" | create_manifest <out_manifest.json>
create_manifest() {
  local out="$1"; shift || true
  mkdir -p "$(dirname "$out")"

  log_info "Gerando manifest em: $out"

  local tmpin; tmpin="$(mktemp -t manifest_in.XXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpin'" EXIT

  if [[ $# -gt 0 ]]; then
    printf "%s\n" "$@" > "$tmpin"
  else
    cat > "$tmpin"
  fi

  # Filtra arquivos existentes, únicos
  mapfile -t files < <(awk 'NF>0' "$tmpin" | sort -u | while IFS= read -r p; do [[ -f "$p" ]] && echo "$p"; done)

  {
    echo "["
    local first=1
    for f in "${files[@]}"; do
      local obj
      obj="$(_manifest_item_for_abs "$f")" || obj=""
      [[ -z "$obj" ]] && continue
      if [[ $first -eq 1 ]]; then
        printf "  %s" "$obj"
        first=0
      else
        printf ",\n  %s" "$obj"
      fi
    done
    echo
    echo "]"
  } > "$out"

  log_info "Manifest criado com ${#files[@]} entradas → $out"
}

# =======================================================
# Verificação do Manifest (hash/size)
# =======================================================

# Verifica se os arquivos em <stage_root>/files/<token_path> batem com o manifest
# Requer jq para ler o JSON.
# Retornos:
#   0 → OK
#   1 → divergências encontradas
#   2 → erro (sem jq, manifest ausente, etc.)
validate_manifest_hashes() {
  local manifest="$1"
  local stage_root="$2"

  [[ -f "$manifest" ]] || { log_error "Manifest não encontrado: $manifest"; return 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq não encontrado (necessário para validar manifest)."; return 2; }

  local files_root="$stage_root/files"
  [[ -d "$files_root" ]] || { log_error "Diretório esperado não existe: $files_root"; return 2; }

  log_info "Validando manifest (hash/size) em: $files_root"

  local fail=0
  # Itera sobre cada item
  jq -r '.[] | [.token_path, (.size|tostring), .sha256] | @tsv' -- "$manifest" | \
  while IFS=$'\t' read -r token_path size_expected sha_expected; do
    local src="$files_root/$token_path"
    if [[ ! -f "$src" ]]; then
      printf "[MISSING] %s\n" "$src" >&2
      fail=1
      continue
    fi
    local size_cur sha_cur
    size_cur="$(stat -c '%s' -- "$src" 2>/dev/null || echo 0)"
    sha_cur="$(sha256_of "$src" 2>/dev/null || echo "")"

    if [[ "$size_cur" != "$size_expected" ]]; then
      printf "[SIZE-MISMATCH] %s\n  esperado: %s  atual: %s\n" "$token_path" "$size_expected" "$size_cur" >&2
      fail=1
    fi
    if [[ -n "$sha_expected" && "$sha_cur" != "$sha_expected" ]]; then
      printf "[HASH-MISMATCH] %s\n  esperado: %s\n  atual:    %s\n" "$token_path" "$sha_expected" "$sha_cur" >&2
      fail=1
    fi
  done

  if [[ "$fail" -ne 0 ]]; then
    log_error "Validação de manifest encontrou divergências."
    return 1
  fi

  log_info "Manifest validado com sucesso."
  return 0
}

# =======================================================
# Execução direta (teste manual)
# =======================================================
# Exemplos:
#   WIN_MOUNT=/media/win ./Manifest.sh create /tmp/manifest.json /media/win/Users/Me/Documents/a.txt
#   ./Manifest.sh verify /tmp/manifest.json /tmp/stage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sub="${1:-}"
  case "$sub" in
    create)
      out="${2:?out.json}"; shift 2
      create_manifest "$out" "$@"
      ;;
    verify)
      man="${2:?manifest.json}"; root="${3:?stage_root}"
      validate_manifest_hashes "$man" "$root"
      ;;
    *)
      echo "Uso:"
      echo "  $0 create <out_manifest.json> <abs_file1> [abs_file2 ...]   # ou stdin"
      echo "  $0 verify <manifest.json> <stage_root>  # espera files/<token_path>"
      exit 0
      ;;
  esac
fi
