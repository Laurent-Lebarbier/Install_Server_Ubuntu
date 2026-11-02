#!/bin/bash
# =============================================================================
#  install_lamp.sh — Stack LAMP sécurisée
#  Auteur  : Laurent Lebarbier
#  Version : 2.0
# =============================================================================
#
#  Installe et configure :
#    - Apache 2         : serveur web
#    - MariaDB          : base de données relationnelle
#    - PHP (dernière version stable) + extensions courantes
#    - phpMyAdmin       : interface web de gestion de la base
#    - Certbot          : certificats SSL/TLS Let's Encrypt (HTTPS gratuit)
#
#  Configuration :
#    - VirtualHost pour le domaine principal (lu depuis server.conf)
#    - Redirection automatique HTTP → HTTPS
#    - Désactivation du site par défaut Apache
#    - Sécurisation de MariaDB (suppression des comptes anonymes, base test)
#    - phpMyAdmin accessible uniquement depuis une IP de confiance (à ajuster)
#
#  Rôle « cloud » (SERVER_ROLE="cloud") : Apache + MariaDB + PHP + Certbot
#  seulement. Pas de site pour le domaine principal (il est sur le serveur
#  web), pas de phpMyAdmin (accès à la base par SSH). Les accès par l'IP ou
#  par un nom inconnu reçoivent un 403 ; Nextcloud et Immich sont ajoutés par
#  install_cloud.sh sur leurs sous-domaines.
#
#  Usage : sudo bash install_lamp.sh
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

# ---------------------------------------------------------------------------
# Vérifications & chargement de la configuration
# ---------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"; exit 1
fi

readonly CONFIG_FILE="$(dirname "$0")/server.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log ERROR "server.conf introuvable. Lancez d'abord install.sh."
    exit 1
fi
# shellcheck source=./server.conf
source "$CONFIG_FILE"

log STEP "Installation de la stack LAMP"
log INFO "Domaine    : $DOMAIN"
log INFO "Utilisateur: $DB_USER"
log INFO "Base de données : $DB_NAME"

# ---------------------------------------------------------------------------
# 1. Mise à jour & dépendances
# ---------------------------------------------------------------------------
log STEP "Mise à jour des paquets"
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 software-properties-common ca-certificates

# ---------------------------------------------------------------------------
# 2. Apache
# ---------------------------------------------------------------------------
log STEP "Installation d'Apache"
if ! dpkg -l apache2 &>/dev/null; then
    apt-get install -y apache2
fi
# Activer les modules essentiels
a2enmod rewrite ssl headers deflate expires
systemctl enable --now apache2
log OK "Apache installé et démarré."

# ---------------------------------------------------------------------------
# 3. MariaDB
# ---------------------------------------------------------------------------
log STEP "Installation de MariaDB"
if ! dpkg -l mariadb-server &>/dev/null; then
    apt-get install -y mariadb-server mariadb-client
fi
systemctl enable --now mariadb

# Réglage mémoire InnoDB : 1/4 de la RAM (défaut MariaDB : 128 Mo seulement).
# Sur un dédié 32 Go en rôle « complet » (Nextcloud + WordPress + mail + une
# éventuelle base de jeu), ça fait 8 Go de cache : les disques HDD sont alors
# beaucoup moins sollicités. Fichier écrit une seule fois : modifiez-le à la
# main ensuite si besoin (puis : systemctl restart mariadb).
TUNING_CNF="/etc/mysql/mariadb.conf.d/90-install-server.cnf"
if [[ ! -f "$TUNING_CNF" ]]; then
    ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    pool_mb=$(( ram_mb / 4 )); (( pool_mb < 256 )) && pool_mb=256
    cat > "$TUNING_CNF" <<CNF
# Généré par install_lamp.sh — RAM détectée : ${ram_mb} Mo
[mysqld]
innodb_buffer_pool_size = ${pool_mb}M
innodb_log_file_size    = $(( pool_mb / 4 > 2048 ? 2048 : (pool_mb / 4 < 64 ? 64 : pool_mb / 4) ))M
innodb_flush_method     = O_DIRECT
max_connections         = 200
CNF
    systemctl restart mariadb
    log OK "MariaDB : cache InnoDB réglé à ${pool_mb} Mo (${TUNING_CNF})."
