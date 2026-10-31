#!/bin/bash
# =============================================================================
#  backup_remote.sh — Sauvegarde croisée entre deux serveurs (VPS ↔ dédié)
#  Auteur  : Laurent Lebarbier
#  Version : 1.0
# =============================================================================
#
#  Chaque nuit, ce serveur fait sa sauvegarde chiffrée (backup_server.sh) et
#  l'envoie sur l'AUTRE serveur, dans un autre datacenter :
#    VPS (web + mail)  ──►  serveur cloud   (sites, bases, mails, DKIM…)
#    serveur cloud     ──►  VPS             (config Nextcloud/Immich + bases)
#
#  Sécurité :
#    • compte dédié « sauvegarde » sur le serveur qui reçoit, sans mot de passe
#    • la clé SSH de l'envoyeur ne peut QUE déposer des fichiers dans SON
#      dossier de dépôt (rrsync -wo -no-del) : pas de shell, pas de lecture,
#      pas de --delete, pas de « .. »
#    • toutes les heures, le serveur qui reçoit range les archives terminées
#      dans /srv/sauvegardes-archives/<nom> (root seulement) : un envoyeur
#      piraté ne peut ni lire, ni effacer, ni écraser ses anciennes sauvegardes
#    • les archives sont chiffrées AES-256 avant de partir
#    • le serveur qui reçoit supprime lui-même les archives trop anciennes
#
#  Mise en place (une fois par sens) :
#    1) sur l'envoyeur :       sudo bash backup_remote.sh configurer
#         → affiche la commande « autoriser … » à copier
#    2) sur le receveur :      sudo bash backup_remote.sh autoriser <nom> "<clé>"
#    3) de retour sur l'envoyeur, valider : test de connexion + tâche cron
#
#  Autres commandes :
#      sudo bash backup_remote.sh envoyer            # sauvegarde + envoi (cron)
#      sudo bash backup_remote.sh etat               # dernier envoi, archives reçues
#      sudo bash backup_remote.sh revoquer <nom>     # retire l'accès d'un envoyeur
#      sudo bash backup_remote.sh autoriser <nom> "<clé>" --jours 60
#
#  ⚠ Le mot de passe de chiffrement (/root/.backup_pass) doit AUSSI être noté
#    ailleurs (gestionnaire de mots de passe) : si le serveur disparaît, c'est
#    la seule façon de relire ses sauvegardes.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO ]${RESET} $ts — $*" ;;
        WARN)  echo -e "${YELLOW}[WARN ]${RESET} $ts — $*" ;;
        ERROR) echo -e "${RED}[ERROR]${RESET} $ts — $*" ;;
        STEP)  echo -e "\n${MAGENTA}${BOLD}▶ $*${RESET}" ;;
        OK)    echo -e "${GREEN}${BOLD}  ✔  $*${RESET}" ;;
    esac
    echo "[$level] $ts — backup_remote — $*" >> /var/log/install_server.log 2>/dev/null || true
}

confirm() {
    local answer
    read -rp "$(echo -e "${YELLOW}  ❓ ${1:-Continuer ?} [O/n] : ${RESET}")" answer
    [[ "${answer,,}" =~ ^(o|oui|y|yes|)$ ]]
}

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_FILE="${SCRIPT_DIR}/server.conf"

# Côté envoyeur
readonly KEY_FILE="/root/.ssh/backup_remote_ed25519"
readonly KNOWN_HOSTS="/root/.ssh/known_hosts_backup_remote"
readonly PASS_FILE="/root/.backup_pass"
readonly CRON_FILE="/etc/cron.d/backup_remote"
readonly SEND_LOG="/var/log/backup_remote.log"
readonly LOCK_FILE="/run/backup_remote.lock"
# Côté receveur ("backup" existe déjà sur Ubuntu : uid 34, ne pas le réutiliser)
readonly RECV_USER="sauvegarde"
readonly RECV_HOME="/srv/sauvegardes"
readonly ARCH_HOME="/srv/sauvegardes-archives"
readonly PURGE_CRON="/etc/cron.hourly/backup-remote"
readonly KEY_TAG="backup-remote:"

