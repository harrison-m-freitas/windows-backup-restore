#!/usr/bin/env bash
# =======================================================
# src/Lib/Logging.sh — Logger simples com níveis e arquivo
# =======================================================
# Recursos:
#   - Níveis: DEBUG < INFO < WARN < ERROR
#   - Formatação: timestamp ISO-8601, nível, mensagem
#   - Cores automáticas (desativa se não TTY ou NO_COLOR=1)
#   - Saída em arquivo opcional (LOG_FILE); cria diretório se preciso
#   - Controle de nível por env LOG_LEVEL (default: INFO)
#   - Modo silencioso parcial por QUIET=1 (suprime INFO/DEBUG no console)
#   - Prefixo automático para DRY-RUN (se DRY_RUN=true)
#   - Rotação simples por tamanho (LOG_MAX_BYTES; default: 2MB)
#
# Uso:
#   source "./Lib/Logging.sh"
#   log_init "/caminho/opcional/do.log"
#   log_info  "Mensagem informativa"
#   log_warn  "Aviso"
#   log_error "Falha"
#   LOG_LEVEL=DEBUG log_debug "Detalhe"
# =======================================================

set -euo pipefail

# ---------- Configurações padrão ----------
: "${LOG_LEVEL:=INFO}"             # DEBUG|INFO|WARN|ERROR
: "${LOG_FILE:=}"                  # vazio = sem arquivo
: "${LOG_MAX_BYTES:=2097152}"      # 2 MiB
: "${QUIET:=0}"                    # 1 = suprimir INFO/DEBUG no console
: "${NO_COLOR:=0}"                 # 1 = desativar cor
: "${TZ:=UTC}"                     # timestamps em UTC por padrão

# ---------- Mapa de níveis ----------
__log_level_to_num() {
  case "${1^^}" in
    DEBUG) echo 10 ;;
    INFO)  echo 20 ;;
    WARN)  echo 30 ;;
    ERROR) echo 40 ;;
    *)     echo 20 ;; # default INFO
  esac
}
__LOG_THRESHOLD="$(__log_level_to_num "$LOG_LEVEL")"

# ---------- Cores ----------
__log_has_color() {
  [[ "$NO_COLOR" != "1" ]] && [[ -t 2 ]]
}
if __log_has_color; then
  __CLR_DEBUG="\033[2m"      # dim
  __CLR_INFO="\033[36m"      # cyan
  __CLR_WARN="\033[33m"      # yellow
  __CLR_ERROR="\033[31m"     # red
  __CLR_RESET="\033[0m"
else
  __CLR_DEBUG=""; __CLR_INFO=""; __CLR_WARN=""; __CLR_ERROR=""; __CLR_RESET=""
fi

# ---------- Auxiliares ----------
log_set_level() {
  LOG_LEVEL="${1^^}"
  __LOG_THRESHOLD="$(__log_level_to_num "$LOG_LEVEL")"
}

log_init() {
  # $1: caminho opcional de arquivo de log (sobrepõe LOG_FILE)
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    LOG_FILE="$1"
  fi
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    # cria arquivo se não existir
    : > "$LOG_FILE" || {
      echo "[ERROR] Não foi possível criar arquivo de log: $LOG_FILE" >&2
      LOG_FILE=""
    }
  fi
}

__log_ts() {
  # ISO-8601 com timezone
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

__log_rotate_if_needed() {
  # Rotação simples: se LOG_FILE excede LOG_MAX_BYTES → renomeia para .1 e recria
  [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] || return 0
  local sz; sz=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$sz" -ge "$LOG_MAX_BYTES" ]]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
  fi
}

__log_emit() {
  # $1: LEVEL   $2: COLOR   $3..: mensagem
  local lvl="$1"; shift
  local color="$1"; shift
  local ts msg prefix
  ts="$(__log_ts)"
  prefix="[$ts] [$lvl]"

  # DRY-RUN prefix
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    prefix="$prefix [DRY-RUN]"
  fi

  msg="$*"

  # Console
  local lvl_num out_line
  lvl_num="$(__log_level_to_num "$lvl")"
  out_line="$prefix $msg"
  if [[ "$lvl_num" -ge "$__LOG_THRESHOLD" ]]; then
    # QUIET suprime INFO/DEBUG no console (mas não no arquivo)
    if [[ "$QUIET" != "1" || "$lvl_num" -ge "$(__log_level_to_num WARN)" ]]; then
      if [[ "$lvl" == "ERROR" ]]; then
        printf "%b%s%b\n" "$color" "$out_line" "$__CLR_RESET" >&2
      else
        printf "%b%s%b\n" "$color" "$out_line" "$__CLR_RESET" >&2
      fi
    fi
  fi

  # Arquivo
  if [[ -n "$LOG_FILE" ]]; then
    __log_rotate_if_needed
    printf "%s\n" "$out_line" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

# ---------- API pública ----------
log_debug() { __log_emit "DEBUG" "$__CLR_DEBUG" "$*"; }
log_info()  { __log_emit "INFO"  "$__CLR_INFO"  "$*"; }
log_warn()  { __log_emit "WARN"  "$__CLR_WARN"  "$*"; }
log_error() { __log_emit "ERROR" "$__CLR_ERROR" "$*"; }

# ---------- Execução direta (teste rápido) ----------
# Exemplo:
#   LOG_LEVEL=DEBUG QUIET=0 NO_COLOR=0 ./Logging.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  log_init "/tmp/example-backup.log"
  log_debug "Debug de inicialização"
  log_info  "Logger operacional (arquivo: $LOG_FILE)"
  log_warn  "Aviso demonstrativo"
  log_error "Erro demonstrativo"
fi
