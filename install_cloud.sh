#!/bin/bash
# =============================================================================
#  install_cloud.sh — Serveur cloud perso : Nextcloud + Immich + surveillance RAID
#  Auteur  : Laurent Lebarbier
#  Version : 1.0
# =============================================================================
#
#  Prévu pour le serveur dédié « cloud » (ex : Kimsufi KS-5, 2×2 To en RAID 1
#  logiciel), installé avec le rôle « cloud » d'install.sh : pas de mail, pas
#  de FTP, pas de WordPress. À lancer APRÈS install_lamp.sh.
#
#  Étapes (toutes relançables sans risque, elles ne refont que le nécessaire) :
#    alertes   : envoi des mails d'alerte via le serveur mail du VPS (msmtp,
#                SMTP authentifié port 587) — utilisé par mdadm, smartd, cron
#                et Nextcloud
#    raid      : surveillance du RAID logiciel (mdadm) + santé des disques
#                (smartd, tests SMART courts/longs) avec alertes par mail
#    nextcloud : Nextcloud sur https://cloud.<domaine> (Apache + mod_php,
#                MariaDB, Redis, cron système), données dans /srv/nextcloud
#    immich    : Immich (Docker) sur https://photos.<domaine>, derrière Apache,
#                photos dans /srv/immich — port 2283 lié à 127.0.0.1 seulement
#    fail2ban  : bannissement SSH + échecs de connexion Nextcloud
#
#  Usage :
#      sudo bash install_cloud.sh              # menu
#      sudo bash install_cloud.sh tout         # alertes + raid + nextcloud + immich + fail2ban
#      sudo bash install_cloud.sh nextcloud    # une seule étape
#      sudo bash install_cloud.sh etat         # RAID, disques, services, espace
#      sudo bash install_cloud.sh test-alertes # mail de test (mdadm)
#      sudo bash install_cloud.sh mise-a-jour  # met à jour Nextcloud et Immich
#
#  Les DNS cloud./photos. sont créés automatiquement chez OVH si les clés API
#  sont dans server.conf (proposé ici : copiez les 3 lignes OVH_* du VPS).
#  Ne lancez JAMAIS install_dns_ovh.sh sur ce serveur : il remet toute la zone
#  à zéro (il le refuse d'ailleurs en rôle cloud).
# =============================================================================

set -euo pipefail

# Journal d'installation : tout l'affichage est aussi écrit dans
# /var/log/install_server/ (voir lib_log.sh)
# shellcheck source=lib_log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_log.sh" 2>/dev/null && start_install_log "$@"
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
    local ts; ts=$(date '+%H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO ]${RESET} $ts — $*" ;;
        WARN)  echo -e "${YELLOW}[WARN ]${RESET} $ts — $*" ;;
        ERROR) echo -e "${RED}[ERROR]${RESET} $ts — $*" ;;
        STEP)  echo -e "\n${MAGENTA}${BOLD}▶ $*${RESET}" ;;
        OK)    echo -e "${GREEN}${BOLD}  ✔  $*${RESET}" ;;
    esac
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') — install_cloud — $*" >> /var/log/install_server.log 2>/dev/null || true
}

confirm() {
    local answer
    read -rp "$(echo -e "${YELLOW}  ❓ ${1:-Continuer ?} [O/n] : ${RESET}")" answer
    [[ "${answer,,}" =~ ^(o|oui|y|yes|)$ ]]
}

# ---------------------------------------------------------------------------
# Vérifications & configuration
# ---------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_FILE="${SCRIPT_DIR}/server.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log ERROR "server.conf introuvable. Lancez d'abord install.sh."; exit 1
fi
# shellcheck source=./server.conf
source "$CONFIG_FILE"
: "${DOMAIN:?DOMAIN manquant dans server.conf}"
: "${SERVER_IP:?SERVER_IP manquant dans server.conf}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"

# Emplacements (modifiables dans server.conf avant la première installation)
NC_SUB="${NC_SUB:-cloud}"
IMMICH_SUB="${IMMICH_SUB:-photos}"
NC_DATA_DIR="${NC_DATA_DIR:-/srv/nextcloud/data}"
IMMICH_DIR="${IMMICH_DIR:-/opt/immich}"
IMMICH_DATA="${IMMICH_DATA:-/srv/immich}"
readonly IMMICH_PORT=2283
readonly VHOST_MARKER="# --- install_cloud.sh"

nc_fqdn()  { echo "${NC_SUB}.${DOMAIN}"; }
nc_dir()   { echo "/var/www/$(nc_fqdn)/public_html"; }
imm_fqdn() { echo "${IMMICH_SUB}.${DOMAIN}"; }

if [[ "${SERVER_ROLE:-web}" == "web" ]]; then
    log WARN "server.conf indique le rôle « ${SERVER_ROLE:-web} » (serveur web + mail)."
    log WARN "Ce script est prévu pour le serveur cloud (rôle « cloud » choisi dans install.sh)."
    confirm "Continuer quand même sur ce serveur ?" || exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Mot de passe aléatoire alphanumérique (sans caractère gênant pour .env/SQL)
gen_pass() {
    local p; p=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
    echo "${p:0:${1:-24}}"
}

# set_conf CLÉ VALEUR — ajoute ou remplace une ligne de server.conf
set_conf() {
    local key="$1" val="$2" line
    if [[ "$val" =~ ^[A-Za-z0-9@._:/+=,-]*$ ]]; then
        line="${key}=\"${val}\""
    else
        line="${key}=$(printf '%q' "$val")"
    fi
    if grep -q "^${key}=" "$CONFIG_FILE"; then
        local tmp; tmp=$(mktemp)
        awk -v k="$key" -v l="$line" 'index($0, k"=")==1 {print l; next} {print}' "$CONFIG_FILE" > "$tmp"
        cat "$tmp" > "$CONFIG_FILE"; rm -f "$tmp"
    else
        echo "$line" >> "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE"
    printf -v "$key" '%s' "$val"
}

apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null; }

need_lamp() {
    if ! command -v apache2ctl &>/dev/null || ! command -v php &>/dev/null \
       || ! mysql -e "SELECT 1" &>/dev/null; then
        log ERROR "Apache, PHP et MariaDB sont nécessaires : lancez d'abord install_lamp.sh (menu [2])."
        return 1
    fi
}

