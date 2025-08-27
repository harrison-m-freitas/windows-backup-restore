#!/usr/bin/env bash
# =======================================================
# src/Lib/Hashing.sh — Funções de hashing e verificação
# =======================================================
# Propósito:
#   Calcular SHA-256 de arquivos (individual e em lote), emitir
#   metadados (tamanho e mtime) e verificar integridade.
#
# Funções públicas:
#   - detect_sha256_bin                     # ecoa 'sha256sum' ou 'openssl'
#   - sha256_of <arquivo>                   # ecoa apenas o hash
#   - sha256_record_tsv <arquivo>           # path<TAB>sha256<TAB>size<TAB>mtime_iso
#   - sha256_batch_to_tsv <out.tsv> [arquivos ...] | (stdin)  # gera TSV em lote
#   - sha256_verify_tsv <tsv>               # verifica hashes do TSV (retorna !=0 se falhar)
#
# Notas:
#   - Paralelismo controlado por env HASH_JOBS (padrão: nproc ou 4).
#   - Depende de coreutils (stat, date) e, preferencialmente, sha256sum.
#   - Fallback: openssl dgst -sha256.
#   - Requer Logging.sh para logs (opcional; falha silenciosa se ausente).
# =======================================================

set -euo pipefail

# ---------- bootstrap de logger (opcional) ----------
# shellcheck disable=SC1091
if ! command -v log_info >/dev/null 2>&1; then
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$THIS_DIR/Logging.sh" ]] && source "$THIS_DIR/Logging.sh" || true
fi
log_info()  { command -v log_info  >/dev/null 2>&1 && command log_info  "$@" || printf '[INFO] %s\n'  "$*"; }
log_warn()  { command -v log_warn  >/dev/null 2>&1 && command log_warn  "$@" || printf '[WARN] %s\n'  "$*"; }
log_error() { command -v log_error >/dev/null 2>&1 && command log_error "$@" || printf '[ERROR] %s\n' "$*" >&2; }

# ---------- utilidades internas ----------
_nproc() {
  if command -v nproc >/dev/null 2>&1; then nproc; else echo 4; fi
}
_jobs() {
  local j="${HASH_JOBS:-$(_nproc)}"
  [[ "$j" =~ ^[0-9]+$ ]] || j=4
  echo "$j"
}

detect_sha256_bin() {
  if command -v sha256sum >/dev/null 2>&1; then echo "sha256sum"; return 0; fi
  if command -v openssl    >/dev/null 2>&1; then echo "openssl";    return 0; fi
  return 1
}

# Retorna o SHA-256 puro (64 hex) do arquivo
sha256_of() {
  local f="$1"
  [[ -f "$f" ]] || { log_error "Arquivo não existe: $f"; return 2; }
  local bin; bin="$(detect_sha256_bin)" || { log_error "Nenhum SHA-256 disponível (instale coreutils/openssl)."; return 3; }
  case "$bin" in
    sha256sum) sha256sum -b -- "$f" | awk '{print $1}' ;;
    openssl)   openssl dgst -sha256 -- "$f" | awk '{print $NF}' ;;
  esac
}

# Emite: path<TAB>sha256<TAB>size<TAB>mtime_iso8601
sha256_record_tsv() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local h s m
  h="$(sha256_of "$f")" || return $?
  # GNU stat (Linux)
  s="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
  # mtime em ISO8601 (UTC)
  local epoch
  epoch="$(stat -c '%Y' -- "$f" 2>/dev/null || date +%s)"
  m="$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf "%s\t%s\t%s\t%s\n" "$f" "$h" "$s" "$m"
}

# Lê lista de arquivos do stdin (um por linha) ou dos argumentos, calcula hashes em paralelo e grava TSV
sha256_batch_to_tsv() {
  local out_tsv="$1"; shift || true
  mkdir -p "$(dirname "$out_tsv")"

  local jobs; jobs="$(_jobs)"
  log_info "Hashing em lote → $out_tsv (jobs: $jobs)"

  # Alimentação: argumentos ou stdin
  local tmpin; tmpin="$(mktemp -t hash_in.XXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpin'" EXIT

  if [[ $# -gt 0 ]]; then
    printf "%s\n" "$@" > "$tmpin"
  else
    cat > "$tmpin"
  fi

  # Filtra apenas arquivos regulares existentes e únicos
  awk 'NF>0' "$tmpin" | sort -u | while IFS= read -r p; do
    [[ -f "$p" ]] && printf "%s\0" "$p"
  done | xargs -0 -n1 -P "$jobs" bash -c '
      for f in "$@"; do
        '"$(typeset -f sha256_of)"'
        '"$(typeset -f sha256_record_tsv)"'
        sha256_record_tsv "$f"
      done
    ' _ > "$out_tsv"

  log_info "TSV gerado: $out_tsv"
}

# Verifica um TSV (path<TAB>sha256<TAB>size<TAB>mtime) recomputando hash
# Saída:
#   - Lista falhas no stderr
#   - Retorno 0 se tudo ok; 1 se houve falhas
sha256_verify_tsv() {
  local tsv="$1"
  [[ -f "$tsv" ]] || { log_error "TSV não encontrado: $tsv"; return 2; }

  local bin; bin="$(detect_sha256_bin)" || { log_error "Sem binário SHA-256 p/ verificação."; return 3; }

  local failures=0
  # Verifica em paralelo
  local jobs; jobs="$(_jobs)"

  awk -F'\t' 'NF>=2{print $1 "\t" $2}' "$tsv" | \
  sort -u | \
  while IFS=$'\t' read -r path expect; do
    [[ -f "$path" ]] || { printf "[MISSING] %s\n" "$path" >&2; failures=1; continue; }
    # hash atual
    case "$bin" in
      sha256sum) cur="$(sha256sum -b -- "$path" | awk "{print \$1}")" ;;
      openssl)   cur="$(openssl dgst -sha256 -- "$path" | awk "{print \$NF}")" ;;
    esac
    if [[ "$cur" != "$expect" ]]; then
      printf "[MISMATCH] %s\n  esperado: %s\n  obtido:   %s\n" "$path" "$expect" "$cur" >&2
      failures=1
    fi
  done

  if [[ $failures -ne 0 ]]; then
    log_error "Verificação de integridade falhou."
    return 1
  fi
  log_info "Integridade verificada com sucesso."
  return 0
}

# ---------- execução direta (teste) ----------
# Exemplos:
#   ./Hashing.sh hash file1
#   ./Hashing.sh batch out.tsv file1 file2 ...
#   printf "/caminho/a\n/caminho/b\n" | ./Hashing.sh batch out.tsv
#   ./Hashing.sh verify out.tsv
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sub="${1:-}"
  case "$sub" in
    hash)
      f="${2:?arquivo}"; sha256_of "$f" ;;
    batch)
      out="${2:?out.tsv}"; shift 2; sha256_batch_to_tsv "$out" "$@" ;;
    verify)
      tsv="${2:?tsv}"; sha256_verify_tsv "$tsv" ;;
    *)
      echo "Uso:"
      echo "  $0 hash <arquivo>"
      echo "  $0 batch <out.tsv> [arquivos ...]    # ou via stdin (um path por linha)"
      echo "  $0 verify <tsv>"
      exit 0
      ;;
  esac
fi
