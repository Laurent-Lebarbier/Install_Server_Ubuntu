#!/bin/bash
# =============================================================================
#  passer_role_cloud.sh — Transforme un serveur « complet » en serveur « cloud »
#  Auteur  : Laurent Lebarbier
#  Version : 1.0
# =============================================================================
#
#  Cas d'usage : le dédié a été installé en rôle « complet » (web + mail +
#  FTP + Nextcloud + Immich), et on décide finalement de garder un VPS pour
#  le site, WordPress et le mail. Le dédié ne doit plus faire que le cloud
#  (Nextcloud + Immich) et recevoir les sauvegardes du VPS.
#
#  Ce que fait le script (Nextcloud et Immich ne sont PAS touchés) :
#    - server.conf : SERVER_ROLE="cloud"
#    - désinstalle Postfix, Dovecot, OpenDKIM, SpamAssassin, Pure-FTPd
#      (un 2e serveur mail pour le même domaine garderait les mails à
#      destination de @domaine en local au lieu de les envoyer au VPS)
#    - supprime la base « vmail », les boîtes /var/vmail, la clé DKIM locale,
#      le compte FTP/SFTP et son bloc dans sshd_config, la prison Fail2Ban mail
#    - Apache : désactive le site principal et phpMyAdmin, ferme le
#      VirtualHost par défaut (comme install_lamp.sh en rôle cloud)
#    - nom d'hôte : mail.<domaine> → <NC_SUB>.<domaine>
#    - pare-feu : remis à zéro puis refait en rôle cloud (22, 80, 443)
#    - Nextcloud : retire l'envoi de mails par le Postfix local
#
#  Ensuite (affiché à la fin) : compte alertes@ sur le VPS, puis
#  install_cloud.sh alertes / nextcloud / fail2ban.
#
#  Usage : sudo bash passer_role_cloud.sh
# =============================================================================

set -euo pipefail

# Journal d'installation (voir lib_log.sh)
# shellcheck source=lib_log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_log.sh" 2>/dev/null && start_install_log "$@"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
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
}

confirm() {
    local ans
    read -rp "$(echo -e "  ${CYAN}$1 [o/N] : ${RESET}")" ans
    [[ "$ans" =~ ^[oOyY]$ ]]
}