php_ver() { php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'; }

# IPv4 publique vue par un résolveur public
resolve_ip() {
    if command -v dig &>/dev/null; then
        dig +short A "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true
    else
        getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true
    fi
}

# wait_dns FQDN SECONDES — attend que le nom pointe sur ce serveur
wait_dns() {
    local fqdn="$1" timeout="$2" waited=0 ip
    while true; do
        ip=$(resolve_ip "$fqdn")
        [[ "$ip" == "$SERVER_IP" ]] && return 0
        (( waited >= timeout )) && break
        (( waited == 0 )) && log INFO "Attente du DNS de ${fqdn} → ${SERVER_IP} (max ${timeout}s)…"
        sleep 15; waited=$((waited + 15))
    done
    log WARN "${fqdn} → ${ip:-(introuvable)} au lieu de ${SERVER_IP}."
    return 1
}

# Propose d'enregistrer les clés API OVH (copiées du server.conf du VPS) pour
# que manage_subdomains.sh crée les enregistrements DNS tout seul.
ask_ovh_keys() {
    [[ -n "${OVH_APP_KEY:-}" && -n "${OVH_APP_SECRET:-}" && -n "${OVH_CONSUMER_KEY:-}" ]] && return 0
    [[ "${OVH_ASKED:-0}" == 1 ]] && return 0
    OVH_ASKED=1
    echo -e "\n${BOLD}  🌍 DNS automatique chez OVH (facultatif)${RESET}"
    echo -e "     Copiez les 3 lignes OVH_APP_KEY / OVH_APP_SECRET / OVH_CONSUMER_KEY"
    echo -e "     du server.conf du VPS (même domaine, mêmes clés)."
    echo -e "     Laissez vide pour créer ${BOLD}$(nc_fqdn)${RESET} et ${BOLD}$(imm_fqdn)${RESET} à la main"
    echo -e "     (enregistrements A → ${SERVER_IP})."
    local k s c
    read -rp "$(echo -e "  ${CYAN}OVH_APP_KEY      : ${RESET}")" k
    [[ -z "$k" ]] && { log INFO "DNS à créer à la main."; return 0; }
    read -rp "$(echo -e "  ${CYAN}OVH_APP_SECRET   : ${RESET}")" s
    read -rp "$(echo -e "  ${CYAN}OVH_CONSUMER_KEY : ${RESET}")" c
    k="${k//\"/}"; s="${s//\"/}"; c="${c//\"/}"
    k="${k#OVH_APP_KEY=}"; s="${s#OVH_APP_SECRET=}"; c="${c#OVH_CONSUMER_KEY=}"
    if [[ -z "$s" || -z "$c" ]]; then log WARN "Clés incomplètes — ignorées."; return 0; fi
    set_conf OVH_APP_KEY "$k"
    set_conf OVH_APP_SECRET "$s"
    set_conf OVH_CONSUMER_KEY "$c"
    log OK "Clés API OVH enregistrées dans server.conf."
}

# vhost_patch FQDN FICHIER_DE_LIGNES — insère un bloc avant </VirtualHost>
# dans le vhost HTTP et dans le vhost HTTPS (s'il existe), une seule fois.
vhost_patch() {
    local fqdn="$1" block="$2" f tmp
    for f in "/etc/apache2/sites-available/${fqdn}.conf" "/etc/apache2/sites-available/${fqdn}-le-ssl.conf"; do
        [[ -f "$f" ]] || continue
        grep -qF "$VHOST_MARKER" "$f" && continue
        tmp=$(mktemp)
        awk -v blk="$block" '
            { lines[NR]=$0 }
            /<\/VirtualHost>/ { last=NR }
            END { for (i=1; i<=NR; i++) {
                    if (i==last) { while ((getline l < blk) > 0) print l; close(blk) }
                    print lines[i] } }' "$f" > "$tmp"
        cat "$tmp" > "$f"; rm -f "$tmp"
    done
}

apache_reload() {
    if apache2ctl configtest &>/dev/null; then
        systemctl reload apache2
    else
        apache2ctl configtest || true
        log ERROR "Configuration Apache invalide — rechargement annulé."
        return 1
    fi
}

# ensure_subdomain SUB [PORT_PROXY] — VirtualHost HTTP via manage_subdomains.sh
ensure_subdomain() {
    local sub="$1" port="${2:-}" fqdn="${1}.${DOMAIN}"
    if [[ -f "/etc/apache2/sites-available/${fqdn}.conf" ]]; then
        log INFO "VirtualHost ${fqdn} déjà présent."
        # Le DNS a pu échouer au premier passage : on le refait s'il ne
        # pointe pas encore ici et que les clés OVH sont connues
        if [[ "$(resolve_ip "$fqdn")" != "$SERVER_IP" && -n "${OVH_CONSUMER_KEY:-}" ]]; then
            bash "${SCRIPT_DIR}/manage_subdomains.sh" dns "$sub" \
                || log WARN "DNS de ${fqdn} non créé — à faire à la main : A → ${SERVER_IP}"
        fi
        return 0
    fi
    local args=(add "$sub" --no-ssl -y)
    [[ -n "$port" ]] && args+=(--proxy "$port")
    bash "${SCRIPT_DIR}/manage_subdomains.sh" "${args[@]}"
}

# ensure_cert FQDN — certificat Let's Encrypt (attend le DNS jusqu'à 5 min)
ensure_cert() {
    local fqdn="$1" sub="${1%."${DOMAIN}"}"
    if [[ -f "/etc/letsencrypt/live/${fqdn}/cert.pem" ]]; then
        log INFO "Certificat ${fqdn} déjà présent."
        return 0
    fi
    if ! wait_dns "$fqdn" 300; then
        log WARN "Certificat non demandé : créez l'enregistrement A ${sub} → ${SERVER_IP}, puis :"
        echo -e "     ${BOLD}sudo bash ${SCRIPT_DIR}/manage_subdomains.sh ssl ${sub}${RESET}"
        echo -e "     ${BOLD}sudo bash $0 $( [[ "$sub" == "$NC_SUB" ]] && echo nextcloud || echo immich)${RESET}   (finalise la config HTTPS)"
        return 1
    fi
    bash "${SCRIPT_DIR}/manage_subdomains.sh" ssl "$sub"
}

# ===========================================================================
# ÉTAPE : ALERTES MAIL (msmtp → serveur mail du VPS)
# ===========================================================================
step_alertes() {
    log STEP "Alertes par mail"

    if dpkg -s postfix &>/dev/null; then
        log INFO "Postfix est installé sur ce serveur : il enverra lui-même les alertes."
        log INFO "(msmtp n'est utile que sur un serveur sans serveur mail.)"
        return 0
    fi

    echo -e "\n${BOLD}  📧 Relais SMTP pour les alertes (RAID, disques, Nextcloud)${RESET}"
    echo -e "     Ce serveur n'a pas de serveur mail : il passe par celui du VPS, avec un"
    echo -e "     compte dédié. Créez-le d'abord ${BOLD}sur le VPS${RESET}, par exemple :"
    echo -e "       ${CYAN}sudo bash manage_mail.sh add alertes@${DOMAIN}${RESET}"
    echo -e "     Laissez le compte vide pour passer cette étape."

    local host port user pass
    read -rp "$(echo -e "  ${CYAN}Serveur SMTP [${RELAY_HOST:-mail.${DOMAIN}}] : ${RESET}")" host
    host="${host:-${RELAY_HOST:-mail.${DOMAIN}}}"
    read -rp "$(echo -e "  ${CYAN}Port (STARTTLS) [${RELAY_PORT:-587}] : ${RESET}")" port
    port="${port:-${RELAY_PORT:-587}}"
    read -rp "$(echo -e "  ${CYAN}Compte expéditeur [${RELAY_USER:-alertes@${DOMAIN}}] : ${RESET}")" user
    user="${user:-${RELAY_USER:-alertes@${DOMAIN}}}"
    if [[ -n "${RELAY_PASS:-}" && "$user" == "${RELAY_USER:-}" ]]; then
        read -rsp "$(echo -e "  ${CYAN}Mot de passe [inchangé] : ${RESET}")" pass; echo
        pass="${pass:-$RELAY_PASS}"
    else
        read -rsp "$(echo -e "  ${CYAN}Mot de passe de ${user} : ${RESET}")" pass; echo
    fi
    if [[ -z "$pass" ]]; then
        log WARN "Pas de mot de passe : alertes mail non configurées (journal système seulement)."
        return 0
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || { log ERROR "Port invalide : ${port}"; return 1; }

    set_conf RELAY_HOST "$host"
    set_conf RELAY_PORT "$port"
    set_conf RELAY_USER "$user"
    set_conf RELAY_PASS "$pass"

    log INFO "Installation de msmtp (remplace sendmail) et mailx…"
    echo "msmtp msmtp/apparmor boolean false" | debconf-set-selections
    apt_install msmtp msmtp-mta bsd-mailx

    # msmtp : valeurs entre guillemets, \ et " échappés
    local qpass="${pass//\\/\\\\}"; qpass="${qpass//\"/\\\"}"
    umask 077
    cat > /etc/msmtprc <<CONF
# Généré par install_cloud.sh — relais SMTP authentifié vers le serveur mail du VPS
defaults
auth            on
tls             on
tls_starttls    on
tls_trust_file  /etc/ssl/certs/ca-certificates.crt
syslog          LOG_MAIL
aliases         /etc/aliases
# L'expéditeur est toujours le compte authentifié (sinon refusé par Postfix)
allow_from_override off
set_from_header on

account relais
host     ${host}
port     ${port}
from     ${user}
user     ${user}
password "${qpass}"

account default : relais
CONF
    umask 022
    chmod 600 /etc/msmtprc
    chown root:root /etc/msmtprc

    # Les mails pour root (cron, mdadm…) partent vers l'adresse admin
    touch /etc/aliases
    local a
    for a in root default; do
        if grep -q "^${a}:" /etc/aliases; then
            sed -i "s|^${a}:.*|${a}: ${ADMIN_EMAIL}|" /etc/aliases
        else
            echo "${a}: ${ADMIN_EMAIL}" >> /etc/aliases
        fi
    done
    log OK "Relais configuré : ${user} via ${host}:${port} → alertes vers ${ADMIN_EMAIL}"

    if confirm "Envoyer un mail de test à ${ADMIN_EMAIL} ?"; then
        if printf 'To: %s\nSubject: [%s] Test des alertes\n\nLes alertes du serveur %s (%s) fonctionnent.\n' \
                "$ADMIN_EMAIL" "$(hostname)" "$(hostname)" "$SERVER_IP" | sendmail -t; then
            log OK "Mail de test envoyé — vérifiez votre boîte (et les spams)."
        else
            log WARN "Échec de l'envoi : voir « journalctl -t msmtp -n 20 »."
            log WARN "Vérifiez le compte sur le VPS et que le port ${port} est ouvert."
        fi
    fi
}

# ===========================================================================
# ÉTAPE : RAID LOGICIEL + SANTÉ DES DISQUES
# ===========================================================================
step_raid() {
    log STEP "Surveillance du RAID et des disques"
    apt_install mdadm smartmontools

    command -v sendmail &>/dev/null \
        || log WARN "Aucun « sendmail » sur ce serveur : les alertes iront seulement dans le journal (étape « alertes »)."

    # --- mdadm ---
    if grep -q '^md' /proc/mdstat 2>/dev/null; then
        local conf=/etc/mdadm/mdadm.conf
        mkdir -p /etc/mdadm; touch "$conf"
        # Les tableaux doivent être déclarés pour être surveillés
        if ! grep -q '^ARRAY' "$conf"; then
            mdadm --detail --scan >> "$conf"
            log OK "Tableaux RAID ajoutés à ${conf}."
            update-initramfs -u >/dev/null 2>&1 || true
        fi
        if grep -q '^MAILADDR' "$conf"; then
            sed -i "s|^MAILADDR.*|MAILADDR ${ADMIN_EMAIL}|" "$conf"
        else
            echo "MAILADDR ${ADMIN_EMAIL}" >> "$conf"
        fi
        if [[ -n "${RELAY_USER:-}" ]]; then
            if grep -q '^MAILFROM' "$conf"; then
                sed -i "s|^MAILFROM.*|MAILFROM ${RELAY_USER}|" "$conf"
            else
                echo "MAILFROM ${RELAY_USER}" >> "$conf"
            fi
        fi
        systemctl restart mdmonitor 2>/dev/null || systemctl restart mdadm 2>/dev/null || true
        # Vérification mensuelle de cohérence (lecture complète des 2 disques)
        systemctl enable --now mdcheck_start.timer mdcheck_continue.timer &>/dev/null || true
        log OK "mdadm surveille : $(grep -oE '^md[0-9]+ : [a-z]+ raid[0-9]+' /proc/mdstat | paste -sd',' | sed 's/ : active / /g')"
        if grep -qE '\[[U]*_[U_]*\]' /proc/mdstat; then
            log WARN "Un tableau RAID est DÉGRADÉ en ce moment :"
            grep -B1 -E '\[[U]*_[U_]*\]' /proc/mdstat
        fi
    else
        log WARN "Aucun RAID logiciel détecté (/proc/mdstat) — surveillance mdadm ignorée."
        log WARN "Sur un Kimsufi, choisissez « RAID 1 » au moment de l'installation de l'OS."
    fi

    # --- smartd ---
    local sconf=/etc/smartd.conf
    if [[ -f "$sconf" ]] && ! grep -qF "install_cloud.sh" "$sconf"; then
        cp "$sconf" "${sconf}.bak"
        sed -i -E 's/^(DEVICESCAN.*)/# \1   # désactivé par install_cloud.sh/' "$sconf"
    fi
    if ! grep -qF "install_cloud.sh" "$sconf" 2>/dev/null || ! grep -q '^DEVICESCAN' "$sconf"; then
        cat >> "$sconf" <<CONF

# install_cloud.sh — tous les disques : santé, attributs, test court chaque nuit
# à 2 h, test long le samedi à 3 h, alerte si > 45 °C (critique 55 °C)
DEVICESCAN -d removable -n standby -a -o on -S on -s (S/../.././02|L/../../6/03) -W 4,45,55 -m ${ADMIN_EMAIL}
CONF
    else
        sed -i -E "s|^(DEVICESCAN .* -m )[^ ]+|\1${ADMIN_EMAIL}|" "$sconf"
    fi
    systemctl enable --now smartmontools &>/dev/null || systemctl enable --now smartd &>/dev/null || true
    systemctl restart smartmontools &>/dev/null || systemctl restart smartd &>/dev/null || true

    local d health
    for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
        health=$(smartctl -H "/dev/$d" 2>/dev/null | grep -iE 'overall-health|SMART Health Status' | awk -F: '{print $2}' | xargs || true)
        log INFO "/dev/${d} : ${health:-santé SMART non lisible}"
    done
    log OK "smartd actif (alertes vers ${ADMIN_EMAIL})."
    echo -e "  Tester l'envoi d'une alerte : ${BOLD}sudo bash $0 test-alertes${RESET}"
}

cmd_test_alertes() {
    if grep -q '^md' /proc/mdstat 2>/dev/null; then
        mdadm --monitor --scan --test --oneshot
        log OK "Alerte de test mdadm envoyée à ${ADMIN_EMAIL} (une par tableau RAID)."
    elif command -v sendmail &>/dev/null; then
        printf 'To: %s\nSubject: [%s] Test des alertes\n\nTest.\n' "$ADMIN_EMAIL" "$(hostname)" | sendmail -t
        log OK "Mail de test envoyé à ${ADMIN_EMAIL}."
    else
        log ERROR "Rien pour envoyer un mail : lancez l'étape « alertes »."
    fi
}

# ===========================================================================
# ÉTAPE : NEXTCLOUD
# ===========================================================================
occ() { runuser -u www-data -- php --define apc.enable_cli=1 "$(nc_dir)/occ" "$@"; }

nc_installed() {
    [[ -f "$(nc_dir)/config/config.php" ]] && grep -q "'installed' => true" "$(nc_dir)/config/config.php"
}

step_nextcloud() {
    log STEP "Nextcloud — https://$(nc_fqdn)"
    need_lamp || return 1
    local NC_DIR; NC_DIR=$(nc_dir)
    local PHPV; PHPV=$(php_ver)

    # --- 1. Paquets ---
    log INFO "Paquets PHP et Redis…"
    apt_install bzip2 redis-server \
        "php${PHPV}-gmp" "php${PHPV}-bz2" "php${PHPV}-redis" "php${PHPV}-apcu" \
        "php${PHPV}-imagick" "php${PHPV}-intl" "php${PHPV}-bcmath" "php${PHPV}-zip" \
        "php${PHPV}-xml" "php${PHPV}-mbstring" "php${PHPV}-curl" "php${PHPV}-gd" "php${PHPV}-mysql"
    apt_install libmagickcore-6.q16-7-extra 2>/dev/null || apt_install libmagickcore-6.q16-6-extra 2>/dev/null || true
    a2enmod -q rewrite headers env dir mime >/dev/null

    # --- 2. PHP : réglages globaux (OPcache/APCu) ; les limites d'upload sont
    #        posées dans le VirtualHost (n'affectent pas les autres sites) ---
    cat > "/etc/php/${PHPV}/apache2/conf.d/90-nextcloud.ini" <<'INI'
; install_cloud.sh — recommandations Nextcloud
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.jit=1255
opcache.jit_buffer_size=128M
apc.shm_size=128M
INI
    cat > "/etc/php/${PHPV}/cli/conf.d/90-nextcloud.ini" <<'INI'
; install_cloud.sh — occ et cron.php ont besoin d'APCu en ligne de commande
apc.enable_cli=1
memory_limit=1G
INI

    # --- 3. Redis via socket Unix (verrous de fichiers + cache partagé) ---
    local rconf=/etc/redis/redis.conf
    if [[ -f "$rconf" ]]; then
        sed -i -E 's|^#? *unixsocket .*|unixsocket /run/redis/redis-server.sock|' "$rconf"
        sed -i -E 's|^#? *unixsocketperm .*|unixsocketperm 770|' "$rconf"
        grep -q '^unixsocket ' "$rconf"     || echo "unixsocket /run/redis/redis-server.sock" >> "$rconf"
        grep -q '^unixsocketperm ' "$rconf" || echo "unixsocketperm 770" >> "$rconf"
        usermod -aG redis www-data
        systemctl enable --now redis-server >/dev/null 2>&1 || true
        systemctl restart redis-server
        log OK "Redis : socket /run/redis/redis-server.sock (www-data dans le groupe redis)."
    fi

    # --- 4. Sous-domaine (VirtualHost HTTP, DNS OVH si clés présentes) ---
    ask_ovh_keys
    ensure_subdomain "$NC_SUB"

    # --- 5. Téléchargement de Nextcloud (vérifié par SHA-256) ---
    if [[ ! -f "${NC_DIR}/occ" ]]; then
        log INFO "Téléchargement de la dernière version de Nextcloud…"
        local tmp; tmp=$(mktemp -d)
        local url="https://download.nextcloud.com/server/releases/latest.tar.bz2"
        if ! curl -fsSL -o "${tmp}/latest.tar.bz2" "$url" \
           || ! curl -fsSL -o "${tmp}/latest.tar.bz2.sha256" "${url}.sha256"; then
            rm -rf "$tmp"; log ERROR "Téléchargement impossible (${url})."; return 1
        fi
        # On compare l'empreinte seule : le nom de fichier écrit dans le .sha256
        # de Nextcloud ne correspond pas toujours à « latest.tar.bz2 » (il a
        # été vu à « latest.metadata »), ce qui faisait échouer sha256sum -c.
        local want got
        want=$(grep -oE '\b[0-9a-f]{64}\b' "${tmp}/latest.tar.bz2.sha256" | head -n1 || true)
        got=$(sha256sum "${tmp}/latest.tar.bz2" | cut -d' ' -f1)
        if [[ -z "$want" || "$want" != "$got" ]]; then
            rm -rf "$tmp"
            log ERROR "Empreinte SHA-256 incorrecte — archive rejetée (attendue : ${want:-illisible}, obtenue : ${got})."
            return 1
        fi
        log OK "Archive vérifiée (SHA-256)."
        # Page d'attente posée par manage_subdomains.sh
        rm -f "${NC_DIR}/index.html"
        mkdir -p "$NC_DIR"
        tar -xjf "${tmp}/latest.tar.bz2" -C "$NC_DIR" --strip-components=1
        rm -rf "$tmp"
        log OK "Nextcloud extrait dans ${NC_DIR}."
    fi
    chown -R www-data:www-data "/var/www/$(nc_fqdn)"
    mkdir -p "$NC_DATA_DIR"
    chown -R www-data:www-data "$NC_DATA_DIR"   # ce dossier seulement (jamais /srv entier)
    chmod 750 "$NC_DATA_DIR"

    # --- 6. Base de données (mot de passe gardé dans server.conf : une
    #        relance resynchronise le compte au lieu d'en créer un autre) ---
    [[ -n "${NC_DB_PASS:-}" ]] || set_conf NC_DB_PASS "$(gen_pass)"
    [[ -n "${NC_DB_NAME:-}" ]] || set_conf NC_DB_NAME "nextcloud"
    [[ -n "${NC_DB_USER:-}" ]] || set_conf NC_DB_USER "nextcloud"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${NC_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';"
    mysql -e "ALTER USER '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${NC_DB_NAME}\`.* TO '${NC_DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
    log OK "Base ${NC_DB_NAME} / compte ${NC_DB_USER} prêts."

    # --- 7. Installation ---
    if nc_installed; then
        log INFO "Nextcloud déjà installé — mise à jour de la configuration seulement."
    else
        [[ -n "${NC_ADMIN_USER:-}" ]] || {
            local u
            read -rp "$(echo -e "  ${CYAN}Identifiant administrateur Nextcloud [admin] : ${RESET}")" u
            set_conf NC_ADMIN_USER "${u:-admin}"
        }
        [[ -n "${NC_ADMIN_PASS:-}" ]] || set_conf NC_ADMIN_PASS "$(gen_pass 20)"
        log INFO "Installation de Nextcloud (1 à 2 minutes)…"
        occ maintenance:install \
            --database=mysql --database-host=localhost \
            --database-name="$NC_DB_NAME" --database-user="$NC_DB_USER" --database-pass="$NC_DB_PASS" \
            --admin-user="$NC_ADMIN_USER" --admin-pass="$NC_ADMIN_PASS" \
            --data-dir="$NC_DATA_DIR"
        log OK "Nextcloud installé."
    fi
    set_conf NC_SUB "$NC_SUB"
    set_conf NC_DATA_DIR "$NC_DATA_DIR"

    # --- 8. Configuration ---
    log INFO "Configuration (domaine, cache, langue, maintenance)…"
    occ config:system:set trusted_domains 0 --value="$(nc_fqdn)" >/dev/null
    occ config:system:set overwrite.cli.url --value="https://$(nc_fqdn)" >/dev/null
    occ config:system:set overwriteprotocol --value="https" >/dev/null
    occ config:system:set default_phone_region --value="FR" >/dev/null
    occ config:system:set default_language --value="fr" >/dev/null
    occ config:system:set default_locale --value="fr_FR" >/dev/null
    occ config:system:set default_timezone --value="Europe/Paris" >/dev/null
    occ config:system:set maintenance_window_start --type=integer --value=1 >/dev/null
    occ config:system:set memcache.local --value='\OC\Memcache\APCu' >/dev/null
    occ config:system:set memcache.distributed --value='\OC\Memcache\Redis' >/dev/null
    occ config:system:set memcache.locking --value='\OC\Memcache\Redis' >/dev/null
    occ config:system:set redis host --value="/run/redis/redis-server.sock" >/dev/null
    occ config:system:set redis port --type=integer --value=0 >/dev/null
    occ config:system:set log_type --value="file" >/dev/null
    occ config:system:set loglevel --type=integer --value=2 >/dev/null
    occ background:cron >/dev/null

    # Mails sortants de Nextcloud (partages, mot de passe oublié) via le relais
    if [[ -n "${RELAY_USER:-}" && -n "${RELAY_PASS:-}" ]]; then
        occ config:system:set mail_smtpmode --value="smtp" >/dev/null
        occ config:system:set mail_smtphost --value="${RELAY_HOST}" >/dev/null
        occ config:system:set mail_smtpport --type=integer --value="${RELAY_PORT}" >/dev/null
        occ config:system:set mail_smtpsecure --value="" >/dev/null
        occ config:system:set mail_smtpauth --type=boolean --value=true >/dev/null
        occ config:system:set mail_smtpname --value="${RELAY_USER}" >/dev/null
        occ config:system:set mail_smtppassword --value="${RELAY_PASS}" >/dev/null
        occ config:system:set mail_from_address --value="${RELAY_USER%@*}" >/dev/null
        occ config:system:set mail_domain --value="${RELAY_USER#*@}" >/dev/null
        log OK "Mails Nextcloud envoyés via ${RELAY_USER}."
    elif dpkg -s postfix &>/dev/null; then
        # Rôle « complet » : Postfix tourne sur cette machine, envoi en local
        occ config:system:set mail_smtpmode --value="sendmail" >/dev/null
        occ config:system:set mail_sendmailmode --value="smtp" >/dev/null
        occ config:system:set mail_from_address --value="nextcloud" >/dev/null
        occ config:system:set mail_domain --value="${DOMAIN}" >/dev/null
        log OK "Mails Nextcloud envoyés par le Postfix local (nextcloud@${DOMAIN})."
    else
        log INFO "Mails Nextcloud non configurés (étape « alertes » non faite)."
    fi
    occ user:setting "${NC_ADMIN_USER:-admin}" settings email "$ADMIN_EMAIL" >/dev/null 2>&1 || true

    # Tâches de fond toutes les 5 minutes
    cat > /etc/cron.d/nextcloud <<CRON
# install_cloud.sh — tâches de fond Nextcloud
*/5 * * * * www-data php --define apc.enable_cli=1 -f ${NC_DIR}/cron.php
CRON
    chmod 644 /etc/cron.d/nextcloud

    # --- 9. VirtualHost : réglages Nextcloud ---
    local blk; blk=$(mktemp)
    cat > "$blk" <<VHOST

    ${VHOST_MARKER} : Nextcloud ---
    <Directory ${NC_DIR}>
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>
    # Pas de limite de taille côté Apache (les clients envoient par morceaux)
    LimitRequestBody 0
    <IfModule php_module>
        php_admin_value upload_max_filesize 16G
        php_admin_value post_max_size 16G
        php_admin_value memory_limit 1G
        php_admin_value max_execution_time 3600
        php_admin_value max_input_time 3600
        php_admin_value output_buffering 0
    </IfModule>
    Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
VHOST
    vhost_patch "$(nc_fqdn)" "$blk"
    apache_reload
    systemctl restart apache2   # nouveaux .ini PHP + groupe redis pour www-data

    # --- 10. HTTPS ---
    if ensure_cert "$(nc_fqdn)"; then
        vhost_patch "$(nc_fqdn)" "$blk"   # vhost HTTPS créé par certbot
        apache_reload || true
    fi
    rm -f "$blk"

    # --- 11. Finitions (index manquants, réparations) ---
    occ db:add-missing-indices >/dev/null 2>&1 || true
    occ maintenance:repair --include-expensive >/dev/null 2>&1 || true

    log STEP "Nextcloud prêt"
    echo -e "  Adresse        : ${GREEN}https://$(nc_fqdn)${RESET}"
    echo -e "  Administrateur : ${BOLD}${NC_ADMIN_USER:-admin}${RESET}"
    echo -e "  Mot de passe   : ${BOLD}${NC_ADMIN_PASS:-(inchangé)}${RESET}   ${YELLOW}(aussi dans server.conf — changez-le à la 1re connexion)${RESET}"
    echo -e "  Données        : ${NC_DATA_DIR}"
    echo -e "  Vérification   : Paramètres → Administration → Vue d'ensemble"
}

# ===========================================================================
# ÉTAPE : IMMICH (Docker)
# ===========================================================================
install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        return 0
    fi
    log INFO "Installation de Docker (dépôt officiel)…"
    apt_install ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck source=/dev/null
    local codename; codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker >/dev/null 2>&1
    log OK "Docker $(docker --version | awk '{print $3}' | tr -d ,) installé."
}

# env_set FICHIER CLÉ VALEUR — remplace (ou décommente, ou ajoute) CLÉ=…
env_set() {
    local f="$1" k="$2" v="$3"
    if grep -qE "^#? *${k}=" "$f"; then
        sed -i -E "s|^#? *${k}=.*|${k}=${v}|" "$f"
    else
        echo "${k}=${v}" >> "$f"
    fi
}

imm_compose() { (cd "$IMMICH_DIR" && docker compose "$@"); }

# Prépare docker-compose.yml + .env (sans rien démarrer) — testable à part
immich_prepare_files() {
    mkdir -p "$IMMICH_DIR"
    local base="https://github.com/immich-app/immich/releases/latest/download"
    if [[ ! -f "${IMMICH_DIR}/docker-compose.yml" ]]; then
        curl -fsSL -o "${IMMICH_DIR}/docker-compose.yml" "${base}/docker-compose.yml" \
            || { log ERROR "Téléchargement de docker-compose.yml impossible."; return 1; }
    fi
    if [[ ! -f "${IMMICH_DIR}/.env" ]]; then
        curl -fsSL -o "${IMMICH_DIR}/.env" "${base}/example.env" \
            || { log ERROR "Téléchargement de example.env impossible."; return 1; }
    fi

    [[ -n "${IMMICH_DB_PASS:-}" ]] || set_conf IMMICH_DB_PASS "$(gen_pass)"
    local env="${IMMICH_DIR}/.env"
    env_set "$env" UPLOAD_LOCATION  "${IMMICH_DATA}/library"
    env_set "$env" DB_DATA_LOCATION "${IMMICH_DATA}/postgres"
    env_set "$env" TZ               "Europe/Paris"
    env_set "$env" DB_PASSWORD      "$IMMICH_DB_PASS"
    chmod 600 "$env"

    local yml="${IMMICH_DIR}/docker-compose.yml"
    # Docker contourne UFW : le port ne doit écouter QUE en local (Apache
    # fait le lien avec l'extérieur en HTTPS).
    sed -i -E "s/^( *- *)['\"]?${IMMICH_PORT}:${IMMICH_PORT}['\"]?/\1'127.0.0.1:${IMMICH_PORT}:${IMMICH_PORT}'/" "$yml"
    if ! grep -qE "^ *- *'127\.0\.0\.1:${IMMICH_PORT}:${IMMICH_PORT}'" "$yml" \
       || grep -qE "^ *- *['\"]?${IMMICH_PORT}:" "$yml"; then
        log ERROR "Impossible de limiter le port ${IMMICH_PORT} à 127.0.0.1 dans ${yml}"
        log ERROR "(format du fichier changé ?). Immich n'est PAS démarré, pour ne pas l'exposer."
        return 1
    fi
    # Base PostgreSQL sur disques durs (réglages adaptés, cf. doc Immich)
    sed -i -E "s/^( *)# *DB_STORAGE_TYPE: *'HDD'/\1DB_STORAGE_TYPE: 'HDD'/" "$yml"
    log OK "Fichiers Immich prêts dans ${IMMICH_DIR} (port ${IMMICH_PORT} local seulement)."
}

step_immich() {
    log STEP "Immich — https://$(imm_fqdn)"
    command -v apache2ctl &>/dev/null || { log ERROR "Apache absent : lancez install_lamp.sh."; return 1; }
    install_docker
    immich_prepare_files || return 1
    mkdir -p "${IMMICH_DATA}/library" "${IMMICH_DATA}/postgres"

    log INFO "Téléchargement des images et démarrage (plusieurs minutes la 1re fois)…"
    imm_compose pull -q
    imm_compose up -d

    log INFO "Attente du démarrage d'Immich…"
    local ok=0
    for _ in $(seq 1 60); do
        if curl -fs "http://127.0.0.1:${IMMICH_PORT}/api/server/ping" 2>/dev/null | grep -q pong; then
            ok=1; break
        fi
        sleep 5
    done
    (( ok )) || { log ERROR "Immich ne répond pas après 5 min : cd ${IMMICH_DIR} && docker compose logs"; return 1; }
    log OK "Immich répond sur 127.0.0.1:${IMMICH_PORT}."
    set_conf IMMICH_SUB "$IMMICH_SUB"

    # Compte administrateur créé tout de suite : sinon, le premier visiteur
    # de la page d'accueil pourrait le créer à votre place.
    [[ -n "${IMMICH_ADMIN_EMAIL:-}" ]] || set_conf IMMICH_ADMIN_EMAIL "$ADMIN_EMAIL"
    [[ -n "${IMMICH_ADMIN_PASS:-}" ]]  || set_conf IMMICH_ADMIN_PASS "$(gen_pass 20)"
    local resp code
    resp=$(curl -s -w '\n%{http_code}' --max-time 15 -X POST \
        "http://127.0.0.1:${IMMICH_PORT}/api/auth/admin-sign-up" \
        -H 'Content-Type: application/json' \
        -d "$(printf '{"email":"%s","password":"%s","name":"Admin"}' "$IMMICH_ADMIN_EMAIL" "$IMMICH_ADMIN_PASS")" || true)
    code=$(tail -n1 <<< "$resp")
    case "$code" in
        200|201) log OK "Compte administrateur Immich créé : ${IMMICH_ADMIN_EMAIL}" ;;
        400)     log INFO "Immich a déjà un administrateur (compte existant conservé)." ;;
        *)       log WARN "Création du compte admin impossible (HTTP ${code:-?}) : créez-le TOUT DE SUITE"
                 log WARN "sur https://$(imm_fqdn) (le premier compte créé devient administrateur)." ;;
    esac
    ask_ovh_keys

    # --- Sous-domaine en proxy + réglages (gros envois, délai long) ---
    ensure_subdomain "$IMMICH_SUB" "$IMMICH_PORT"
    local f
    for f in "/etc/apache2/sites-available/$(imm_fqdn).conf" "/etc/apache2/sites-available/$(imm_fqdn)-le-ssl.conf"; do
        [[ -f "$f" ]] || continue
        sed -i -E "s|^( *ProxyPass +/ +http://[^ ]+/ +upgrade=websocket)$|\1 timeout=600|" "$f"
    done
    local blk; blk=$(mktemp)
    cat > "$blk" <<VHOST

    ${VHOST_MARKER} : Immich ---
    # Vidéos de plusieurs Go : pas de limite de taille, délai de 10 min
    LimitRequestBody 0
    ProxyTimeout 600