load_conf() {
    [[ -f "$CONFIG_FILE" ]] || { log ERROR "server.conf introuvable dans ${SCRIPT_DIR}."; exit 1; }
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    : "${DOMAIN:?DOMAIN manquant dans server.conf}"
}

set_conf() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONFIG_FILE"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_FILE"
    else
        echo "${key}=\"${val}\"" >> "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE"
}

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; }

ssh_opts() {
    printf '%s\n' -i "$KEY_FILE" -p "${BACKUP_REMOTE_PORT:-22}" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=20 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS"
}

# Envoie des fichiers dans le dossier distant (chemin imposé par rrsync)
remote_put() {
    local -a opts; mapfile -t opts < <(ssh_opts)
    rsync -t --timeout=600 \
        -e "ssh $(printf '%q ' "${opts[@]}")" \
        "$@" "${RECV_USER}@${BACKUP_REMOTE_HOST}:"
}

# Dossier local des archives (même règle que backup_server.sh)
local_backup_dir() {
    local owner="root"
    if [[ -n "${SYS_USER:-}" && "${SYS_USER}" != "root" ]] && id "$SYS_USER" &>/dev/null; then
        owner="$SYS_USER"
    fi
    echo "$(getent passwd "$owner" | cut -d: -f6)/backups"
}

# Mail d'alerte si un « sendmail » existe (Postfix sur le VPS, msmtp sur le cloud)
alert() {
    local subject="$1" body="$2"
    command -v sendmail &>/dev/null || return 0
    printf 'To: %s\nSubject: [%s] %s\n\n%s\n\nJournal : %s\n' \
        "${ADMIN_EMAIL:-root}" "$(hostname)" "$subject" "$body" "$SEND_LOG" \
        | sendmail -t 2>/dev/null || true
}