[[ $EUID -eq 0 ]] || { log ERROR "À lancer avec sudo."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/server.conf"
[[ -f "$CONFIG_FILE" ]] || { log ERROR "server.conf introuvable (${CONFIG_FILE})."; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${DOMAIN:?DOMAIN manquant dans server.conf}"
: "${SERVER_IP:?SERVER_IP manquant dans server.conf}"
NC_SUB="${NC_SUB:-cloud}"
SYS_USER="${SYS_USER:-ubuntu}"
readonly FTP_USER="${SYS_USER}_ftp"
readonly NEW_HOST="${NC_SUB}.${DOMAIN}"

if [[ "${SERVER_ROLE:-web}" == "cloud" ]] && ! dpkg -s postfix &>/dev/null; then
    log INFO "Ce serveur est déjà en rôle « cloud », sans serveur mail. Rien à faire."
    exit 0
fi

echo -e "\n${BOLD}  Passage de ce serveur en rôle « cloud »${RESET} (${DOMAIN}, ${SERVER_IP})\n"
echo -e "  Seront ${RED}supprimés${RESET} : serveur mail (Postfix, Dovecot, OpenDKIM, SpamAssassin),"
echo -e "  boîtes mail locales (/var/vmail) et base vmail, clé DKIM locale, FTP/SFTP,"
echo -e "  site principal ${DOMAIN} et phpMyAdmin (désactivés dans Apache)."
echo -e "  ${GREEN}Conservés${RESET} : Nextcloud, Immich, MariaDB, Redis, Docker, certificats, RAID.\n"
echo -e "  ${YELLOW}Le DNS de ${DOMAIN} (site, MX, SPF, DKIM) doit pointer vers le VPS,${RESET}"
echo -e "  ${YELLOW}pas vers ce serveur. Seuls ${NC_SUB}.${DOMAIN} et ${IMMICH_SUB:-photos}.${DOMAIN} pointent ici.${RESET}\n"
confirm "Continuer ?" || { log WARN "Annulé."; exit 0; }

# ---------------------------------------------------------------------------
log STEP "server.conf"
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
if grep -q '^SERVER_ROLE=' "$CONFIG_FILE"; then
    sed -i 's/^SERVER_ROLE=.*/SERVER_ROLE="cloud"/' "$CONFIG_FILE"
else
    echo 'SERVER_ROLE="cloud"' >> "$CONFIG_FILE"
fi
# Le mot de passe vmail ne sert plus : on le retire pour ne pas le réutiliser
sed -i '/^VMAIL_DB_PASS=/d' "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
log OK "SERVER_ROLE=\"cloud\" (ancienne version gardée en .bak)."

# ---------------------------------------------------------------------------
log STEP "Nextcloud : arrêt de l'envoi par le Postfix local"
NC_DIR="/var/www/${NC_SUB}.${DOMAIN}/public_html"
if [[ -f "${NC_DIR}/occ" ]]; then
    occ() { runuser -u www-data -- php --define apc.enable_cli=1 "${NC_DIR}/occ" "$@"; }
    if [[ "$(occ config:system:get mail_smtpmode 2>/dev/null || true)" == "sendmail" ]]; then
        occ config:system:delete mail_smtpmode    >/dev/null 2>&1 || true
        occ config:system:delete mail_sendmailmode >/dev/null 2>&1 || true
        log OK "Réglage mail retiré (il sera refait avec le relais : install_cloud.sh nextcloud)."
    else
        log INFO "Rien à changer."
    fi
else
    log INFO "Nextcloud absent : rien à faire."
fi

# ---------------------------------------------------------------------------
log STEP "Désinstallation du serveur mail et du FTP"
systemctl stop postfix dovecot opendkim spamassassin spamd pure-ftpd 2>/dev/null || true
mapfile -t pkgs < <(dpkg-query -W -f='${Package} ${Status}\n' \
    'postfix*' 'dovecot*' 'opendkim*' 'spamassassin' 'spamc' 'sa-compile' \
    'pure-ftpd*' 'mailutils' 2>/dev/null | awk '/install ok installed/ {print $1}')
if (( ${#pkgs[@]} )); then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${pkgs[@]}" >/dev/null
    log OK "Paquets supprimés : ${pkgs[*]}"
else
    log INFO "Aucun paquet mail/FTP installé."
fi
rm -f /etc/fail2ban/jail.d/mail.conf
rm -rf /etc/dkimkeys /etc/opendkim /run/opendkim
if [[ -d /var/vmail ]]; then
    rm -rf /var/vmail
    userdel vmail 2>/dev/null || true
    groupdel vmail 2>/dev/null || true
    log OK "/var/vmail supprimé."
fi
mysql -e "DROP DATABASE IF EXISTS vmail; DROP USER IF EXISTS 'vmail'@'localhost'; DROP USER IF EXISTS 'vmail'@'127.0.0.1';" 2>/dev/null \
    && log OK "Base vmail supprimée." || log WARN "Base vmail : suppression impossible (à vérifier)."
rm -f /etc/cron.d/*spamassassin* 2>/dev/null || true

# ---------------------------------------------------------------------------
log STEP "Compte FTP / SFTP"
SSHD_CONFIG="/etc/ssh/sshd_config"
BLOCK_BEGIN="# >>> install_ftp.sh: SFTP pour ${FTP_USER} >>>"
BLOCK_END="# <<< install_ftp.sh: SFTP pour ${FTP_USER} <<<"
if grep -qF "$BLOCK_BEGIN" "$SSHD_CONFIG"; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i "\|^${BLOCK_BEGIN}\$|,\|^${BLOCK_END}\$|d" "$SSHD_CONFIG"
    if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        log OK "Bloc SFTP retiré de sshd_config."
    else
        log ERROR "sshd_config invalide après modification : remise de la sauvegarde."
        cp "$(ls -t "${SSHD_CONFIG}".bak.* | head -n1)" "$SSHD_CONFIG"
    fi
fi
if id "$FTP_USER" &>/dev/null; then
    userdel "$FTP_USER" 2>/dev/null || true
    log OK "Compte système ${FTP_USER} supprimé."
fi
rm -rf /home/ftpusers /etc/pure-ftpd /etc/ssl/private/pure-ftpd.pem

# ---------------------------------------------------------------------------
log STEP "Apache : site principal et phpMyAdmin désactivés"
for s in "${DOMAIN}-le-ssl.conf" "${DOMAIN}.conf" 000-default.conf default-ssl.conf; do
    [[ -e "/etc/apache2/sites-enabled/${s}" ]] && a2dissite -q "$s" && log OK "Désactivé : ${s}"
done
if [[ -e /etc/apache2/conf-enabled/phpmyadmin.conf ]]; then
    a2disconf -q phpmyadmin && log OK "Désactivé : phpMyAdmin"
fi
cat > /etc/apache2/sites-available/000-catchall.conf <<'VHOST'
# install_lamp.sh (rôle cloud) — répond aux requêtes sans nom connu
<VirtualHost *:80>
    ServerName  catchall.invalid
    DocumentRoot /var/www/html
    <Location />
        Require all denied
    </Location>
    ErrorLog  ${APACHE_LOG_DIR}/catchall-error.log
    CustomLog ${APACHE_LOG_DIR}/catchall-access.log combined
</VirtualHost>
VHOST
a2ensite -q 000-catchall.conf
if apache2ctl configtest 2>/dev/null; then
    systemctl reload apache2
    log OK "Apache rechargé (seuls ${NC_SUB} et ${IMMICH_SUB:-photos} répondent)."
else
    log ERROR "apache2ctl configtest a échoué : voir « sudo apache2ctl configtest »."
fi
log INFO "Fichiers du site laissés en place : /var/www/${DOMAIN} (supprimez-les si inutiles)."

# ---------------------------------------------------------------------------
log STEP "Nom d'hôte"
OLD_HOST=$(hostname -f 2>/dev/null || hostname)
hostnamectl set-hostname "$NEW_HOST"
sed -i "/[[:space:]]mail\.${DOMAIN//./\\.}\([[:space:]]\|$\)/d" /etc/hosts
grep -qE "[[:space:]]${NEW_HOST//./\\.}([[:space:]]|$)" /etc/hosts \
    || echo "${SERVER_IP} ${NEW_HOST} ${NC_SUB}" >> /etc/hosts
log OK "${OLD_HOST} → ${NEW_HOST}"

# ---------------------------------------------------------------------------
log STEP "Pare-feu (rôle cloud)"
# install_firewall.sh remet lui-même UFW à zéro : un « ufw reset » ici, dans
# la même seconde, faisait échouer le sien (nom de sauvegarde déjà pris)
bash "${SCRIPT_DIR}/install_firewall.sh"
# Docker recrée ses propres règles (il ne passe pas par UFW)
systemctl restart docker 2>/dev/null || true

# ---------------------------------------------------------------------------
systemctl restart fail2ban 2>/dev/null || true

log STEP "Serveur passé en rôle « cloud »"
echo -e "  ${BOLD}À faire maintenant :${RESET}"
echo -e "  1. ${BOLD}Sur le VPS${RESET}, créer le compte qui enverra les alertes de ce serveur :"
echo -e "       ${CYAN}sudo bash manage_mail.sh add alertes@${DOMAIN}${RESET}"
echo -e "  2. ${BOLD}Ici${RESET} :"
echo -e "       ${CYAN}sudo bash ${SCRIPT_DIR}/install_cloud.sh alertes${RESET}     # relais via le VPS + mail de test"
echo -e "       ${CYAN}sudo bash ${SCRIPT_DIR}/install_cloud.sh raid${RESET}        # adresse des alertes RAID/disques"
echo -e "       ${CYAN}sudo bash ${SCRIPT_DIR}/install_cloud.sh nextcloud${RESET}   # mails Nextcloud via le relais"
echo -e "       ${CYAN}sudo bash ${SCRIPT_DIR}/install_cloud.sh fail2ban${RESET}    # prisons sshd + nextcloud"
echo -e "  3. Sauvegarde du VPS vers ce serveur : ${CYAN}sudo bash backup_remote.sh${RESET} (sur le VPS)"
echo -e "  4. Reverse DNS de ${SERVER_IP} : inutile maintenant (pas de mail ici)."
