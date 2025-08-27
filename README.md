# Windows Backup/Restore (Linux) — README

Projeto de **backup e restauração de arquivos de um disco Windows** a partir de um sistema Linux, com seleção por *Known Folders*, padrões de arquivos, inventário de softwares, compactação 7-Zip (com criptografia opcional), manifest tokenizado e rotação de pacotes.

> **Estado do projeto (v1.0)**
>
> * **Backup**: estável (seleção por *Known Folders*, inventário, rotação, 7z/zip, hash).
> * **Restore**: funcional, porém com **avisos importantes** na seção [⚠️ Notas importantes / limitações](#️-notas-importantes--limitações) (leia antes de usar `--only-folder`).
> * **Manifest/Inventário**: estáveis.

---

## Sumário

- [Windows Backup/Restore (Linux) — README](#windows-backuprestore-linux--readme)
  - [Sumário](#sumário)
  - [Arquitetura e visão](#arquitetura-e-visão)
  - [Estrutura de diretórios](#estrutura-de-diretórios)
  - [Requisitos](#requisitos)
  - [Instalação](#instalação)
  - [Montagem do disco Windows (NTFS)](#montagem-do-disco-windows-ntfs)
  - [Configuração](#configuração)
    - [Defina o ponto de montagem](#defina-o-ponto-de-montagem)
    - [Raiz de backup, rotação e criptografia](#raiz-de-backup-rotação-e-criptografia)
    - [Usuários e Pastas (Known Folders)](#usuários-e-pastas-known-folders)
    - [Padrões de inclusão](#padrões-de-inclusão)
    - [Exclusões globais](#exclusões-globais)
    - [Inventário de softwares](#inventário-de-softwares)
  - [Como usar — Backup](#como-usar--backup)
  - [Como usar — Restore](#como-usar--restore)
  - [Criptografia](#criptografia)
  - [Rotação de backups](#rotação-de-backups)
  - [Validação, listagem e integridade](#validação-listagem-e-integridade)
  - [Agendamento (cron/systemd)](#agendamento-cronsystemd)
  - [⚠️ Notas importantes / limitações](#️-notas-importantes--limitações)
  - [Solução de problemas](#solução-de-problemas)
    - [Exemplos rápidos (receitas)](#exemplos-rápidos-receitas)
  - [Anexos — Referência rápida de *Known Folders*](#anexos--referência-rápida-de-known-folders)

---

## Arquitetura e visão

* **Entrada (Backup):** disco Windows **montado** no Linux (`WIN_MOUNT`), seleção de usuários/pastas (*Known Folders*) e padrões de arquivo.
* **Saídas:**

  * **Pacote** `.7z` (preferencial) ou `.zip` contendo os arquivos selecionados.
  * `manifest.json` (tokeniza caminhos com `{{Documents}}/...`, `{{Pictures}}/...` etc.), hashes SHA-256, tamanhos e metadados.
  * **Inventário** de softwares (`InstalledSoftware.json` + `InstalledSoftware.md`) via Registro do Windows (`hivexregedit`) e heurísticas de diretórios.
  * `*.sha256` com a soma do pacote.
* **Restauração:** extrai o pacote e reidrata cada arquivo para o **novo** disco Windows montado, resolvendo tokens para caminhos reais (com `--user-map` opcional).
* **Segurança:** suporte opcional à criptografia 7-Zip (senha **nunca** logada).
* **Princípios:** simples, mensurável, robusto e auditável.

---

## Estrutura de diretórios

```
.
├── config/
│   ├── backup.config.yaml
│   └── samples/
│       └── include-patterns.txt
└── src/
    ├── BackupWindows.sh
    ├── RestoreWindows.sh
    └── Lib/
        ├── Compression.sh
        ├── Hashing.sh
        ├── Inventory.sh
        ├── Logging.sh
        ├── Manifest.sh
        └── Paths.sh
```

---

## Requisitos

**Pacotes (Debian/Ubuntu):**

```bash
sudo apt-get update
sudo apt-get install -y \
  jq ntfs-3g zip unzip p7zip-full libhivex-bin coreutils \
  moreutils # (sponge etc., opcional)
# yq (Mike Farah) – recomendado (Go):
sudo snap install yq # ou baixe binário oficial (https://github.com/mikefarah/yq)
# 7z "novo" (alternativo ao p7zip):
# sudo apt-get install -y 7zip
```

**Pacotes equivalentes:**

* **Arch/Manjaro:** `pacman -S jq ntfs-3g zip unzip p7zip hivex yq`
* **Fedora/RHEL:** `dnf install jq ntfs-3g zip unzip p7zip p7zip-plugins hivex2` e instale o `yq` (binário oficial).

**Observações:**

* `hivexregedit` vem em `libhivex-bin` (Debian/Ubuntu), `hivex` (Arch) ou `hivex2` (Fedora).
* `yq` (Mike Farah) é **fortemente recomendado**. Sem ele, há *fallbacks* simplificados de YAML.

---

## Instalação

1. **Clone** o projeto e torne os scripts executáveis:

   ```bash
   git clone <seu-repo> windows-backup-restore
   cd windows-backup-restore
   chmod +x src/*.sh src/Lib/*.sh
   ```

2. (Opcional) **ShellCheck** para qualidade:

   ```bash
   sudo apt-get install -y shellcheck
   shellcheck src/*.sh src/Lib/*.sh
   ```

---

## Montagem do disco Windows (NTFS)

1. **Identifique a partição** (ex.: via `lsblk -f`).
2. **Desative** no Windows o **Fast Startup/Hibernação** (evita NTFS “sujo”).
3. **Monte** (exemplo):

   ```bash
   sudo mkdir -p /media/win
   sudo mount -t ntfs-3g -o uid=$(id -u),gid=$(id -g),windows_names /dev/sdXN /media/win
   ```
4. **Teste**:

   ```bash
   ls /media/win/Users
   ```

---

## Configuração

Arquivo principal: `config/backup.config.yaml` (exemplo fornecido pelo projeto).

> **Importante:** defina **onde** o Windows está montado **ou** exporte `WIN_MOUNT`.

### Defina o ponto de montagem

Você pode **exportar** no ambiente:

```bash
export WIN_MOUNT="/media/win"
```

Ou acrescente ao YAML (recomendado):

```yaml
windows:
  mount: "/media/win"
```

### Raiz de backup, rotação e criptografia

```yaml
backup_root: "/mnt/backups_windows"

rotation:
  keep_last: 5
  max_age_days: 30
  prefix: "winbackup"

encryption:
  enabled: false
  password_env: "BACKUP_PASSWORD"
```

### Usuários e Pastas (Known Folders)

```yaml
users:
  - all  # ou liste nomes específicos existentes em C:\Users

includes:
  known_folders:
    - Desktop
    - Documents
    - Downloads
    - Pictures
    - Videos
    - Music
    - Favorites
    - AppDataRoaming
    - AppDataLocal
    - UserProfile
```

**Tokens suportados:**
`{{SystemDrive}} {{Windows}} {{ProgramFiles}} {{ProgramFilesX86}} {{ProgramData}} {{Users}} {{UserProfile}} {{Desktop}} {{Documents}} {{Downloads}} {{Pictures}} {{Videos}} {{Music}} {{Favorites}} {{AppDataRoaming}} {{AppDataLocal}}`

### Padrões de inclusão

O projeto traz um *sample* em `config/samples/include-patterns.txt`.
**Configure o arquivo na sua `backup.config.yaml`:**

```yaml
includes:
  known_folders:
    - Documents
    - Pictures
    # ...
  patterns_file: "config/samples/include-patterns.txt"
```

> **Nota:** a chave `includes.patterns` no YAML **ainda não é lida** pelo código v1.0. Utilize **`includes.patterns_file`**.

### Exclusões globais

Conforme exemplo já incluso no YAML:

```yaml
excludes:
  - "**/AppData/Local/Temp/**"
  - "**/.git/**"
  - "*.iso"
  # ...
```

### Inventário de softwares

```yaml
inventory:
  enabled: true
```

Requer `hivexregedit`. Se ausente, o módulo tenta heurísticas por diretórios.

---

## Como usar — Backup

**Dry-run (simulação) primeiro:**

```bash
WIN_MOUNT=/media/win \
src/BackupWindows.sh config/backup.config.yaml --dry-run --log-file /tmp/winbackup.log
```

**Execução real (7-Zip preferencial):**

```bash
WIN_MOUNT=/media/win \
src/BackupWindows.sh config/backup.config.yaml --log-file /var/log/winbackup.log
```

**Parâmetros úteis:**

* `--dry-run` — não copia/compacta, apenas estatísticas.
* `--force` — ignora alguns avisos (ex.: espaço).
* `--log-file <arquivo>` — registra log detalhado.
* `--win-mount <dir>` — sobrescreve o ponto de montagem.
* `--no-inventory` — não gera inventário.

**Saídas típicas (em `backup_root`):**

```
winbackup_YYYYMMDD_HHMMSS.7z
winbackup_YYYYMMDD_HHMMSS.7z.sha256
```

O pacote inclui: arquivos selecionados, `manifest.json`, `InstalledSoftware.*` (se habilitado) e a config efetiva.

---

## Como usar — Restore

Restaure para **outro** disco Windows montado (ex.: `/media/WIN_NEW`).

**Exemplo — pacote 7z com criptografia:**

```bash
export WIN_MOUNT="/media/WIN_NEW"
export BACKUP_ENCRYPTION=1
export BACKUP_PASSWORD="sua_senha"

src/RestoreWindows.sh \
  --source /mnt/backups_windows/winbackup_20250827_120000.7z \
  --check-archive-hash \
  --log-file /var/log/winrestore.log
```

**Exemplo — diretório já extraído:**

```bash
# 1) Extraia manualmente
7z x /mnt/backups_windows/winbackup_20250827_120000.7z -o/tmp/restore_root
# 2) Aponte o script para o diretório
WIN_MOUNT=/media/WIN_NEW src/RestoreWindows.sh --source /tmp/restore_root
```

**Filtros e mapeamentos:**

* `--only-user <nome>` — restaura apenas itens daquele usuário.
* `--user-map Origem:Destino` — mapeia usuário de origem para outro nome no destino (pode repetir).
* `--verify-only` — valida hashes/manifest e pára.
* `--skip-verify` — pula validação (não recomendado).
* `--force` — sobrescreve arquivos existentes sem perguntar.
* `--assume-yes` — confirma criação de diretórios automaticamente.
* `--keep-extracted` — mantém pasta temporária extraída (útil para auditoria).

> **Sobre `--only-folder`**: veja [⚠️ Notas importantes / limitações](#️-notas-importantes--limitações).

---

## Criptografia

* Habilite na config:

  ```yaml
  encryption:
    enabled: true
    password_env: "BACKUP_PASSWORD"
  ```
* **NUNCA** registre a senha em logs.
* No *runtime*, exporte:

  ```bash
  export BACKUP_PASSWORD='minha-senha-forte'
  ```
* Para `Restore`, exporte **os mesmos** `BACKUP_ENCRYPTION=1` e `BACKUP_PASSWORD`.

---

## Rotação de backups

Controlada por `rotation.keep_last` e `rotation.max_age_days` no YAML.
Ao final do `Backup`, o script **remove** pacotes mais antigos conforme a política.

---

## Validação, listagem e integridade

**Testar integridade do pacote:**

```bash
src/Lib/Compression.sh t /mnt/backups_windows/winbackup_*.7z
```

**Listar conteúdo (rápido):**

```bash
src/Lib/Compression.sh l /mnt/backups_windows/winbackup_*.7z
```

**Conferir SHA-256 do pacote:**

```bash
sha256sum -c /mnt/backups_windows/winbackup_*.7z.sha256
```

**Validar `manifest.json` contra arquivos extraídos (pré-restore):**

```bash
WIN_MOUNT=/media/WIN_NEW \
src/Lib/Manifest.sh verify /tmp/restore_root/manifest.json /tmp/restore_root
```

---

## Agendamento (cron/systemd)

**Cron diário 02:30:**

```bash
crontab -e
# Adicione:
30 2 * * * WIN_MOUNT=/media/win BACKUP_PASSWORD='...' BACKUP_ENCRYPTION=1 \
/caminho/projeto/src/BackupWindows.sh /caminho/projeto/config/backup.config.yaml \
--log-file /var/log/winbackup.log >> /var/log/winbackup.cron 2>&1
```

**systemd timer (exemplo mínimo):**

`/etc/systemd/system/winbackup.service`

```ini
[Unit]
Description=Windows Backup (7z) - Linux
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=WIN_MOUNT=/media/win
Environment=BACKUP_ENCRYPTION=1
Environment=BACKUP_PASSWORD=...
ExecStart=/caminho/projeto/src/BackupWindows.sh /caminho/projeto/config/backup.config.yaml --log-file /var/log/winbackup.log
```

`/etc/systemd/system/winbackup.timer`

```ini
[Unit]
Description=Agenda do Windows Backup

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now winbackup.timer
systemctl status winbackup.timer
```

---

## ⚠️ Notas importantes / limitações

1. **Ponto de montagem obrigatório:** defina `WIN_MOUNT` (ambiente) **ou** `windows.mount` no YAML.
2. **`includes.patterns_file`:** use o arquivo de padrões (`config/samples/include-patterns.txt`). A chave `includes.patterns` **não é lida** no v1.0.
3. **Estrutura do pacote e `Restore`:** o `RestoreWindows.sh` espera um conteúdo extraído com:

   ```
   <root>/
     manifest.json
     files/<token_path> ...   # ex.: files/{{Documents}}/projeto/relatorio.pdf
   ```

   O **Backup v1.0** compacta os **arquivos selecionados** e adiciona `manifest.json` ao pacote, mas **pode não materializar** a árvore `files/<token_path>` dentro do `.7z`.

   * **Solução prática (workaround):** extraia o `.7z` para um diretório e **reidrate** a árvore `files/` a partir do `manifest.json` antes de chamar o `Restore` apontando para esse diretório. Exemplo de reidratação (ajuste `EXTRACTED`):

     ```bash
     EXTRACTED="/tmp/restore_root"
     mkdir -p "$EXTRACTED/files"
     jq -r '.[] | [.token_path, .origin] | @tsv' "$EXTRACTED/manifest.json" | \
     while IFS=$'\t' read -r token origin; do
       mkdir -p "$EXTRACTED/files/$(dirname "$token")"
       # Se o pacote extraiu os caminhos originais, tente localizar o arquivo extraído:
       if [[ -f "$EXTRACTED/$origin" ]]; then
         cp -p -- "$EXTRACTED/$origin" "$EXTRACTED/files/$token"
       else
         echo "[WARN] Não encontrado: $EXTRACTED/$origin -> $token" >&2
       fi
     done
     ```

     Em seguida:

     ```bash
     WIN_MOUNT=/media/WIN_NEW src/RestoreWindows.sh --source "$EXTRACTED"
     ```
   * Uma atualização futura alinhará o `Backup` para **sempre** gerar a árvore `files/<token_path>` no pacote, eliminando esse passo.
4. **`--only-folder` (Restore):** está **experimental** no v1.0. A filtragem por pasta conhecida depende de campo `known_folder` no manifest, que ainda **não** é emitido. Por ora, prefira `--only-user` e/ou ajuste seus padrões no **backup**.
5. **NTFS/Permissões:** para escrita no destino, o NTFS deve estar montado **rw** e o Windows sem hibernação/fast-startup.
6. **Desempenho:** para muitos arquivos pequenos, o gargalo é E/S. 7-Zip já usa *multithread*; assegure I/O adequado.

---

## Solução de problemas

* **`WIN_MOUNT não definido`**
  Defina `export WIN_MOUNT="/media/win"` **ou** `windows.mount` no YAML.

* **`hivexregedit` ausente / inventário vazio**
  Instale `libhivex-bin` (Debian/Ubuntu) ou pacote equivalente. Se mesmo assim falhar, o inventário usa *fallback* por diretórios.

* **`7z` não encontrado**
  Instale `p7zip-full` (ou `7zip` novo). O projeto cai para `zip/unzip`, mas **sem criptografia**.

* **`Permission denied` no NTFS**
  Monte com `ntfs-3g` em modo leitura/escrita e desative hibernação/fast-startup no Windows.

* **`--only-folder` não surtiu efeito**
  Recurso experimental no v1.0. Use `--only-user` e/ou refine padrões no backup.

* **Espaço insuficiente**
  Use `--dry-run` para estimar tamanho; ajuste `KEEP_LAST`/`max_age_days`; libere espaço no destino.

---

### Exemplos rápidos (receitas)

**Backup com criptografia e log:**

```bash
export WIN_MOUNT=/media/win
export BACKUP_ENCRYPTION=1
export BACKUP_PASSWORD='Senha*Forte*Aqui'
src/BackupWindows.sh config/backup.config.yaml --log-file /var/log/winbackup.log
```

**Restaurar mapeando usuário `Harrison` → `Admin` no novo disco:**

```bash
export WIN_MOUNT=/media/WIN_NEW
src/RestoreWindows.sh \
  --source /mnt/backups_windows/winbackup_20250827_120000.7z \
  --user-map Harrison:Admin \
  --check-archive-hash \
  --force
```

**Validar manifest antes de copiar (auditoria):**

```bash
export WIN_MOUNT=/media/WIN_NEW
src/RestoreWindows.sh --source /tmp/restore_root --verify-only
```

---

## Anexos — Referência rápida de *Known Folders*

| Token                 | Exemplo no Windows montado                |
| --------------------- | ----------------------------------------- |
| `{{UserProfile}}`     | `/media/win/Users/<User>`                 |
| `{{Desktop}}`         | `/media/win/Users/<User>/Desktop`         |
| `{{Documents}}`       | `/media/win/Users/<User>/Documents`       |
| `{{Downloads}}`       | `/media/win/Users/<User>/Downloads`       |
| `{{Pictures}}`        | `/media/win/Users/<User>/Pictures`        |
| `{{Videos}}`          | `/media/win/Users/<User>/Videos`          |
| `{{Music}}`           | `/media/win/Users/<User>/Music`           |
| `{{Favorites}}`       | `/media/win/Users/<User>/Favorites`       |
| `{{AppDataRoaming}}`  | `/media/win/Users/<User>/AppData/Roaming` |
| `{{AppDataLocal}}`    | `/media/win/Users/<User>/AppData/Local`   |
| `{{ProgramFiles}}`    | `/media/win/Program Files`                |
| `{{ProgramFilesX86}}` | `/media/win/Program Files (x86)`          |
| `{{ProgramData}}`     | `/media/win/ProgramData`                  |
| `{{Windows}}`         | `/media/win/Windows`                      |

