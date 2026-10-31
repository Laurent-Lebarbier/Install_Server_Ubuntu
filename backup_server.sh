#!/bin/bash
# =============================================================================
#  backup_server.sh — Sauvegarde complète du serveur (pour migration / réinstall)
#  Auteur  : Laurent Lebarbier
#  Version : 1.0
# =============================================================================
#
#  Crée UNE archive contenant tout ce que les scripts d'installation ne
#  savent pas recréer :
#    - server.conf (réglages, mots de passe, clés API OVH)
#    - toutes les bases MariaDB (dont vmail = comptes mail + alias)
#      et les comptes MariaDB avec leurs mots de passe (hachés)
#    - les mails           : /var/vmail
#    - la clé DKIM         : /etc/dkimkeys + /etc/opendkim
#    - les sites           : /var/www
#    - les fichiers FTP    : /home/ftpusers (+ mot de passe FTP)
#    - la liste des sous-domaines (manage_subdomains.sh), les VirtualHosts
#      Apache (pour référence) et les crontabs
#    - serveur cloud : config Nextcloud (dans /var/www) + sa base, Immich
#      (/opt/immich : docker-compose.yml + .env) et un export de sa base
#      PostgreSQL, le relais mail (/etc/msmtprc)
#      Les FICHIERS (Nextcloud /srv/nextcloud, photos Immich /srv/immich) ne
#      sont PAS inclus par défaut (plusieurs centaines de Go) : ajoutez
#      --avec-donnees-cloud si vous le voulez vraiment.
#
#  L'archive est CHIFFRÉE par défaut (AES-256, mot de passe demandé) : elle
#  contient la clé privée DKIM et les secrets de server.conf.
#
#  Usage :
#      sudo bash backup_server.sh                       # → /home/ubuntu/backups/
#                                                         (dossier du compte SSH)
#      sudo bash backup_server.sh --dest /mnt/disque    # autre dossier
#      sudo bash backup_server.sh --pass-file /root/.backup_pass   # sans question (cron)
#      sudo bash backup_server.sh --no-encrypt          # archive en clair (déconseillé)
#      sudo bash backup_server.sh --keep 7              # garde les 7 dernières (défaut : 5)
#      sudo bash backup_server.sh --avec-donnees-cloud  # + fichiers Nextcloud et photos Immich
#
#  Envoi automatique chaque nuit vers l'autre serveur : backup_remote.sh
#
#  Restauration : voir restore_server.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

log() {
    local level="$1"; shift
    local ts; ts=$(date '+%H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO ]${RESET} $ts — $*" ;;
        WARN)  echo -e "${YELLOW}[WARN ]${RESET} $ts — $*" ;;
        ERROR) echo -e "${RED}[ERROR]${RESET} $ts — $*" ;;
        STEP)  echo -e "\n${MAGENTA}${BOLD}▶ $*${RESET}" ;;
        OK)    echo -e "${GREEN}${BOLD}  ✔  $*${RESET}" ;;
    esac
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') — backup_server — $*" >> /var/log/install_server.log 2>/dev/null || true
}

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_FILE="${SCRIPT_DIR}/server.conf"
[[ -f "$CONFIG_FILE" ]] || { log ERROR "server.conf introuvable dans ${SCRIPT_DIR}."; exit 1; }
# shellcheck source=./server.conf
source "$CONFIG_FILE"
: "${DOMAIN:?DOMAIN manquant dans server.conf}"
SYS_USER="${SYS_USER:-}"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
# Propriétaire des archives : le compte de connexion SSH (ex : ubuntu), pour
# pouvoir les récupérer directement par scp — root n'est pas joignable en SSH.
OWNER="root"
if [[ -n "$SYS_USER" && "$SYS_USER" != "root" ]] && id "$SYS_USER" &>/dev/null; then
    OWNER="$SYS_USER"
