#!/usr/bin/env bash
# =======================================================
# src/Lib/Inventory.sh — Inventário de softwares (Windows montado)
# =======================================================
# Propósito:
#   Rodando em Linux, coletar inventário de aplicativos de um
#   disco Windows montado (WIN_MOUNT), priorizando o Registro
#   do Windows (via hivexregedit se disponível) e com fallback
#   para heurísticas de diretórios (Program Files / Start Menu).
#
# Saídas (função principal):
#   collect_inventory_windows_mounted <out_json> <out_md>
#     - <out_json>: JSON máquina-legível com metadados + items
#     - <out_md>  : relatório Markdown tabular
#
# Dependências:
#   - Logging.sh (log_info/log_warn/log_error)
#   - Paths.sh (init_win_mount, list_windows_users)    [para localizar WIN_MOUNT e usuários]
#   - opcional: hivexregedit (pacote: libhivex-bin)   [para ler hives do Registro]
#
# Itens coletados (campos):
#   name | version | source | publisher | location
#   - source: HKLM, HKCU:<user>, Dir:ProgramFiles, Dir:ProgramFilesX86, StartMenu
#   - location: caminho de origem (chave do Registro ou diretório/lnk)
#
# Segurança:
#   - Não utiliza credenciais; não acessa rede; somente leitura do disco.
# =======================================================

set -euo pipefail

# ---------- bootstrap de logger (se chamado isolado) ----------
# shellcheck disable=SC1091
if ! command -v log_info >/dev/null 2>&1; then
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$THIS_DIR/Logging.sh" ]] && source "$THIS_DIR/Logging.sh"
fi

# Carrega Paths (para WIN_MOUNT e usuários)
if ! command -v init_win_mount >/dev/null 2>&1; then
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$THIS_DIR/Paths.sh" ]] && source "$THIS_DIR/Paths.sh"
fi

# =======================================================
# Helpers
# =======================================================

_have_hivex() {
  command -v hivexregedit >/dev/null 2>&1
}

# Emite JSON com metadata do host Linux e do Windows montado (versão aproximada)
_sys_metadata_json() {
  local host kernel distro winver="unknown"

  host="$(hostname 2>/dev/null || echo unknown)"
  kernel="$(uname -r 2>/dev/null || echo unknown)"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro="${NAME:-unknown} ${VERSION:-}"
  else
    distro="unknown"
  fi

  # Tentativa simples de detectar versão do Windows a partir de "ProductName" no SOFTWARE hive
  if _have_hivex && [[ -f "$WIN_MOUNT/Windows/System32/config/SOFTWARE" ]]; then
    # Exporta chave CurrentVersion
    local tmpf; tmpf="$(mktemp -t winver.XXXX)"
    if hivexregedit --export "$WIN_MOUNT/Windows/System32/config/SOFTWARE" \
       'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion' > "$tmpf" 2>/dev/null; then
      # Procura ProductName e CurrentBuild
      local pn cb
      pn="$(awk -F'=' '/"ProductName"/{gsub(/^"|"$/,"",$2);gsub(/^"/,"",$2);gsub(/"$/,"",$2);gsub(/^"/,"",$2);print $2}' "$tmpf" | head -n1)"
      cb="$(awk -F'=' '/"CurrentBuild"/{gsub(/^"|"$/,"",$2);print $2}' "$tmpf" | head -n1)"
      winver="$(printf "%s (build %s)" "${pn:-Windows}" "${cb:-?}")"
    fi
    rm -f "$tmpf"
  fi

  printf '{"linux_host":"%s","linux_kernel":"%s","linux_distro":"%s","windows_version":"%s"}' \
    "$(echo "$host"   | sed 's/"/\\"/g')" \
    "$(echo "$kernel" | sed 's/"/\\"/g')" \
    "$(echo "$distro" | sed 's/"/\\"/g')" \
    "$(echo "$winver" | sed 's/"/\\"/g')"
}

# Acumula resultados em stream tabulado:
#   name \t version \t source \t publisher \t location
_emit_row() {
  local name="$1" ver="$2" src="$3" pub="$4" loc="$5"
  [[ -z "$name" ]] && return 0
  printf "%s\t%s\t%s\t%s\t%s\n" "$name" "$ver" "$src" "$pub" "$loc"
}

# =======================================================
# Coleta via Registro do Windows (HKLM/HKCU) usando hivexregedit
# =======================================================