fi

# Sécurisation de MariaDB (équivalent mysql_secure_installation)
# Note : on NE touche PAS à l'authentification de root@localhost, qui reste
# en "unix_socket" (le défaut sécurisé sur Ubuntu/Debian, sans mot de passe
# à gérer). La modifier ici casserait toutes les commandes `mysql -e` sans
# identifiants exécutées ensuite dans ce script ET dans install_mail.sh.
log INFO "Sécurisation de MariaDB..."
mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -e "FLUSH PRIVILEGES;"

# Création de la base et de l'utilisateur
log INFO "Création de la base de données '$DB_NAME' et de l'utilisateur '$DB_USER'..."
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"
log OK "Base de données et utilisateur créés."

# ---------------------------------------------------------------------------
# 4. PHP
# ---------------------------------------------------------------------------
log STEP "Installation de PHP et ses extensions"
apt-get install -y \
    php libapache2-mod-php php-mysql \
    php-curl php-gd php-intl php-imagick \
    php-imap php-mbstring php-xml php-xmlrpc \
    php-zip php-apcu php-bcmath php-tidy

# Optimisations PHP recommandées
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $NF}')
if [[ -f "$PHP_INI" ]]; then
    sed -i 's/^upload_max_filesize.*/upload_max_filesize = 64M/' "$PHP_INI"
    sed -i 's/^post_max_size.*/post_max_size = 64M/'            "$PHP_INI"
    sed -i 's/^memory_limit.*/memory_limit = 256M/'             "$PHP_INI"
    sed -i 's/^max_execution_time.*/max_execution_time = 120/'   "$PHP_INI"
    log OK "php.ini optimisé (upload 64M, mémoire 256M)."
fi
systemctl restart apache2

# ---------------------------------------------------------------------------
# Rôle cloud : on s'arrête ici (pas de site principal ni de phpMyAdmin)
# ---------------------------------------------------------------------------
if [[ "${SERVER_ROLE:-web}" == "cloud" ]]; then
    log STEP "Rôle cloud : VirtualHost par défaut fermé"
    # Premier VirtualHost chargé (000-…) = celui qui répond à l'IP nue ou à un
    # nom inconnu : on refuse, plutôt que d'exposer la page Apache par défaut.
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
    a2dissite -q 000-default.conf 2>/dev/null || true
    a2ensite -q 000-catchall.conf
    if ! command -v certbot &>/dev/null; then
        apt-get install -y certbot python3-certbot-apache
    fi
    systemctl reload apache2
    log OK "Apache, MariaDB et PHP prêts (sans site principal ni phpMyAdmin)."
    echo -e "  Suite : ${BOLD}sudo bash install_cloud.sh${RESET} (menu [12] d'install.sh)"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. VirtualHost pour le domaine
# ---------------------------------------------------------------------------
log STEP "Configuration du VirtualHost pour $DOMAIN"
VHOST_DIR="/var/www/${DOMAIN}/public_html"
mkdir -p "$VHOST_DIR"
chown -R "$SYS_USER:www-data" "$VHOST_DIR"
chmod -R 755 "$VHOST_DIR"

