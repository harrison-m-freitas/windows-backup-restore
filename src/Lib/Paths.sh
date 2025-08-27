#!/usr/bin/env bash
# =======================================================
# src/Lib/Paths.sh  —  Mapeamento e resolução de paths
# =======================================================
# Propósito:
#   Rodando em Linux, mapear/caminhar um disco Windows montado
#   (WIN_MOUNT) para coletar/emitir arquivos conforme include/exclude.
#
# Fornece (principais):
#   - init_win_mount <config.yaml>           # Define WIN_MOUNT (config/env)
#   - list_windows_users                     # Lista perfis válidos em C:\Users
#   - get_known_folder <token> <user>        # Resolve pasta conhecida do Windows
#   - map_token_to_abs_path <token_path> <user>   # {{Tokens}} -> caminho absoluto
#   - tokenize_abs_path <abs_path> <user>    # caminho absoluto -> {{Tokens}}
#   - resolve_file_set_from_config <config.yaml>  # Emite (stdout) paths absolutos
#
# Requisitos:
#   - Logger externo: log_info/log_warn/log_error (src/Lib/Logging.sh)
#   - Opcional: yq para parse YAML (fallback grep/sed)
#
# Notas:
#   - Os tokens a seguir são suportados (case-sensitive):
#     {{SystemDrive}}, {{Windows}}, {{ProgramFiles}}, {{ProgramFilesX86}},
#     {{ProgramData}}, {{Users}}, {{UserProfile}},
#     {{Desktop}}, {{Documents}}, {{Downloads}}, {{Pictures}}, {{Videos}},
#     {{Music}}, {{Favorites}}, {{AppDataRoaming}}, {{AppDataLocal}}
#   - Perfis ignorados por padrão: Default, Default User, All Users, Public
# =======================================================

set -euo pipefail

# ---------- Utilidades internas de YAML ----------
_yaml_get_scalar() {
  # $1: .path.no.yaml   $2: arquivo
  if command -v yq >/dev/null 2>&1; then
    yq e "$1" "$2"
  else
    # Fallback simples p/ chaves no formato 'key: value' (nível único)
    # Ex.: _yaml_get_scalar '.backup_root' file.yaml
    local key; key="${1#.}"
    awk -v k="^${key}:" '
      $0 ~ k {
        sub(/^[^:]+:[[:space:]]*/,"");
        print; exit
      }' "$2"
  fi
}

_yaml_get_list() {
  # $1: .path.list  $2: file
  if command -v yq >/dev/null 2>&1; then
    yq e "$1[]" "$2" 2>/dev/null | sed '/^null$/d' || true
  else
    # Fallback: assume lista YAML com "- item"
    # Busca da linha da chave até próximo bloco não indentado
    local key; key="${1#.}"
    awk -v k="^${key}:" '
      f==0 && $0 ~ k { f=1; next }
      f==1 {
        if ($0 ~ /^[^[:space:]-]/) exit
        if ($0 ~ /^[[:space:]]*-[[:space:]]+/) {
          sub(/^[[:space:]]*-[[:space:]]+/,"")
          print
        }
      }' "$2"
  fi
}

# ---------- Inicialização de WIN_MOUNT ----------
init_win_mount() {
  # Define WIN_MOUNT (ordem de prioridade):
  # 1) variável de ambiente WIN_MOUNT
  # 2) config: .windows.mount (ex.: /media/<uuid>)
  # 3) erro se não encontrado
  local cfg="${1:-}"
  if [[ -n "${WIN_MOUNT:-}" ]]; then
    :
  elif [[ -n "$cfg" && -f "$cfg" ]]; then
    WIN_MOUNT="$(_yaml_get_scalar '.windows.mount' "$cfg" | sed 's/"//g')"
  fi

  if [[ -z "${WIN_MOUNT:-}" ]]; then
    log_error "WIN_MOUNT não definido. Ex.: export WIN_MOUNT=/media/SEU_DISCO_WINDOWS"
    exit 2
  fi
  if [[ ! -d "$WIN_MOUNT" ]]; then
    log_error "WIN_MOUNT não é diretório válido: $WIN_MOUNT"
    exit 2
  fi
  # Heurística mínima: deve conter diretórios típicos
  if [[ ! -d "$WIN_MOUNT/Windows" ]] && [[ ! -d "$WIN_MOUNT/Users" ]]; then
    log_warn "Montagem não parece um Windows. Continuando mesmo assim: $WIN_MOUNT"
  fi
  log_info "Disco Windows montado detectado: $WIN_MOUNT"
}