# Parser simples para .reg (saída do hivexregedit --export)
# Lê blocos [HKEY_...] e coleta DisplayName, DisplayVersion, Publisher
_parse_uninstall_reg_stream() {
  # $1: fonte (ex.: HKLM, HKCU:<user>)
  local src="$1"
  awk -v SRC="$src" '
    BEGIN{
      name=""; ver=""; pub=""; loc="";
    }
    /^\[/ {
      # imprime o anterior se tinha nome
      if (name != "") {
        printf "%s\t%s\t%s\t%s\t%s\n", name, ver, SRC, pub, loc
      }
      name=""; ver=""; pub=""; loc=$0
      next
    }
    /"DisplayName"=/ {
      $0=$0; sub(/^.*="/,""); sub(/"$/,"");
      name=$0
      next
    }
    /"DisplayVersion"=/ {
      $0=$0; sub(/^.*="/,""); sub(/"$/,"");
      ver=$0
      next
    }
    /"Publisher"=/ {
      $0=$0; sub(/^.*="/,""); sub(/"$/,"");
      pub=$0
      next
    }
    END{
      if (name != "") {
        printf "%s\t%s\t%s\t%s\t%s\n", name, ver, SRC, pub, loc
      }
    }
  '
}

_collect_hklm_uninstall() {
  # SOFTWARE hive 64-bit contém Uninstall 64 e Wow6432Node (32-bit)
  local hive="$WIN_MOUNT/Windows/System32/config/SOFTWARE"
  [[ -f "$hive" ]] || { log_warn "Hive HKLM SOFTWARE não encontrado: $hive"; return 0; }

  log_info "Lendo Registro HKLM (SOFTWARE)..."
  local tmpf
  tmpf="$(mktemp -t hklm.XXXX)"

  # Uninstall (64-bit)
  if hivexregedit --export "$hive" 'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall' > "$tmpf" 2>/dev/null; then
    _parse_uninstall_reg_stream "HKLM" < "$tmpf"
  fi

  # Wow6432Node (32-bit)
  if hivexregedit --export "$hive" 'HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall' > "$tmpf" 2>/dev/null; then
    _parse_uninstall_reg_stream "HKLM" < "$tmpf"
  fi

  rm -f "$tmpf"
}

_collect_hkcu_uninstall_for_user() {
  # NTUSER.DAT por usuário (instalações por usuário)
  local user="$1"
  local ntuser="$WIN_MOUNT/Users/$user/NTUSER.DAT"
  [[ -f "$ntuser" ]] || return 0

  log_info "Lendo Registro HKCU para usuário: $user"
  local tmpf
  tmpf="$(mktemp -t hkcu.XXXX)"

  if hivexregedit --export "$ntuser" 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall' > "$tmpf" 2>/dev/null; then
    _parse_uninstall_reg_stream "HKCU:'$user'" < "$tmpf"
  fi

  rm -f "$tmpf"
}

_collect_registry_inventory() {
  _have_hivex || { log_warn "hivexregedit ausente — inventário via Registro não disponível."; return 0; }

  _collect_hklm_uninstall

  # Por usuário (HKCU)
  local users; mapfile -t users < <(list_windows_users)
  for u in "${users[@]}"; do
    _collect_hkcu_uninstall_for_user "$u"
  done
}

# =======================================================
# Fallbacks por diretório (Program Files / Start Menu)
# =======================================================

_collect_program_files_dirs() {
  # Heurística: listar diretórios dentro de Program Files como pacotes
  local pf64="$WIN_MOUNT/Program Files"
  local pf32="$WIN_MOUNT/Program Files (x86)"

  if [[ -d "$pf64" ]]; then
    find "$pf64" -mindepth 1 -maxdepth 1 -type d -printf "%f\t\tDir:ProgramFiles\t\t%s\n" {} 2>/dev/null | \
      sed "s|\t$WIN_MOUNT/Program Files/|\t|g" | \
      awk -F'\t' '{printf "%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,("'"$pf64"'/"$1)}'
  fi

  if [[ -d "$pf32" ]]; then
    find "$pf32" -mindepth 1 -maxdepth 1 -type d -printf "%f\t\tDir:ProgramFilesX86\t\t%s\n" {} 2>/dev/null | \
      sed "s|\t$WIN_MOUNT/Program Files (x86)/|\t|g" | \
      awk -F'\t' '{printf "%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,("'"$pf32"'/"$1)}'
  fi
}

_collect_start_menu_shortcuts() {
  # Mapear atalhos do menu Iniciar (todos os usuários)
  local sm="$WIN_MOUNT/ProgramData/Microsoft/Windows/Start Menu/Programs"
  [[ -d "$sm" ]] || return 0

  # Considera .lnk como "nome"; versão/publisher desconhecidos
  find "$sm" -type f -name "*.lnk" -print0 2>/dev/null | \
    xargs -0 -I{} basename "{}" | sed 's/\.lnk$//' | \
    while IFS= read -r base; do
      _emit_row "$base" "" "StartMenu" "" "$sm/$base.lnk"
    done
}

# =======================================================
# Deduplicação e formatações
# =======================================================

_dedup_rows() {
  # Dedup por (name|version|source); mantém primeiro publisher/location
  awk -F'\t' '
    BEGIN{OFS="\t"}
    {
      key=$1 "|" $2 "|" $3
      if(!(key in seen)){
        seen[key]=1
        print $1,$2,$3,$4,$5
      }
    }'
}

_stream_to_json_array() {
  awk -F'\t' '
    BEGIN{ print "["; first=1 }
    {
      name=$1; ver=$2; src=$3; pub=$4; loc=$5
      gsub(/"/,"\\\"",name); gsub(/"/,"\\\"",ver); gsub(/"/,"\\\"",src);
      gsub(/"/,"\\\"",pub);  gsub(/"/,"\\\"",loc);
      line=sprintf("{\"name\":\"%s\",\"version\":\"%s\",\"source\":\"%s\",\"publisher\":\"%s\",\"location\":\"%s\"}",name,ver,src,pub,loc)
      if(first){ printf "  %s", line; first=0 } else { printf ",\n  %s", line }
    }
    END{ print "\n]" }'
}

_stream_to_markdown() {
  # Ordena por source, name
  sort -t$'\t' -k3,3 -k1,1 | \
  awk -F'\t' '
    BEGIN{
      print "| Nome | Versão | Fonte | Publisher | Local |"
      print "|------|--------|-------|-----------|-------|"
    }
    {
      n=$1; v=$2; s=$3; p=$4; l=$5
      if(p=="") p="-"; if(v=="") v="-";
      gsub(/\|/,"\\|",n); gsub(/\|/,"\\|",p); gsub(/\|/,"\\|",l);
      printf "| %s | %s | %s | %s | %s |\n", n, v, s, p, l
    }'
}

# =======================================================
# Função pública principal
# =======================================================

collect_inventory_windows_mounted() {
  local out_json="$1"
  local out_md="$2"

  # WIN_MOUNT deve estar definido (via init_win_mount já executado pelo chamador)
  if [[ -z "${WIN_MOUNT:-}" || ! -d "$WIN_MOUNT" ]]; then
    log_error "WIN_MOUNT não definido/ inválido. Chame init_win_mount <config.yaml> antes."
    exit 2
  fi

  log_info "Coletando inventário do Windows em: $WIN_MOUNT"

  local tmp; tmp="$(mktemp -t invwin.XXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT

  {
    # 1) Registro (se houver hivexregedit)
    _collect_registry_inventory
    # 2) Fallbacks por diretórios
    _collect_program_files_dirs
    _collect_start_menu_shortcuts
  } | sed '/^[[:space:]]*$/d' | _dedup_rows > "$tmp" || true

  # JSON
  {
    echo "{"
    echo '  "metadata": '"$(_sys_metadata_json)"","
    echo '  "items":'
    _stream_to_json_array < "$tmp"
    echo "}"
  } > "$out_json"

  # Markdown
  {
    echo "# Inventário de Softwares — Windows (disco montado)"
    echo
    echo "- Montagem: \`$WIN_MOUNT\`"
    echo "- Gerado em: $(date -Iseconds)"
    echo
    _stream_to_markdown < "$tmp"
    echo
    echo "_Observações:_"
    echo "- Itens de **HKLM/HKCU** dependem do utilitário \`hivexregedit\`."
    echo "- Itens **Dir:ProgramFiles** e **StartMenu** são heurísticos e podem conter entradas auxiliares/duplicadas."
  } > "$out_md"

  log_info "Inventário gerado: JSON -> $out_json ; Markdown -> $out_md"
}

# =======================================================
# Execução direta (teste manual)
# =======================================================
# Exemplos:
#   export WIN_MOUNT=/media/win
#   ./Inventory.sh /tmp/InstalledSoftware.json /tmp/InstalledSoftware.md
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Uso: WIN_MOUNT=/media/win $0 <out_json> <out_md>"
    exit 1
  fi
  collect_inventory_windows_mounted "$1" "$2"
fi