# ===========================================================================
# ENVOYEUR — configurer
# ===========================================================================
cmd_configurer() {
    load_conf
    command -v rsync &>/dev/null || apt-get install -y -qq rsync >/dev/null
    log STEP "Sauvegarde croisée — configuration de l'envoi depuis ce serveur"

    # --- Nom de ce serveur (= dossier de l'autre côté) ---
    local def_name="${BACKUP_REMOTE_NAME:-${SERVER_ROLE:-web}-${DOMAIN}}" name
    read -rp "$(echo -e "  ${CYAN}Nom de ce serveur (dossier de réception) [${def_name}] : ${RESET}")" name
    name="${name:-$def_name}"; name="${name,,}"
    valid_name "$name" || { log ERROR "Nom invalide : minuscules, chiffres, . _ - uniquement."; return 1; }

    # --- Serveur qui reçoit ---
    local host port
    read -rp "$(echo -e "  ${CYAN}Adresse du serveur qui reçoit (IP ou nom) [${BACKUP_REMOTE_HOST:-}] : ${RESET}")" host
    host="${host:-${BACKUP_REMOTE_HOST:-}}"
    [[ -n "$host" ]] || { log ERROR "Adresse obligatoire."; return 1; }
    read -rp "$(echo -e "  ${CYAN}Port SSH [${BACKUP_REMOTE_PORT:-22}] : ${RESET}")" port
    port="${port:-${BACKUP_REMOTE_PORT:-22}}"
    [[ "$port" =~ ^[0-9]+$ ]] || { log ERROR "Port invalide."; return 1; }

    # --- Mot de passe de chiffrement ---
    if [[ ! -s "$PASS_FILE" ]]; then
        echo -e "\n${BOLD}  🔐 Mot de passe de chiffrement des sauvegardes${RESET}"
        echo -e "     Laissez vide pour en générer un (affiché une seule fois)."
        local p1 p2
        while true; do
            read -rsp "  Mot de passe : " p1; echo
            if [[ -z "$p1" ]]; then
                p1=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9'); p1="${p1:0:32}"
                break
            fi
            read -rsp "  Confirmez   : " p2; echo
            if [[ "$p1" != "$p2" ]]; then log WARN "Différents, recommencez."
            elif (( ${#p1} < 12 )); then log WARN "Minimum 12 caractères."
            else break; fi
        done
        ( umask 077; printf '%s\n' "$p1" > "$PASS_FILE" )
        echo -e "\n  ${RED}${BOLD}⚠  NOTEZ CE MOT DE PASSE MAINTENANT (gestionnaire de mots de passe) :${RESET}"
        echo -e "     ${BOLD}${p1}${RESET}"
        echo -e "  ${YELLOW}Sans lui, les sauvegardes envoyées sont illisibles si ce serveur disparaît.${RESET}"
        read -rp "  Appuyez sur Entrée une fois noté… " _
    else
        log INFO "Mot de passe de chiffrement existant : ${PASS_FILE}"
    fi

    # --- Clé SSH dédiée ---
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    if [[ ! -f "$KEY_FILE" ]]; then
        ssh-keygen -q -t ed25519 -N "" -C "backup-remote-${name}" -f "$KEY_FILE"
        log OK "Clé SSH dédiée créée : ${KEY_FILE}"
    fi
    local pub; pub=$(cut -d' ' -f1,2 "${KEY_FILE}.pub")

    set_conf BACKUP_REMOTE_NAME "$name"
    set_conf BACKUP_REMOTE_HOST "$host"
    set_conf BACKUP_REMOTE_PORT "$port"
    BACKUP_REMOTE_NAME="$name"; BACKUP_REMOTE_HOST="$host"; BACKUP_REMOTE_PORT="$port"

    echo -e "\n${BOLD}  ➜ Sur le serveur ${host}, lancez :${RESET}\n"
    echo -e "  ${CYAN}sudo bash ~/Install_Server_Ubuntu/backup_remote.sh autoriser ${name} \"${pub}\"${RESET}\n"
    echo -e "  (adaptez le chemin si les scripts sont ailleurs)"
    confirm "C'est fait ? Tester la connexion maintenant" || {
        log INFO "Relancez « $0 configurer » une fois la commande passée de l'autre côté."; return 0; }

    # --- Test : dépôt d'un petit fichier ---
    local t; t=$(mktemp -d)
    echo "Test de connexion depuis $(hostname) — $(date)" > "${t}/.test_connexion"
    if remote_put "${t}/.test_connexion"; then
        log OK "Connexion OK : ${RECV_USER}@${host} accepte les dépôts dans son dossier « ${name} »."
    else
        rm -rf "$t"
        log ERROR "Échec. Vérifiez : commande « autoriser » passée, port ${port} ouvert, rsync installé là-bas."
        return 1
    fi
    rm -rf "$t"

    # --- Tâche planifiée (heure décalée selon le rôle, pour ne pas croiser) ---
    local hour=3; [[ "${SERVER_ROLE:-web}" == "cloud" ]] && hour=4
    command -v cron &>/dev/null || apt-get install -y -qq cron >/dev/null
    mkdir -p "$(dirname "$CRON_FILE")"
    cat > "$CRON_FILE" <<CRON
# backup_remote.sh — sauvegarde chiffrée envoyée chaque nuit vers ${host}
30 ${hour} * * * root bash ${SCRIPT_DIR}/backup_remote.sh envoyer >> ${SEND_LOG} 2>&1
CRON
    chmod 644 "$CRON_FILE"
    log OK "Envoi programmé chaque nuit à ${hour} h 30 (${CRON_FILE})."

    if confirm "Faire une première sauvegarde + envoi maintenant ?"; then
        cmd_envoyer
    fi
}

# ===========================================================================
# ENVOYEUR — envoyer (cron)
# ===========================================================================
cmd_envoyer() {
    load_conf
    [[ -n "${BACKUP_REMOTE_HOST:-}" ]] || { log ERROR "Pas configuré : lancez « $0 configurer »."; exit 1; }
    [[ -s "$PASS_FILE" && -f "$KEY_FILE" ]] || { log ERROR "Mot de passe ou clé absent : relancez « $0 configurer »."; exit 1; }

    exec 9>"$LOCK_FILE"
    flock -n 9 || { log WARN "Un envoi est déjà en cours."; exit 0; }

    local start; start=$(date +%s)
    log STEP "Sauvegarde puis envoi vers ${BACKUP_REMOTE_HOST} (${BACKUP_REMOTE_NAME})"

    if ! bash "${SCRIPT_DIR}/backup_server.sh" --pass-file "$PASS_FILE" --keep "${BACKUP_LOCAL_KEEP:-3}"; then
        log ERROR "backup_server.sh a échoué."
        alert "ÉCHEC sauvegarde" "backup_server.sh a échoué sur $(hostname) — rien n'a été envoyé."
        exit 1
    fi

    local dir archive
    dir=$(local_backup_dir)
    archive=$(find "$dir" -maxdepth 1 -name "server_backup_${DOMAIN}_*.tar.gz*" ! -name '*.sha256' \
                -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
    [[ -n "$archive" && -f "${archive}.sha256" ]] || {
        log ERROR "Archive introuvable dans ${dir}."; alert "ÉCHEC sauvegarde" "Archive introuvable dans ${dir}."; exit 1; }

    local try ok=0
    for try in 1 2 3; do
        if remote_put "$archive" "${archive}.sha256"; then ok=1; break; fi
        log WARN "Envoi échoué (tentative ${try}/3), nouvel essai dans 60 s…"
        sleep 60
    done
    if (( ! ok )); then
        log ERROR "Envoi vers ${BACKUP_REMOTE_HOST} impossible."
        alert "ÉCHEC envoi sauvegarde" "L'archive $(basename "$archive") n'a pas pu être envoyée vers ${BACKUP_REMOTE_HOST}."
        exit 1
    fi
    log OK "Envoyé : $(basename "$archive") ($(du -h "$archive" | cut -f1)) en $(( $(date +%s) - start )) s."
}

# ===========================================================================
# RECEVEUR — autoriser / revoquer
# ===========================================================================
find_rrsync() {
    local r
    r=$(command -v rrsync 2>/dev/null || true)
    [[ -z "$r" && -x /usr/bin/rrsync ]] && r=/usr/bin/rrsync
    echo "$r"
}

cmd_autoriser() {
    local name="${1:-}" key="${2:-}" days="${3:-30}"
    name="${name,,}"
    valid_name "$name" || { log ERROR "Usage : $0 autoriser <nom> \"ssh-ed25519 AAAA…\" [--jours N]"; return 1; }
    [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 )) || { log ERROR "--jours attend un nombre ≥ 1."; return 1; }
    local ktype kdata
    ktype=$(awk '{print $1}' <<< "$key"); kdata=$(awk '{print $2}' <<< "$key")
    if [[ ! "$ktype" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$ || ! "$kdata" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
        log ERROR "Clé publique invalide (attendu : \"ssh-ed25519 AAAA…\", entre guillemets)."; return 1
    fi

    log STEP "Autorisation des dépôts de « ${name} » sur ce serveur"
    command -v rsync &>/dev/null || apt-get install -y -qq rsync >/dev/null
    local rr; rr=$(find_rrsync)
    [[ -n "$rr" ]] || { log ERROR "rrsync introuvable (paquet rsync ≥ 3.2.4 requis)."; return 1; }
    command -v python3 &>/dev/null || { log ERROR "python3 requis par rrsync."; return 1; }

    # Compte dédié, sans mot de passe (« * » : connexion par clé seulement)
    if ! id "$RECV_USER" &>/dev/null; then
        local gopt=(--user-group)
        getent group "$RECV_USER" &>/dev/null && gopt=(-g "$RECV_USER")
        useradd --system "${gopt[@]}" --create-home --home-dir "$RECV_HOME" --shell /bin/bash "$RECV_USER"
        usermod -p '*' "$RECV_USER"
        log OK "Compte ${RECV_USER} créé (dossier ${RECV_HOME}, sans mot de passe)."
    fi
    mkdir -p "${RECV_HOME}/${name}" "${RECV_HOME}/.ssh"
    chown "${RECV_USER}:${RECV_USER}" "$RECV_HOME" "${RECV_HOME}/${name}" "${RECV_HOME}/.ssh"
    chmod 750 "$RECV_HOME"; chmod 700 "${RECV_HOME}/${name}" "${RECV_HOME}/.ssh"

    # Clé limitée : rrsync -wo -no-del = dépôt seulement, dans SON dossier
    local ak="${RECV_HOME}/.ssh/authorized_keys"
    touch "$ak"
    local tmp; tmp=$(mktemp)
    grep -v " ${KEY_TAG}${name}\$" "$ak" > "$tmp" || true
    echo "restrict,command=\"${rr} -wo -no-del ${RECV_HOME}/${name}\" ${ktype} ${kdata} ${KEY_TAG}${name}" >> "$tmp"
    cat "$tmp" > "$ak"; rm -f "$tmp"
    chown "${RECV_USER}:${RECV_USER}" "$ak"; chmod 600 "$ak"
    log OK "Clé de « ${name} » autorisée en écriture seule dans ${RECV_HOME}/${name}."

    mkdir -p "${ARCH_HOME}/${name}"
    chown root:root "$ARCH_HOME" "${ARCH_HOME}/${name}"
    chmod 700 "$ARCH_HOME" "${ARCH_HOME}/${name}"

    command -v cron &>/dev/null || apt-get install -y -qq cron >/dev/null
    mkdir -p "$(dirname "$PURGE_CRON")"
    # Toutes les heures (root) : range les dépôts terminés hors de portée de
    # l'envoyeur, puis supprime les archives de plus de N jours.
    cat > "$PURGE_CRON" <<CRON
#!/bin/bash
# backup_remote.sh — range les archives reçues et purge celles de plus de ${days} jours
set -u
for up in ${RECV_HOME}/*/; do
    name=\$(basename "\$up")
    dest="${ARCH_HOME}/\$name"
    [[ -d "\$dest" ]] || continue
    rm -f "\$up/.test_connexion"
    # Fichiers inchangés depuis 30 min = envoi terminé
    find "\$up" -maxdepth 1 -type f -name 'server_backup_*' -mmin +30 -print0 |
    while IFS= read -r -d '' f; do
        t="\$dest/\$(basename "\$f")"
        [[ -e "\$t" ]] && t="\$t.doublon-\$(date +%s)"   # jamais d'écrasement
        mv "\$f" "\$t" && chown root:root "\$t" && chmod 600 "\$t"
    done
done
find ${ARCH_HOME} -mindepth 2 -maxdepth 2 -type f -name 'server_backup_*' -mtime +${days} -delete
CRON
    chmod 755 "$PURGE_CRON"
    rm -f /etc/cron.daily/backup-remote-purge
    log OK "Archives rangées dans ${ARCH_HOME}/${name} (root), conservées ${days} jours (${PURGE_CRON})."

    # Avertissements SSH éventuels
    if sshd -T 2>/dev/null | grep -qiE '^(allowusers|allowgroups) '; then
        log WARN "sshd a une liste AllowUsers/AllowGroups : ajoutez-y « ${RECV_USER} »."
    fi
    echo -e "\n  Retournez sur l'envoyeur et validez le test de connexion."
}

cmd_revoquer() {
    local name="${1:-}"; name="${name,,}"
    valid_name "$name" || { log ERROR "Usage : $0 revoquer <nom>"; return 1; }
    local ak="${RECV_HOME}/.ssh/authorized_keys"
    if [[ -f "$ak" ]] && grep -q " ${KEY_TAG}${name}\$" "$ak"; then
        local tmp; tmp=$(mktemp)
        grep -v " ${KEY_TAG}${name}\$" "$ak" > "$tmp" || true
        cat "$tmp" > "$ak"; rm -f "$tmp"
        log OK "Accès de « ${name} » retiré (archives déjà reçues conservées dans ${RECV_HOME}/${name})."
    else
        log WARN "Aucune clé autorisée pour « ${name} »."
    fi
}

# ===========================================================================
# ÉTAT
# ===========================================================================
cmd_etat() {
    [[ -f "$CONFIG_FILE" ]] && load_conf
    log STEP "Envoi depuis ce serveur"
    if [[ -n "${BACKUP_REMOTE_HOST:-}" ]]; then
        echo -e "  Vers      : ${BOLD}${RECV_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_PORT:-22}${RESET} (dossier ${BACKUP_REMOTE_NAME:-?})"
        if [[ -f "$CRON_FILE" ]]; then
            echo -e "  Planifié  : $(grep -v '^#' "$CRON_FILE" | awk '{print $2"h"$1}')"
        else
            echo -e "  Planifié  : ${YELLOW}non${RESET}"
        fi
        if [[ -f "$SEND_LOG" ]]; then
            local last; last=$(grep -E 'Envoyé :|ERROR' "$SEND_LOG" | tail -n1 || true)
            echo -e "  Dernier   : ${last:-(aucun envoi)}"
        fi
        echo -e "  Local     : $(local_backup_dir)"
    else
        echo "  (non configuré — « $0 configurer »)"
    fi

    log STEP "Archives reçues sur ce serveur (${ARCH_HOME})"
    if [[ -d "$RECV_HOME" ]]; then
        local d n newest age count found=0
        for d in "$RECV_HOME"/*/; do
            [[ -d "$d" ]] || continue
            found=1; n=$(basename "$d")
            newest=$(find "$d" "${ARCH_HOME}/${n}" -maxdepth 1 -name 'server_backup_*' ! -name '*.sha256' \
                        -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n1 || true)
            if [[ -z "$newest" ]]; then
                printf "  %-32s ${YELLOW}aucune archive${RESET}\n" "$n"; continue
            fi
            count=$(find "$d" "${ARCH_HOME}/${n}" -maxdepth 1 -name 'server_backup_*' ! -name '*.sha256' 2>/dev/null | wc -l)
            age=$(( ( $(date +%s) - ${newest%%.*} ) / 3600 ))
            printf "  %-32s %3s archive(s), %6s, dernière il y a %s h" "$n" "$count" \
                "$(du -sch "$d" "${ARCH_HOME}/${n}" 2>/dev/null | tail -n1 | cut -f1)" "$age"
            (( age > 36 )) && printf " ${RED}⚠ en retard${RESET}"
            echo
        done
        (( found )) || echo "  (aucun envoyeur autorisé)"
    else
        echo "  (aucune — ce serveur ne reçoit pas de sauvegardes)"
    fi
    echo
}

# ===========================================================================
# Menu / point d'entrée
# ===========================================================================
menu() {
    while true; do
        echo -e "\n${CYAN}${BOLD}  🔁 Sauvegarde croisée${RESET}\n"
        echo -e "  ${CYAN}[1]${RESET} Configurer l'envoi depuis CE serveur"
        echo -e "  ${CYAN}[2]${RESET} Autoriser un autre serveur à déposer ici"
        echo -e "  ${CYAN}[3]${RESET} Sauvegarder + envoyer maintenant"
        echo -e "  ${CYAN}[4]${RESET} État"
        echo -e "  ${CYAN}[5]${RESET} Retirer l'accès d'un serveur"
        echo -e "  ${CYAN}[0]${RESET} Retour\n"
        local c n k
        read -rp "$(echo -e "  ${BOLD}Votre choix : ${RESET}")" c
        case "$c" in
            1) cmd_configurer || true ;;
            2) read -rp "  Nom (affiché par « configurer » sur l'autre serveur) : " n
               read -rp "  Clé publique (ssh-ed25519 AAAA…) : " k
               cmd_autoriser "$n" "$k" || true ;;
            3) ( cmd_envoyer ) || true ;;
            4) cmd_etat ;;
            5) read -rp "  Nom : " n; cmd_revoquer "$n" || true ;;
            0|q) return 0 ;;
            *) log WARN "Choix invalide : ${c}" ;;
        esac
    done
}

cmd="${1:-menu}"; [[ $# -gt 0 ]] && shift
case "$cmd" in
    menu)                 menu ;;
    configurer|setup)     cmd_configurer ;;
    envoyer|send)         cmd_envoyer ;;
    autoriser|allow)
        n="${1:-}"; k="${2:-}"; j=30
        [[ "${3:-}" == "--jours" ]] && j="${4:-}"
        cmd_autoriser "$n" "$k" "$j" ;;
    revoquer|revoke)      cmd_revoquer "${1:-}" ;;
    etat|status)          cmd_etat ;;
    -h|--help|help)       sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) log ERROR "Commande inconnue : ${cmd} (voir : $0 help)"; exit 1 ;;
esac