# ---------- Perfis de usuário ----------
list_windows_users() {
  # Emite nomes de pastas em C:\Users, filtrando perfis de sistema
  local users_root="$WIN_MOUNT/Users"
  [[ -d "$users_root" ]] || { log_warn "Diretório ausente: $users_root"; return 0; }

  find "$users_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | \
    grep -Ev '^(Default|Default User|All Users|Public)$' || true
}

# ---------- Mapa de pastas conhecidas ----------
get_known_folder() {
  # $1: token (ex.: Documents)  $2: user (opcional)
  local token="$1"
  local user="${2:-}"

  case "$token" in
    SystemDrive)         echo "$WIN_MOUNT" ;;
    Windows)             echo "$WIN_MOUNT/Windows" ;;
    ProgramFiles)        echo "$WIN_MOUNT/Program Files" ;;
    ProgramFilesX86)     echo "$WIN_MOUNT/Program Files (x86)" ;;
    ProgramData)         echo "$WIN_MOUNT/ProgramData" ;;
    Users)               echo "$WIN_MOUNT/Users" ;;
    UserProfile)
      [[ -z "$user" ]] && { log_error "User requerido para {{UserProfile}}"; return 1; }
      echo "$WIN_MOUNT/Users/$user"
      ;;
    Desktop)             echo "$WIN_MOUNT/Users/$user/Desktop" ;;
    Documents)           echo "$WIN_MOUNT/Users/$user/Documents" ;;
    Downloads)           echo "$WIN_MOUNT/Users/$user/Downloads" ;;
    Pictures)            echo "$WIN_MOUNT/Users/$user/Pictures" ;;
    Videos)              echo "$WIN_MOUNT/Users/$user/Videos" ;;
    Music)               echo "$WIN_MOUNT/Users/$user/Music" ;;
    Favorites)           echo "$WIN_MOUNT/Users/$user/Favorites" ;;
    AppDataRoaming)      echo "$WIN_MOUNT/Users/$user/AppData/Roaming" ;;
    AppDataLocal)        echo "$WIN_MOUNT/Users/$user/AppData/Local" ;;
    *)                   echo "$WIN_MOUNT/$token" ;;
  esac
}

# ---------- Token -> Caminho absoluto ----------
map_token_to_abs_path() {
  # $1: token_path (ex.: {{Documents}}/foo.txt)  $2: user
  local token_path="$1"
  local user="${2:-}"
  local out="$token_path"

  # Ordem: do mais específico p/ genérico evita colidir prefixos
  out="${out//\{\{UserProfile\}\}/$(get_known_folder UserProfile "$user")}"
  out="${out//\{\{Desktop\}\}/$(get_known_folder Desktop "$user")}"
  out="${out//\{\{Documents\}\}/$(get_known_folder Documents "$user")}"
  out="${out//\{\{Downloads\}\}/$(get_known_folder Downloads "$user")}"
  out="${out//\{\{Pictures\}\}/$(get_known_folder Pictures "$user")}"
  out="${out//\{\{Videos\}\}/$(get_known_folder Videos "$user")}"
  out="${out//\{\{Music\}\}/$(get_known_folder Music "$user")}"
  out="${out//\{\{Favorites\}\}/$(get_known_folder Favorites "$user")}"
  out="${out//\{\{AppDataRoaming\}\}/$(get_known_folder AppDataRoaming "$user")}"
  out="${out//\{\{AppDataLocal\}\}/$(get_known_folder AppDataLocal "$user")}"

  out="${out//\{\{ProgramFilesX86\}\}/$(get_known_folder ProgramFilesX86)}"
  out="${out//\{\{ProgramFiles\}\}/$(get_known_folder ProgramFiles)}"
  out="${out//\{\{ProgramData\}\}/$(get_known_folder ProgramData)}"
  out="${out//\{\{Windows\}\}/$(get_known_folder Windows)}"
  out="${out//\{\{Users\}\}/$(get_known_folder Users)}"
  out="${out//\{\{SystemDrive\}\}/$(get_known_folder SystemDrive)}"

  # Normalização simples de // -> /
  echo "$out" | sed 's://*:/:g'
}