fi
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
DEST="${OWNER_HOME:-/root}/backups"
DEST_IS_DEFAULT=1
ENCRYPT=1
PASS_FILE=""
KEEP=5
CLOUD_DATA=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)       DEST="${2:?--dest attend un dossier}"; DEST_IS_DEFAULT=0; shift 2 ;;
        --no-encrypt) ENCRYPT=0; shift ;;
        --pass-file)  PASS_FILE="${2:?--pass-file attend un fichier}"; shift 2 ;;
        --keep)       KEEP="${2:?--keep attend un nombre}"; shift 2 ;;
        --avec-donnees-cloud) CLOUD_DATA=1; shift ;;
        -h|--help)    sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log ERROR "Option inconnue : $1"; exit 1 ;;
    esac
done
[[ "$KEEP" =~ ^[0-9]+$ ]] || { log ERROR "--keep attend un nombre."; exit 1; }

# Mot de passe de chiffrement
PASSPHRASE=""
if [[ "$ENCRYPT" == 1 ]]; then
    command -v openssl &>/dev/null || { log ERROR "openssl requis pour le chiffrement."; exit 1; }
    if [[ -n "$PASS_FILE" ]]; then
        [[ -r "$PASS_FILE" ]] || { log ERROR "Fichier de mot de passe illisible : ${PASS_FILE}"; exit 1; }
        PASSPHRASE=$(head -n1 "$PASS_FILE")
    else
        echo -e "\n${BOLD}  🔐 Mot de passe de l'archive${RESET} (à conserver : sans lui, restauration impossible)"
        while true; do
            read -rsp "  Mot de passe : " PASSPHRASE; echo
            read -rsp "  Confirmez   : " p2; echo
            if [[ "$PASSPHRASE" != "$p2" ]]; then log WARN "Différents, recommencez."
            elif (( ${#PASSPHRASE} < 12 )); then log WARN "Minimum 12 caractères."
            else break; fi
        done
    fi
    [[ -n "$PASSPHRASE" ]] || { log ERROR "Mot de passe vide."; exit 1; }
fi

STAMP=$(date +%Y%m%d_%H%M%S)
NAME="server_backup_${DOMAIN}_${STAMP}.tar.gz"
[[ "$ENCRYPT" == 1 ]] && NAME="${NAME}.enc"
mkdir -p "$DEST"; chmod 700 "$DEST"
[[ "$DEST_IS_DEFAULT" == 1 ]] && chown "${OWNER}:" "$DEST"
ARCHIVE="${DEST}/${NAME}"

STAGE=$(mktemp -d /root/.backup_stage.XXXXXX)
chmod 700 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/meta" "$STAGE/db"

log STEP "Sauvegarde de ${DOMAIN} → ${ARCHIVE}"

# ---------------------------------------------------------------------------
# 1. Informations & configuration
# ---------------------------------------------------------------------------
cp "$CONFIG_FILE" "$STAGE/meta/server.conf"
{
    echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo "domain=${DOMAIN}"
    echo "server_ip=${SERVER_IP:-}"
    echo "os=$(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "role=${SERVER_ROLE:-web}"
    echo "format=1"
} > "$STAGE/meta/info.txt"

# ---------------------------------------------------------------------------
# 2. Bases de données + comptes MariaDB
# ---------------------------------------------------------------------------
if command -v mysql &>/dev/null && mysql -e "SELECT 1" &>/dev/null; then
    log STEP "Bases de données"
    # Exclues : bases système, et phpmyadmin (recréée par le paquet)
    while IFS= read -r db; do
        mysqldump --single-transaction --routines --triggers --events \
            --default-character-set=utf8mb4 "$db" > "$STAGE/db/${db}.sql"
        log OK "Base ${db} ($(du -h "$STAGE/db/${db}.sql" | cut -f1))"
    done < <(mysql -N -e "SHOW DATABASES" | grep -vxE 'information_schema|performance_schema|mysql|sys|phpmyadmin')

    # Comptes MariaDB (mot de passe haché + droits). Exclus : comptes système,
    # phpmyadmin (paquet) et vmail (recréé par install_mail.sh avec le mot de
    # passe de server.conf, déjà cohérent avec les fichiers Postfix/Dovecot).
    : > "$STAGE/db/users.sql"
    while IFS=$'\t' read -r u h; do
        create=$(mysql -N -e "SHOW CREATE USER '${u}'@'${h}'")
        echo "${create/CREATE USER/CREATE USER IF NOT EXISTS};" >> "$STAGE/db/users.sql"
        echo "${create/CREATE USER/ALTER USER};"                >> "$STAGE/db/users.sql"
        mysql -N -e "SHOW GRANTS FOR '${u}'@'${h}'" | sed 's/$/;/' >> "$STAGE/db/users.sql"
    done < <(mysql -N -e "SELECT User, Host FROM mysql.user
                          WHERE User NOT IN ('', 'root', 'mysql', 'mariadb.sys', 'phpmyadmin', 'debian-sys-maint', 'vmail')")
    log OK "Comptes MariaDB : $(grep -c '^CREATE USER' "$STAGE/db/users.sql" || true)"
else
    log WARN "MariaDB inaccessible — bases non sauvegardées."
fi

# ---------------------------------------------------------------------------
# 2bis. Immich : export de la base PostgreSQL (méthode de la doc Immich)
# ---------------------------------------------------------------------------
IMMICH_DIR="${IMMICH_DIR:-/opt/immich}"
if command -v docker &>/dev/null \
   && [[ "$(docker inspect -f '{{.State.Running}}' immich_postgres 2>/dev/null)" == "true" ]]; then
    log STEP "Base Immich"
    imm_user=$(grep -m1 '^DB_USERNAME=' "${IMMICH_DIR}/.env" 2>/dev/null | cut -d= -f2)
    set +e
    docker exec immich_postgres pg_dumpall --clean --if-exists --username="${imm_user:-postgres}" \
        | gzip > "$STAGE/db/immich.sql.gz"
    irc=("${PIPESTATUS[@]}")
    set -e
    if (( irc[0] != 0 || irc[1] != 0 )); then
        rm -f "$STAGE/db/immich.sql.gz"
        log WARN "Export de la base Immich échoué — sauvegarde poursuivie sans elle."
    else
        log OK "Base Immich ($(du -h "$STAGE/db/immich.sql.gz" | cut -f1))"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Sous-domaines, VirtualHosts, crontabs, FTP
# ---------------------------------------------------------------------------
log STEP "Configuration (sous-domaines, Apache, cron, FTP)"

# Format : nom|site   ou   nom|proxy|hôte:port
: > "$STAGE/meta/subdomains.txt"
for conf in /etc/apache2/sites-available/*."${DOMAIN}".conf; do
    [[ -f "$conf" && "$conf" != *-le-ssl.conf ]] || continue
    tag=$(grep -m1 '^# Géré par manage_subdomains.sh' "$conf" || true)
    [[ -n "$tag" ]] || continue
    sub=$(basename "$conf" .conf); sub="${sub%."${DOMAIN}"}"
    if [[ "$tag" =~ type:\ proxy\ ([^ ]+) ]]; then
        echo "${sub}|proxy|${BASH_REMATCH[1]}" >> "$STAGE/meta/subdomains.txt"
    else
        echo "${sub}|site" >> "$STAGE/meta/subdomains.txt"
    fi
done
log OK "Sous-domaines : $(wc -l < "$STAGE/meta/subdomains.txt")"

if [[ -d /etc/apache2/sites-available ]]; then
    cp -a /etc/apache2/sites-available "$STAGE/meta/apache-sites"
fi

crontab -l -u root > "$STAGE/meta/crontab.root" 2>/dev/null || rm -f "$STAGE/meta/crontab.root"
if [[ -n "$SYS_USER" ]] && id "$SYS_USER" &>/dev/null; then
    crontab -l -u "$SYS_USER" > "$STAGE/meta/crontab.user" 2>/dev/null || rm -f "$STAGE/meta/crontab.user"
fi

[[ -f /etc/pure-ftpd/pureftpd.passwd ]] && cp /etc/pure-ftpd/pureftpd.passwd "$STAGE/meta/pureftpd.passwd"

# ---------------------------------------------------------------------------
# 4. Création de l'archive (flux : tar → gzip → chiffrement)
# ---------------------------------------------------------------------------
log STEP "Création de l'archive"
PATHS=()
CANDIDATES=(var/vmail var/www etc/dkimkeys etc/opendkim home/ftpusers
            "${IMMICH_DIR#/}" etc/msmtprc)
(( CLOUD_DATA )) && CANDIDATES+=(srv/nextcloud srv/immich/library)
for p in "${CANDIDATES[@]}"; do
    if [[ -e "/$p" ]]; then
        PATHS+=("$p")
        log INFO "/$p ($(du -sh "/$p" 2>/dev/null | cut -f1))"
    fi
done

# Exclus : la base PostgreSQL brute d'Immich (exportée plus haut) et les
# fichiers Nextcloud s'ils étaient rangés sous /var/www (sauf option)
EXCLUDES=(--exclude='srv/immich/postgres')
if (( ! CLOUD_DATA )); then
    EXCLUDES+=(--exclude='var/www/*/data/*/files' --exclude='var/www/*/data/appdata_*')
fi

make_tar() {
    tar --create --gzip --warning=no-file-changed "${EXCLUDES[@]}" \
        -C "$STAGE" meta db \
        -C / "${PATHS[@]}"
}

set +e
if [[ "$ENCRYPT" == 1 ]]; then
    make_tar | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
        -pass fd:3 -out "$ARCHIVE" 3<<< "$PASSPHRASE"
else
    make_tar > "$ARCHIVE"
fi
rc=("${PIPESTATUS[@]}")
set -e
# tar rend 1 si un fichier a changé pendant la lecture (mail reçu…) : bénin
if (( rc[0] > 1 )) || (( ${rc[1]:-0} != 0 )); then
    rm -f "$ARCHIVE"
    log ERROR "Échec de la création de l'archive (codes : ${rc[*]})."; exit 1
fi
chmod 600 "$ARCHIVE"

# ---------------------------------------------------------------------------
# 5. Vérification : l'archive se relit entièrement
# ---------------------------------------------------------------------------
log STEP "Vérification de l'archive"
set +e
if [[ "$ENCRYPT" == 1 ]]; then
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 -in "$ARCHIVE" 3<<< "$PASSPHRASE" \
        | tar -tzf - > /dev/null
else
    tar -tzf "$ARCHIVE" > /dev/null
fi
vrc=("${PIPESTATUS[@]}")
set -e
if (( ${vrc[0]} != 0 )) || (( ${vrc[1]:-0} != 0 )); then
    log ERROR "L'archive ne se relit pas correctement — ne vous y fiez pas !"; exit 1
fi
# Empreinte avec un nom relatif : vérifiable avec « sha256sum -c » depuis
# n'importe quel dossier où les deux fichiers sont copiés ensemble
(cd "$DEST" && sha256sum "$NAME" > "${NAME}.sha256")
chown "${OWNER}:" "$ARCHIVE" "${ARCHIVE}.sha256"
log OK "Archive vérifiée ($(du -h "$ARCHIVE" | cut -f1))."

# ---------------------------------------------------------------------------
# 6. Rotation : on garde les $KEEP plus récentes
# ---------------------------------------------------------------------------
if (( KEEP > 0 )); then
    mapfile -t old < <(find "$DEST" -maxdepth 1 -name "server_backup_${DOMAIN}_*.tar.gz*" ! -name '*.sha256' \
                            -printf '%T@ %p\n' | sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2-)
    for f in "${old[@]}"; do
        rm -f -- "$f" "${f}.sha256"
        log INFO "Ancienne sauvegarde supprimée : $(basename "$f")"
    done
fi

log STEP "Sauvegarde terminée"
echo -e "  Archive : ${BOLD}${ARCHIVE}${RESET}"
[[ "$ENCRYPT" == 1 ]] && echo -e "  ${YELLOW}Chiffrée — gardez le mot de passe, il sera demandé à la restauration.${RESET}"
echo -e "  ${YELLOW}Copiez-la HORS du serveur, par exemple depuis votre PC :${RESET}"
echo -e "    scp ${OWNER}@${SERVER_IP:-IP}:${ARCHIVE}* ."