VHOST
    vhost_patch "$(imm_fqdn)" "$blk"
    apache_reload
    if ensure_cert "$(imm_fqdn)"; then
        vhost_patch "$(imm_fqdn)" "$blk"
        apache_reload || true
    fi
    rm -f "$blk"

    log STEP "Immich prêt"
    echo -e "  Adresse        : ${GREEN}https://$(imm_fqdn)${RESET}"
    echo -e "  Administrateur : ${BOLD}${IMMICH_ADMIN_EMAIL}${RESET}"
    echo -e "  Mot de passe   : ${BOLD}${IMMICH_ADMIN_PASS:-(inchangé)}${RESET}   ${YELLOW}(aussi dans server.conf — changez-le à la 1re connexion)${RESET}"
    echo -e "  Photos         : ${IMMICH_DATA}/library"
    echo -e "  Appli mobile   : « Immich » (Android/iOS), serveur https://$(imm_fqdn)"
}

# ===========================================================================
# ÉTAPE : FAIL2BAN
# ===========================================================================
step_fail2ban() {
    log STEP "Fail2Ban (SSH + Nextcloud)"
    apt_install fail2ban

    cat > /etc/fail2ban/filter.d/nextcloud.conf <<'CONF'
# install_cloud.sh — filtre officiel de la documentation Nextcloud
[Definition]
_groupsre = (?:(?:,?\s*"\w+":(?:"[^"]+"|\w+))*)
failregex = ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Login failed:
            ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Two-factor challenge failed:
            ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Trusted domain error.
datepattern = ,?\s*"time"\s*:\s*"%%Y-%%m-%%d[T ]%%H:%%M:%%S(%%z)?"
CONF

    local nc_log="${NC_DATA_DIR}/nextcloud.log"
    [[ -f "$nc_log" ]] || { [[ -d "$NC_DATA_DIR" ]] && touch "$nc_log" && chown www-data:www-data "$nc_log"; } || true

    {
        echo "# install_cloud.sh"
        echo "[DEFAULT]"
        echo "bantime  = 1h"
        echo "findtime = 10m"
        echo "maxretry = 5"
        echo
        echo "[sshd]"
        echo "enabled = true"
        if [[ -f "$nc_log" ]]; then
            echo
            echo "[nextcloud]"
            echo "enabled  = true"
            echo "backend  = auto"
            echo "port     = 80,443"
            echo "protocol = tcp"
            echo "filter   = nextcloud"
            echo "maxretry = 5"
            echo "bantime  = 1h"
            echo "findtime = 12h"
            echo "logpath  = ${nc_log}"
        fi
    } > /etc/fail2ban/jail.d/cloud.conf

    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    sleep 2
    fail2ban-client status 2>/dev/null | sed 's/^/  /' || log WARN "fail2ban ne répond pas : journalctl -u fail2ban"
    [[ -f "$nc_log" ]] || log INFO "Prison Nextcloud ajoutée à la prochaine relance (après l'étape nextcloud)."
    log OK "Fail2Ban actif."
}

# ===========================================================================
# ÉTAT / MISE À JOUR
# ===========================================================================
cmd_etat() {
    log STEP "RAID logiciel"
    if grep -q '^md' /proc/mdstat 2>/dev/null; then
        grep -A2 '^md' /proc/mdstat | sed 's/^/  /'
        if grep -qE '\[[U]*_[U_]*\]' /proc/mdstat; then
            echo -e "  ${RED}${BOLD}⚠  RAID DÉGRADÉ — un disque est hors service.${RESET}"
        else
            echo -e "  ${GREEN}Tous les disques sont actifs.${RESET}"
        fi
    else
        echo "  (aucun RAID logiciel)"
    fi

    log STEP "Disques (SMART)"
    local d h t
    for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
        h=$(smartctl -H "/dev/$d" 2>/dev/null | grep -iE 'overall-health|SMART Health Status' | awk -F: '{print $2}' | xargs || true)
        t=$(smartctl -A "/dev/$d" 2>/dev/null | awk '/Temperature_Celsius/ {print $10"°C"}' | head -n1 || true)
        printf "  /dev/%-8s %-12s %s\n" "$d" "${h:-?}" "$t"
    done

    log STEP "Espace disque"
    df -h / /srv 2>/dev/null | awk 'NR==1 || !seen[$0]++' | sed 's/^/  /'
    [[ -d "$NC_DATA_DIR" ]]          && echo "  Nextcloud : $(du -sh "$NC_DATA_DIR" 2>/dev/null | cut -f1)"
    [[ -d "${IMMICH_DATA}/library" ]] && echo "  Immich    : $(du -sh "${IMMICH_DATA}/library" 2>/dev/null | cut -f1)"

    log STEP "Nextcloud"
    if nc_installed; then
        echo -e "  ${GREEN}installé${RESET} — $(occ status --output=json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("version "+d["versionstring"]+(" (MAINTENANCE)" if d.get("maintenance") else ""))' 2>/dev/null || echo "version ?")"
    elif [[ -f "$(nc_dir)/occ" ]]; then
        echo -e "  ${YELLOW}fichiers présents mais installation non terminée${RESET} — sudo bash $0 nextcloud"
    else
        echo -e "  ${RED}non installé${RESET} — sudo bash $0 nextcloud"
    fi

    log STEP "Services"
    local s
    for s in apache2 mariadb redis-server docker fail2ban smartmontools; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            printf "  %-14s ${GREEN}actif${RESET}\n" "$s"
        else
            printf "  %-14s ${RED}%s${RESET}\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo absent)"
        fi
    done
    if nc_installed; then
        echo -e "\n  ${BOLD}Nextcloud${RESET} : $(occ status --output=json 2>/dev/null | grep -oE '"versionstring":"[^"]+"' | cut -d'"' -f4 || echo '?')"
    fi
    if [[ -f "${IMMICH_DIR}/docker-compose.yml" ]] && command -v docker &>/dev/null; then
        echo -e "  ${BOLD}Immich${RESET} :"
        imm_compose ps --format '    {{.Name}}  {{.Status}}' 2>/dev/null || true
    fi
    echo
}

cmd_mise_a_jour() {
    if nc_installed; then
        log STEP "Mise à jour de Nextcloud"
        runuser -u www-data -- php --define apc.enable_cli=1 "$(nc_dir)/updater/updater.phar" --no-interaction \
            || log WARN "L'updater a échoué — voir Paramètres → Administration → Vue d'ensemble."
        occ db:add-missing-indices >/dev/null 2>&1 || true
        occ status
    fi
    if [[ -f "${IMMICH_DIR}/docker-compose.yml" ]]; then
        log STEP "Mise à jour d'Immich (même version majeure : $(grep -E '^IMMICH_VERSION=' "${IMMICH_DIR}/.env" | cut -d= -f2))"
        echo -e "  ${YELLOW}Avant un changement de version majeure, lisez les notes de version Immich.${RESET}"
        imm_compose pull -q
        imm_compose up -d
        docker image prune -f >/dev/null
        log OK "Immich à jour."
    fi
}

step_tout() {
    # Chaque étape est lancée seule : un échec n'arrête pas les suivantes,
    # mais il est signalé dans le bilan (avant, « Serveur cloud installé »
    # s'affichait même quand Nextcloud avait échoué)
    local failed=() st
    for st in alertes raid nextcloud immich fail2ban; do
        "step_${st}" || failed+=("$st")
    done
    if (( ${#failed[@]} )); then
        log STEP "Serveur cloud installé — AVEC ERREURS"
        for st in "${failed[@]}"; do
            echo -e "  ${RED}✘ ${st}${RESET} — relancez : ${BOLD}sudo bash $0 ${st}${RESET}"
        done
        echo -e "  (le message d'erreur est plus haut, ou dans /var/log/install_server/)"
    else
        log STEP "Serveur cloud installé"
    fi
    echo -e "  Nextcloud : ${GREEN}https://$(nc_fqdn)${RESET}"
    echo -e "  Immich    : ${GREEN}https://$(imm_fqdn)${RESET}"
    echo -e "  État      : ${BOLD}sudo bash $0 etat${RESET}"
    (( ${#failed[@]} == 0 ))
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
menu() {
    while true; do
        echo -e "\n${CYAN}${BOLD}  ☁️  Serveur cloud — ${DOMAIN}${RESET}\n"
        echo -e "  ${CYAN}[1]${RESET} Tout installer (2 → 6)"
        echo -e "  ${CYAN}[2]${RESET} Alertes mail (relais SMTP du VPS)"
        echo -e "  ${CYAN}[3]${RESET} Surveillance RAID + disques"
        echo -e "  ${CYAN}[4]${RESET} Nextcloud  → https://$(nc_fqdn)"
        echo -e "  ${CYAN}[5]${RESET} Immich     → https://$(imm_fqdn)"
        echo -e "  ${CYAN}[6]${RESET} Fail2Ban (SSH + Nextcloud)"
        echo -e "  ${CYAN}[7]${RESET} État du serveur"
        echo -e "  ${CYAN}[8]${RESET} Envoyer une alerte de test"
        echo -e "  ${CYAN}[9]${RESET} Mettre à jour Nextcloud et Immich"
        echo -e "  ${CYAN}[0]${RESET} Retour\n"
        local choice
        read -rp "$(echo -e "  ${BOLD}Votre choix : ${RESET}")" choice
        case "$choice" in
            1) step_tout || true ;;
            2) step_alertes || true ;;
            3) step_raid || true ;;
            4) step_nextcloud || true ;;
            5) step_immich || true ;;
            6) step_fail2ban || true ;;
            7) cmd_etat ;;
            8) cmd_test_alertes || true ;;
            9) cmd_mise_a_jour || true ;;
            0|q) return 0 ;;
            *) log WARN "Choix invalide : ${choice}" ;;
        esac
    done
}

case "${1:-menu}" in
    menu)                    menu ;;
    tout|all)                step_tout ;;
    alertes|mail)            step_alertes ;;
    raid)                    step_raid ;;
    nextcloud)               step_nextcloud ;;
    immich)                  step_immich ;;
    fail2ban)                step_fail2ban ;;
    etat|status)             cmd_etat ;;
    test-alertes)            cmd_test_alertes ;;
    mise-a-jour|update)      cmd_mise_a_jour ;;
    _prepare-immich)         immich_prepare_files ;;   # test : fichiers seulement
    -h|--help|help)          sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) log ERROR "Commande inconnue : $1 (voir : $0 help)"; exit 1 ;;
esac
