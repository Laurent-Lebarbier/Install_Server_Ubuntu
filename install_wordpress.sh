#!/bin/bash
# =============================================================================
#  install_wordpress.sh — Installation de WordPress
#  Auteur  : Laurent Lebarbier
#  Version : 2.0
# =============================================================================
#
#  Installe WordPress sur le VirtualHost du domaine (créé par install_lamp.sh) :
#    - WP-CLI
#    - Base de données MariaDB dédiée (distincte de DB_NAME/DB_USER, le
#      compte créé par install_lamp.sh pour un éventuel site "vitrine")
#    - Téléchargement + configuration de WordPress (wp-config.php, clés de
#      sécurité uniques générées automatiquement par WP-CLI)
#    - Création du compte administrateur WordPress
#    - Permaliens "jolis" (/%postname%/) — nécessite mod_rewrite et
#      AllowOverride All, déjà activés par install_lamp.sh
#    - Durcissement de base : permissions fichiers, édition de fichiers
#      désactivée depuis l'admin WordPress (DISALLOW_FILE_EDIT)
#
#  Prérequis : install_lamp.sh doit avoir été exécuté au préalable
#              (Apache, PHP, MariaDB, VirtualHost pour $DOMAIN).
#
#  Usage : sudo bash install_wordpress.sh
#          Ou via le menu principal install.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Couleurs & helpers
# ---------------------------------------------------------------------------
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
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') — $*" >> /var/log/install_server.log 2>/dev/null || true
}

confirm() {
    local prompt="${1:-Continuer ?}"
    local answer
    read -rp "$(echo -e "${YELLOW}  ❓ $prompt [O/n] : ${RESET}")" answer
    [[ "${answer,,}" =~ ^(o|oui|y|yes|)$ ]]
}

# ---------------------------------------------------------------------------
# Vérifications & chargement de la configuration
# ---------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"; exit 1
fi

readonly CONFIG_FILE="$(dirname "$0")/server.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log ERROR "server.conf introuvable. Lancez d'abord install.sh."; exit 1
fi
# shellcheck source=./server.conf
source "$CONFIG_FILE"

readonly VHOST_DIR="/var/www/${DOMAIN}/public_html"

if ! dpkg -l apache2 &>/dev/null; then
    log ERROR "Apache non détecté. Lancez d'abord install_lamp.sh (option 2 du menu)."
    exit 1
fi
if [[ ! -d "$VHOST_DIR" ]]; then
    log ERROR "$VHOST_DIR introuvable. Lancez d'abord install_lamp.sh."
    exit 1
fi

log STEP "Installation de WordPress sur $DOMAIN"

# ---------------------------------------------------------------------------
# 1. Dépendances & WP-CLI
# ---------------------------------------------------------------------------
log STEP "Vérification des dépendances"
apt-get install -y -qq php-cli curl >/dev/null
log OK "php-cli et curl présents."

log STEP "Installation de WP-CLI"
if ! command -v wp &>/dev/null; then
    curl -sS -o /tmp/wp-cli.phar \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /tmp/wp-cli.phar
    mv /tmp/wp-cli.phar /usr/local/bin/wp
    log OK "WP-CLI installé ($(wp --version --allow-root 2>/dev/null || echo 'ok'))."
else
    log INFO "WP-CLI déjà installé."
fi

# ---------------------------------------------------------------------------
# 2. Informations du site
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}  📝 Configuration WordPress${RESET}"

read -rp "$(echo -e "  ${CYAN}Titre du site [${DOMAIN}] : ${RESET}")" WP_TITLE
WP_TITLE="${WP_TITLE:-$DOMAIN}"

read -rp "$(echo -e "  ${CYAN}Identifiant admin WordPress [wpadmin] : ${RESET}")" WP_ADMIN_USER
WP_ADMIN_USER="${WP_ADMIN_USER:-wpadmin}"

read -rp "$(echo -e "  ${CYAN}Email admin WordPress [${ADMIN_EMAIL}] : ${RESET}")" WP_ADMIN_EMAIL
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-$ADMIN_EMAIL}"

# Mot de passe admin WordPress : généré aléatoirement, affiché en fin de
# script et sauvegardé dans server.conf (même logique que VMAIL_DB_PASS
# dans install_mail.sh)
WP_ADMIN_PASS=$(openssl rand -base64 18 | tr -d '+/=' | head -c 20)

# ---------------------------------------------------------------------------
# 3. Base de données dédiée (distincte de DB_NAME/DB_USER du site "vitrine"
#    éventuellement déjà créé par install_lamp.sh)
# ---------------------------------------------------------------------------
log STEP "Création de la base de données WordPress"
WP_DB_NAME="${DB_NAME}_wp"
WP_DB_USER="${DB_USER}_wp"
# Réutilisé depuis server.conf si déjà présent (voir même correctif que
# VMAIL_DB_PASS dans install_mail.sh — CREATE USER IF NOT EXISTS ne met
# pas à jour le mot de passe d'un utilisateur MySQL déjà existant).
if grep -q '^WP_DB_PASS=' "$CONFIG_FILE"; then
    WP_DB_PASS=$(grep '^WP_DB_PASS=' "$CONFIG_FILE" | cut -d'"' -f2)
    log INFO "Mot de passe WordPress DB existant réutilisé depuis server.conf."
else
    WP_DB_PASS=$(openssl rand -base64 20 | tr -d '+/=' | head -c 24)
fi

mysql -e "CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';"
mysql -e "ALTER USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"
log OK "Base '$WP_DB_NAME' et utilisateur '$WP_DB_USER' créés."