# ---------- Caminho absoluto -> Token ----------
tokenize_abs_path() {
  # $1: abs_path   $2: user
  local p="$1"
  local user="${2:-}"

  # Priorizar substituições mais específicas
  local s

  s="$(get_known_folder AppDataRoaming "$user")";   p="${p/$s/\{\{AppDataRoaming\}\}}"
  s="$(get_known_folder AppDataLocal "$user")";      p="${p/$s/\{\{AppDataLocal\}\}}"
  s="$(get_known_folder Desktop "$user")";           p="${p/$s/\{\{Desktop\}\}}"
  s="$(get_known_folder Documents "$user")";         p="${p/$s/\{\{Documents\}\}}"
  s="$(get_known_folder Downloads "$user")";         p="${p/$s/\{\{Downloads\}\}}"
  s="$(get_known_folder Pictures "$user")";          p="${p/$s/\{\{Pictures\}\}}"
  s="$(get_known_folder Videos "$user")";            p="${p/$s/\{\{Videos\}\}}"
  s="$(get_known_folder Music "$user")";             p="${p/$s/\{\{Music\}\}}"
  s="$(get_known_folder Favorites "$user")";         p="${p/$s/\{\{Favorites\}\}}"
  s="$(get_known_folder UserProfile "$user")";       p="${p/$s/\{\{UserProfile\}\}}"

  s="$(get_known_folder ProgramFilesX86)";           p="${p/$s/\{\{ProgramFilesX86\}\}}"
  s="$(get_known_folder ProgramFiles)";              p="${p/$s/\{\{ProgramFiles\}\}}"
  s="$(get_known_folder ProgramData)";               p="${p/$s/\{\{ProgramData\}\}}"
  s="$(get_known_folder Windows)";                   p="${p/$s/\{\{Windows\}\}}"
  s="$(get_known_folder Users)";                     p="${p/$s/\{\{Users\}\}}"
  s="$(get_known_folder SystemDrive)";               p="${p/$s/\{\{SystemDrive\}\}}"

  echo "$p"
}