# Page d'accueil par défaut
cat > "${VHOST_DIR}/index.html" <<HTML
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${DOMAIN}</title>
    <style>
        body { font-family: sans-serif; text-align: center; padding: 60px;
               background: #f8f8f8; color: #333; }
        h1   { font-size: 2.5rem; margin-bottom: 0.5rem; }
        p    { color: #666; }
    </style>
</head>
<body>
    <h1>🚀 ${DOMAIN}</h1>
    <p>Serveur Ubuntu opérationnel — stack LAMP + SSL actifs.</p>
</body>
</html>
HTML

# VirtualHost HTTP (port 80) — redirigera vers HTTPS après Certbot
cat > "/etc/apache2/sites-available/${DOMAIN}.conf" <<VHOST
<VirtualHost *:80>
    ServerAdmin   ${ADMIN_EMAIL}
    ServerName    ${DOMAIN}
    ServerAlias   www.${DOMAIN}
    DocumentRoot  ${VHOST_DIR}

    <Directory ${VHOST_DIR}>
        Options       -Indexes +FollowSymLinks
        AllowOverride All
        Require       all granted
    </Directory>

    # Logs dédiés au domaine
    ErrorLog  \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
VHOST

# Désactivation du site par défaut, activation du domaine
a2dissite 000-default.conf 2>/dev/null || true
a2ensite "${DOMAIN}.conf"
systemctl reload apache2
log OK "VirtualHost pour $DOMAIN activé."

# ---------------------------------------------------------------------------
# 6. phpMyAdmin
# ---------------------------------------------------------------------------
log STEP "Installation de phpMyAdmin"
if ! dpkg -l phpmyadmin &>/dev/null; then
    # Installation non-interactive
    # Note : pas de "phpmyadmin/mysql/admin-pass" ici — root@localhost reste
    # en authentification unix_socket (voir plus haut). dbconfig-common
    # s'exécute en tant que root pendant la postinst du paquet et se
    # connecte via le socket local sans mot de passe, comme prévu.
    debconf-set-selections <<< "phpmyadmin phpmyadmin/dbconfig-install boolean true"
    debconf-set-selections <<< "phpmyadmin phpmyadmin/app-password-confirm password ${DB_PASS}"
    debconf-set-selections <<< "phpmyadmin phpmyadmin/mysql/app-pass password ${DB_PASS}"
    debconf-set-selections <<< "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2"
    DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin
fi
phpenmod mbstring
# Lien symbolique si absent
if [[ ! -f /etc/apache2/conf-available/phpmyadmin.conf ]]; then
    ln -s /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf
fi
a2enconf phpmyadmin

# Restriction d'accès à phpMyAdmin par IP (recommandé)
# Modifiez l'IP ci-dessous avec votre IP personnelle pour plus de sécurité
cat > /etc/apache2/conf-available/phpmyadmin-restrict.conf <<CONF
# Restriction d'accès à phpMyAdmin
# Remplacez 0.0.0.0/0 par votre IP fixe pour plus de sécurité
<Directory /usr/share/phpmyadmin>
    Options -Indexes
    AllowOverride None
    Require all granted
    # Exemple pour restreindre :
    # Require ip 1.2.3.4
</Directory>
CONF
a2enconf phpmyadmin-restrict
systemctl reload apache2
log OK "phpMyAdmin installé."

# ---------------------------------------------------------------------------
# 7. Certbot — Certificats SSL Let's Encrypt
# ---------------------------------------------------------------------------
log STEP "Configuration SSL avec Certbot (Let's Encrypt)"

if ! command -v certbot &>/dev/null; then
    apt-get install -y certbot python3-certbot-apache
fi

log INFO "Obtention du certificat SSL pour $DOMAIN et www.$DOMAIN..."
certbot --non-interactive --agree-tos \
        --apache \
        --email "$ADMIN_EMAIL" \
        -d "$DOMAIN" \
        -d "www.${DOMAIN}" \
        --redirect \
    && log OK "Certificat SSL obtenu et redirection HTTPS activée." \
    || log WARN "Certbot a échoué. Vérifiez que DNS pointe vers $SERVER_IP."

# Renouvellement automatique (cron déjà configuré par Certbot)
log INFO "Renouvellement automatique : certbot renew --quiet (géré par systemd timer)."

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------
log STEP "Installation LAMP terminée"
echo -e "  Site web     : ${GREEN}https://${DOMAIN}${RESET}"
echo -e "  phpMyAdmin   : ${GREEN}https://${DOMAIN}/phpmyadmin${RESET}"
echo -e "  Utilisateur  : ${BOLD}${DB_USER}${RESET}"
echo -e "  Base de données : ${BOLD}${DB_NAME}${RESET}"