# Sauvegarde des secrets dans server.conf (ne duplique pas si déjà présent —
# utile si vous relancez le script après une première installation)
grep -q '^WP_DB_NAME='    "$CONFIG_FILE" || echo "WP_DB_NAME=\"${WP_DB_NAME}\""       >> "$CONFIG_FILE"
grep -q '^WP_DB_USER='    "$CONFIG_FILE" || echo "WP_DB_USER=\"${WP_DB_USER}\""       >> "$CONFIG_FILE"
grep -q '^WP_DB_PASS='    "$CONFIG_FILE" || echo "WP_DB_PASS=\"${WP_DB_PASS}\""       >> "$CONFIG_FILE"
grep -q '^WP_ADMIN_USER=' "$CONFIG_FILE" || echo "WP_ADMIN_USER=\"${WP_ADMIN_USER}\"" >> "$CONFIG_FILE"
grep -q '^WP_ADMIN_PASS=' "$CONFIG_FILE" || echo "WP_ADMIN_PASS=\"${WP_ADMIN_PASS}\"" >> "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# 4. Vérification du contenu existant du VirtualHost
# ---------------------------------------------------------------------------
if [[ -f "${VHOST_DIR}/wp-config.php" ]]; then
    log WARN "WordPress semble déjà installé dans $VHOST_DIR (wp-config.php présent)."
    confirm "Continuer quand même (peut écraser des fichiers existants) ?" \
        || { log INFO "Installation annulée."; exit 0; }
elif [[ -n "$(ls -A "$VHOST_DIR" 2>/dev/null)" ]]; then
    log WARN "$VHOST_DIR contient déjà des fichiers (ex : la page d'accueil par défaut d'install_lamp.sh)."
    confirm "Effacer ce contenu et installer WordPress à la place ?" \
        || { log INFO "Installation annulée."; exit 0; }
    find "$VHOST_DIR" -mindepth 1 -delete
fi

chown -R www-data:www-data "$VHOST_DIR"

# ---------------------------------------------------------------------------
# 5. Téléchargement et configuration de WordPress
# ---------------------------------------------------------------------------
log STEP "Téléchargement de WordPress (dernière version, FR)"
sudo -u www-data wp core download --path="$VHOST_DIR" --locale=fr_FR
log OK "WordPress téléchargé."

log STEP "Génération de wp-config.php"
sudo -u www-data wp config create \
    --path="$VHOST_DIR" \
    --dbname="$WP_DB_NAME" \
    --dbuser="$WP_DB_USER" \
    --dbpass="$WP_DB_PASS" \
    --dbhost="localhost" \
    --extra-php <<'PHP'
define('DISALLOW_FILE_EDIT', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
PHP
log OK "wp-config.php généré (clés de sécurité uniques incluses)."

# Utilise HTTPS si Certbot a déjà posé un certificat pour ce domaine
# (install_lamp.sh, étape 7), sinon HTTP en attendant.
WP_SCHEME="http"
[[ -d "/etc/letsencrypt/live/${DOMAIN}" ]] && WP_SCHEME="https"

log STEP "Installation de WordPress (création du site + compte admin)"
sudo -u www-data wp core install \
    --path="$VHOST_DIR" \
    --url="${WP_SCHEME}://${DOMAIN}" \
    --title="$WP_TITLE" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --skip-email
log OK "WordPress installé."

# ---------------------------------------------------------------------------
# 6. Permaliens "jolis"
# ---------------------------------------------------------------------------
log STEP "Configuration des permaliens"
sudo -u www-data wp rewrite structure '/%postname%/' --path="$VHOST_DIR"
sudo -u www-data wp rewrite flush --hard --path="$VHOST_DIR"
log OK "Permaliens configurés (/%postname%/)."

# ---------------------------------------------------------------------------
# 7. Permissions finales (recommandations officielles WordPress)
# ---------------------------------------------------------------------------
log STEP "Application des permissions"
find "$VHOST_DIR" -type d -exec chmod 755 {} \;
find "$VHOST_DIR" -type f -exec chmod 644 {} \;
chmod 640 "${VHOST_DIR}/wp-config.php"
chown -R www-data:www-data "$VHOST_DIR"
log OK "Permissions appliquées (dossiers 755, fichiers 644, wp-config.php 640)."

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------
log STEP "Installation WordPress terminée"
echo -e "  Site            : ${GREEN}${WP_SCHEME}://${DOMAIN}${RESET}"
echo -e "  Admin           : ${GREEN}${WP_SCHEME}://${DOMAIN}/wp-admin${RESET}"
echo -e "  Utilisateur     : ${BOLD}${WP_ADMIN_USER}${RESET}"
echo -e "  Mot de passe    : ${YELLOW}${WP_ADMIN_PASS}${RESET}  (sauvegardé dans server.conf, chmod 600)"
echo -e "  Base de données : ${BOLD}${WP_DB_NAME}${RESET}  (utilisateur : ${WP_DB_USER})"
if [[ "$WP_SCHEME" == "http" ]]; then
    echo -e "  ${YELLOW}⚠  Aucun certificat SSL détecté pour ${DOMAIN}.${RESET}"
    echo -e "  ${YELLOW}   Lancez (ou relancez) install_lamp.sh (étape Certbot), puis :${RESET}"
    echo -e "  ${YELLOW}   wp option update siteurl 'https://${DOMAIN}' --path=${VHOST_DIR} --allow-root${RESET}"
    echo -e "  ${YELLOW}   wp option update home    'https://${DOMAIN}' --path=${VHOST_DIR} --allow-root${RESET}"
fi