# ---------- Seleção de usuários a partir do YAML ----------
_select_users_from_config() {
  # $1: config.yaml
  local cfg="$1"
  local raw_users
  mapfile -t raw_users < <(_yaml_get_list '.users' "$cfg")
  if [[ ${#raw_users[@]} -eq 0 ]]; then
    # Padrão: todos os usuários válidos
    list_windows_users
    return
  fi
  # Se contiver "all" → todos
  if printf '%s\n' "${raw_users[@]}" | grep -qx "all"; then
    list_windows_users
    return
  fi
  # senão, retornar os especificados que existem
  for u in "${raw_users[@]}"; do
    [[ -d "$WIN_MOUNT/Users/$u" ]] && echo "$u" || log_warn "Usuário não encontrado: $u"
  done
}

# ---------- Filtros de include/exclude ----------
_read_known_folders() {
  # $1: config.yaml → lista de tokens de pastas de usuário
  _yaml_get_list '.includes.known_folders' "$1"
}

_read_patterns_file() {
  # $1: config.yaml → caminho do arquivo de padrões
  _yaml_get_scalar '.includes.patterns_file' "$1" | sed 's/"//g'
}

_read_excludes() {
  # $1: config.yaml → array de padrões a excluir (globs relativos)
  _yaml_get_list '.excludes' "$1"
}

# ---------- Construção do conjunto de arquivos ----------
_emit_files_for_user_and_folder() {
  # $1: user  $2: folder_token  $3: patterns_file (pode ser vazio)
  local user="$1" token="$2" patterns_file="${3:-}"
  local base; base="$(get_known_folder "$token" "$user")"
  [[ -d "$base" ]] || return 0

  if [[ -n "$patterns_file" && -f "$patterns_file" ]]; then
    # Cada linha do patterns_file pode ser: *.ext  ou  **/*.ext
    while IFS= read -r pat; do
      [[ -z "$pat" || "$pat" =~ ^# ]] && continue
      # Converter ** para * em find -path (aproximação conservadora)
      local fpat="${pat//**/*}"
      # Buscar a partir da base; -type f ; -path "*fpat*"
      find "$base" -type f -path "*/${fpat#\*/}" 2>/dev/null || true
    done < "$patterns_file"
  else
    find "$base" -type f 2>/dev/null || true
  fi
}

_apply_excludes_stream() {
  # Lê paths absolutos em stdin e remove os que casam com exclude globs
  # Excludes são interpretados como substrings/globs simples contra caminho
  local excludes=("$@")
  if [[ ${#excludes[@]} -eq 0 ]]; then
    cat
    return
  fi

  # Monta expressão ERE unificada (escape básico de '.')
  local re=""
  for ex in "${excludes[@]}"; do
    # Normaliza padrão: transforma ** -> .*, * -> [^/]*  (aproximação)
    local e="$ex"
    e="${e//\./\\.}"
    e="${e//\*\*/.*}"
    e="${e//\*/[^/]*}"
    # remove anchors relativos
    [[ -n "$re" ]] && re="$re|"
    re="${re}${e}"
  done

  awk -v RS='\n' -v E="$re" '
    BEGIN{ if (E=="") pass=1; else pass=0 }
    {
      if (pass) { print; next }
      if ($0 ~ E) next
      print
    }'
}

resolve_file_set_from_config() {
  # $1: config.yaml  — emite lista de paths absolutos (stdout)
  local cfg="$1"
  init_win_mount "$cfg"

  local users; mapfile -t users < <(_select_users_from_config "$cfg")
  if [[ ${#users[@]} -eq 0 ]]; then
    log_warn "Nenhum usuário selecionado/encontrado em $WIN_MOUNT/Users"
    return 0
  fi
  local folders; mapfile -t folders < <(_read_known_folders "$cfg")
  if [[ ${#folders[@]} -eq 0 ]]; then
    log_warn "Nenhuma pasta conhecida definida em includes.known_folders"; return 0
  fi
  local patterns_file; patterns_file="$(_read_patterns_file "$cfg")"
  [[ -n "$patterns_file" && ! -f "$patterns_file" ]] && log_warn "patterns_file não existe: $patterns_file"

  local excludes; mapfile -t excludes < <(_read_excludes "$cfg")

  log_info "Usuários-alvo: ${users[*]}"
  log_info "Pastas-alvo: ${folders[*]}"
  [[ -n "$patterns_file" ]] && log_info "Filtro de padrões: $patterns_file"
  [[ ${#excludes[@]} -gt 0 ]] && log_info "Excludes: ${excludes[*]}"

  {
    for u in "${users[@]}"; do
      for f in "${folders[@]}"; do
        _emit_files_for_user_and_folder "$u" "$f" "$patterns_file"
      done
    done
  } | sed 's://*:/:g' | sort -u | _apply_excludes_stream "${excludes[@]}"
}

# ---------- Execução direta (teste) ----------
# Exemplo:
#   WIN_MOUNT=/media/win ./Paths.sh --list "/caminho/backup.config.yaml"
#   WIN_MOUNT=/media/win ./Paths.sh --map "{{Documents}}/foo.txt" USERNAME
#   WIN_MOUNT=/media/win ./Paths.sh --tokenize "/media/win/Users/USERNAME/Documents/foo.txt" USERNAME
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --list)
      cfg="${2:-config/backup.config.yaml}"
      resolve_file_set_from_config "$cfg"
      ;;
    --map)
      path="${2:?Informe token_path}"; user="${3:-}"
      init_win_mount ""
      map_token_to_abs_path "$path" "$user"
      ;;
    --tokenize)
      abs="${2:?Informe abs_path}"; user="${3:-}"
      init_win_mount ""
      tokenize_abs_path "$abs" "$user"
      ;;
    *)
      echo "Uso:"
      echo "  WIN_MOUNT=/media/win $0 --list <config.yaml>"
      echo "  WIN_MOUNT=/media/win $0 --map '{{Documents}}/file.txt' <UserName>"
      echo "  WIN_MOUNT=/media/win $0 --tokenize '/media/win/Users/<User>/Documents/file.txt' <UserName>"
      exit 0
      ;;
  esac
fi
