#!/bin/bash
# =============================================================================
#  install_mail.sh — Serveur de messagerie complet
#  Auteur  : Laurent Lebarbier
#  Version : 2.0
# =============================================================================
#
#  Ce script installe et configure un serveur mail complet permettant
#  d'ENVOYER et de RECEVOIR des e-mails avec votre propre domaine.
#
#  Composants installés :
#    - Postfix      : MTA (Mail Transfer Agent) — gère l'envoi et la réception
#    - Dovecot      : MDA (Mail Delivery Agent) — stockage et accès IMAP/POP3
#    - OpenDKIM     : signe numériquement les mails sortants (anti-spam)
#    - SpamAssassin : filtre anti-spam
#    - Fail2Ban     : protection contre les attaques brute-force
#    - MariaDB      : stockage des comptes mail virtuels
#
#  Protocoles configurés :
#    - SMTP  (25)   : réception des mails depuis Internet
#    - SMTP  (587)  : envoi authentifié depuis vos clients mail (STARTTLS)
#    - IMAP  (993)  : lecture des mails via SSL/TLS  ← recommandé
#    - POP3  (995)  : téléchargement des mails via SSL/TLS
#
#  Après l'installation, configurez votre DNS chez votre hébergeur :
#    MX, SPF, DKIM, DMARC — les enregistrements sont affichés à la fin.
#
#  Testez l'envoi sur : https://mail-tester.com
#  Testez les ports   : https://mxtoolbox.com
#
#  Usage : sudo bash install_mail.sh
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

# Variables dérivées
readonly MAIL_HOSTNAME="mail.${DOMAIN}"
readonly VMAIL_DIR="/var/vmail"
readonly DKIM_DIR="/etc/dkimkeys/${DOMAIN}"

log STEP "Installation du serveur de messagerie"
log INFO "Domaine    : $DOMAIN"
log INFO "Hostname   : $MAIL_HOSTNAME"
log INFO "IP publique: $SERVER_IP"

# ---------------------------------------------------------------------------
# 1. Installation des paquets
# ---------------------------------------------------------------------------
log STEP "Installation des paquets mail"

# Préconfiguration de Postfix pour éviter le prompt interactif
debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
debconf-set-selections <<< "postfix postfix/mailname string ${MAIL_HOSTNAME}"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    postfix postfix-mysql \
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-mysql \
    opendkim opendkim-tools \
    spamassassin spamc \
    fail2ban \
    mariadb-server \
    openssl mailutils \
    certbot

log OK "Paquets installés."

# ---------------------------------------------------------------------------
# 2. Nom d'hôte
# ---------------------------------------------------------------------------
log STEP "Configuration du nom d'hôte"
hostnamectl set-hostname "$MAIL_HOSTNAME"
# Ajoute l'entrée dans /etc/hosts si absente
grep -q "$MAIL_HOSTNAME" /etc/hosts \
    || echo "$SERVER_IP $MAIL_HOSTNAME mail" >> /etc/hosts
log OK "Hostname : $MAIL_HOSTNAME"

# ---------------------------------------------------------------------------
# 3. Certificat SSL pour le serveur mail
# ---------------------------------------------------------------------------
log STEP "Certificat SSL pour $MAIL_HOSTNAME"
if [[ ! -d "/etc/letsencrypt/live/${MAIL_HOSTNAME}" ]]; then
    # Mode standalone : Apache est arrêté le temps de la validation (port 80).
    # Les hooks sont enregistrés par Certbot et rejoués à CHAQUE
    # renouvellement — sans eux, le renouvellement automatique échouait
    # (port 80 occupé par Apache) et le certificat expirait au bout de 90 jours.
    certbot certonly --standalone \
        --non-interactive --agree-tos \
        --email "$ADMIN_EMAIL" \
        --pre-hook  "systemctl stop apache2" \
        --post-hook "systemctl start apache2" \
        --deploy-hook "systemctl reload postfix dovecot" \
        -d "$MAIL_HOSTNAME" \
        && log OK "Certificat SSL obtenu pour $MAIL_HOSTNAME" \
        || { log WARN "Certbot a échoué (DNS pas encore sur ce serveur ?). Certificat auto-signé en attendant — relancez ensuite : restore_server.sh ssl"; }
    systemctl start apache2 2>/dev/null || true
else
    log INFO "Certificat déjà présent pour $MAIL_HOSTNAME."
fi

# Chemins des certificats (Let's Encrypt ou auto-signé en fallback)
if [[ -d "/etc/letsencrypt/live/${MAIL_HOSTNAME}" ]]; then
    SSL_CERT="/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"
else
    log WARN "Utilisation d'un certificat auto-signé (non recommandé en production)."
    SSL_CERT="/etc/ssl/certs/ssl-cert-snakeoil.pem"
    SSL_KEY="/etc/ssl/private/ssl-cert-snakeoil.key"
fi

# ---------------------------------------------------------------------------
# 4. Base de données vmail (comptes mail virtuels)
# ---------------------------------------------------------------------------
log STEP "Création de la base de données vmail"

# Mot de passe dédié pour l'utilisateur vmail (différent du DB_PASS général).
# Réutilisé depuis server.conf si déjà présent (ré-exécution du script) —
# sinon régénéré à chaque run alors que l'utilisateur MySQL existe déjà,
# "CREATE USER IF NOT EXISTS" ne mettant PAS à jour son mot de passe : les
# fichiers de config (Dovecot/Postfix) et la base finissaient désynchronisés.
if grep -q '^VMAIL_DB_PASS=' "$CONFIG_FILE"; then
    VMAIL_DB_PASS=$(grep '^VMAIL_DB_PASS=' "$CONFIG_FILE" | cut -d'"' -f2)
    log INFO "Mot de passe vmail existant réutilisé depuis server.conf."
else
    VMAIL_DB_PASS=$(openssl rand -base64 20 | tr -d '+/=' | head -c 24)
fi

mysql -e "CREATE DATABASE IF NOT EXISTS vmail CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS 'vmail'@'localhost' IDENTIFIED BY '${VMAIL_DB_PASS}';"
# Synchronise systématiquement le mot de passe (filet de sécurité si
# l'utilisateur existait déjà avec un mot de passe différent de celui
# qu'on est sur le point d'écrire dans les fichiers de config).
mysql -e "ALTER USER 'vmail'@'localhost' IDENTIFIED BY '${VMAIL_DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON vmail.* TO 'vmail'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Schéma de la base
mysql vmail <<SQL
-- Table des domaines virtuels
CREATE TABLE IF NOT EXISTS domains (
    id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    domain VARCHAR(100) NOT NULL UNIQUE,
    active TINYINT(1) NOT NULL DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Table des utilisateurs (boîtes mail)
CREATE TABLE IF NOT EXISTS users (
    id       INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    domain   VARCHAR(100) NOT NULL,
    email    VARCHAR(255) NOT NULL UNIQUE,
    password VARCHAR(255) NOT NULL,
    quota    INT UNSIGNED NOT NULL DEFAULT 0,   -- quota en octets, 0 = illimité
    active   TINYINT(1) NOT NULL DEFAULT 1,
    FOREIGN KEY (domain) REFERENCES domains(domain) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Table des alias (redirections)
CREATE TABLE IF NOT EXISTS aliases (
    id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    source      VARCHAR(255) NOT NULL UNIQUE,
    destination VARCHAR(255) NOT NULL,
    active      TINYINT(1) NOT NULL DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL

# Sauvegarde du mot de passe vmail dans server.conf
grep -q 'VMAIL_DB_PASS' "$CONFIG_FILE" \
    || echo "VMAIL_DB_PASS=\"${VMAIL_DB_PASS}\"" >> "$CONFIG_FILE"

log OK "Base de données vmail créée."

# ---------------------------------------------------------------------------
# 5. Utilisateur système vmail (stockage des boîtes)
# ---------------------------------------------------------------------------
log STEP "Création de l'utilisateur système vmail"
if ! id vmail &>/dev/null; then
    groupadd -g 5000 vmail
    useradd -g vmail -u 5000 -d "$VMAIL_DIR" -m -s /sbin/nologin vmail
fi
mkdir -p "$VMAIL_DIR"
chown -R vmail:vmail "$VMAIL_DIR"
chmod 770 "$VMAIL_DIR"
log OK "Utilisateur vmail prêt ($VMAIL_DIR)."

# ---------------------------------------------------------------------------
# 6. Configuration de Postfix
# ---------------------------------------------------------------------------
log STEP "Configuration de Postfix"

# Fichiers de connexion MySQL pour Postfix
mkdir -p /etc/postfix/mysql
chmod 750 /etc/postfix/mysql

# Connexion générique : factorisation dans une fonction
write_postfix_mysql_file() {
    local file="$1" query="$2"
    cat > "/etc/postfix/mysql/${file}" <<CONF
user     = vmail
password = ${VMAIL_DB_PASS}
hosts    = 127.0.0.1
dbname   = vmail
query    = ${query}
CONF
    chmod 640 "/etc/postfix/mysql/${file}"
}

write_postfix_mysql_file "virtual-domains.cf" \
    "SELECT 1 FROM domains WHERE domain='%s' AND active=1"

write_postfix_mysql_file "virtual-mailbox.cf" \
    "SELECT CONCAT(domain,'/',email,'/') FROM users WHERE email='%s' AND active=1"

write_postfix_mysql_file "virtual-alias.cf" \
    "SELECT destination FROM aliases WHERE source='%s' AND active=1"

# main.cf de Postfix
cat > /etc/postfix/main.cf <<MAINCF
# =======================================================
# Postfix — Configuration principale
# Domaine : ${DOMAIN}
# =======================================================

# Identité du serveur
smtpd_banner     = \$myhostname ESMTP
biff             = no
append_dot_mydomain = no
myhostname       = ${MAIL_HOSTNAME}
mydomain         = ${DOMAIN}
myorigin         = \$mydomain
inet_interfaces  = all
inet_protocols   = ipv4

# Ce serveur est destination finale pour localhost uniquement
# (le reste est géré par les tables virtuelles)
mydestination    = \$myhostname, localhost.\$mydomain, localhost

# Domaines et boîtes virtuelles (lus depuis MariaDB)
virtual_mailbox_domains = mysql:/etc/postfix/mysql/virtual-domains.cf
virtual_mailbox_maps    = mysql:/etc/postfix/mysql/virtual-mailbox.cf
virtual_alias_maps      = mysql:/etc/postfix/mysql/virtual-alias.cf
virtual_mailbox_base    = ${VMAIL_DIR}
virtual_uid_maps        = static:5000
virtual_gid_maps        = static:5000

# Livraison via Dovecot LMTP (plus robuste que virtual_transport direct)
virtual_transport = lmtp:unix:private/dovecot-lmtp

# Authentification SASL via Dovecot (pour l'envoi authentifié port 587)
smtpd_sasl_type          = dovecot
smtpd_sasl_path          = private/auth
smtpd_sasl_auth_enable   = yes
smtpd_sasl_security_options = noanonymous
broken_sasl_auth_clients = yes

# Restrictions de relais : on accepte localhost et les utilisateurs authentifiés
smtpd_relay_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    defer_unauth_destination

# Restrictions sur les connexions SMTP entrantes
smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination,
    reject_invalid_hostname,
    reject_non_fqdn_hostname,
    reject_non_fqdn_sender,
    reject_non_fqdn_recipient,
    reject_unknown_recipient_domain,
    reject_rbl_client zen.spamhaus.org,
    reject_rbl_client bl.spamcop.net

# TLS entrant (STARTTLS sur port 25 et 587)
smtpd_tls_security_level  = may
smtpd_tls_cert_file       = ${SSL_CERT}
smtpd_tls_key_file        = ${SSL_KEY}
smtpd_tls_auth_only       = yes
smtpd_tls_protocols       = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_loglevel        = 1

# TLS sortant (vers d'autres serveurs)
smtp_tls_security_level   = may
smtp_tls_loglevel         = 1
smtp_tls_protocols        = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1

# Signature DKIM via OpenDKIM
milter_default_action = accept
milter_protocol       = 6
smtpd_milters         = inet:localhost:8891
non_smtpd_milters     = inet:localhost:8891

# Taille max des messages : 50 Mo
message_size_limit = 52428800
# Boîtes illimitées — sans ce réglage explicite, Postfix garde sa valeur par
# défaut (51 200 000 octets), plus petite que message_size_limit ci-dessus,
# ce qui fait planter l'agent local ("mailbox_size_limit is smaller than
# message_size_limit") à chaque tentative de livraison locale.
mailbox_size_limit = 0

# File d'attente
queue_directory = /var/spool/postfix
MAINCF

# master.cf : activation du port 587 (submission) avec STARTTLS obligatoire
cat > /etc/postfix/master.cf <<MASTERCF
# =======================================================
# Postfix — Services (master.cf)
# =======================================================
# Port 25 : réception SMTP depuis Internet
smtp      inet  n       -       y       -       -       smtpd

# Port 587 : envoi authentifié depuis les clients mail
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# Services internes
pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
  -o syslog_name=postfix/relay
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
MASTERCF

log OK "Postfix configuré."

# ---------------------------------------------------------------------------
# 7. Configuration de Dovecot
# ---------------------------------------------------------------------------
log STEP "Configuration de Dovecot (IMAP/POP3)"

# Protocoles activés
# IMPORTANT : !include conf.d/*.conf est indispensable — sans cette ligne,
# aucun fichier de conf.d/ n'est chargé (auth-sql, mail, ssl, master...),
# ce qui provoque l'erreur Dovecot "No passdbs specified in configuration
# file" au démarrage du service auth.
cat > /etc/dovecot/dovecot.conf <<CONF
# Dovecot — Configuration principale
protocols = imap pop3 lmtp
listen    = *, ::
!include conf.d/*.conf
CONF

# Emplacement des mails (format Maildir)
cat > /etc/dovecot/conf.d/10-mail.conf <<CONF
# Format Maildir : un fichier par mail, compatible avec tous les clients
mail_location = maildir:${VMAIL_DIR}/%d/%n
mail_uid      = 5000
mail_gid      = 5000
mail_privileged_group = vmail

# Namespace INBOX — indispensable : sans lui Dovecot refuse toute connexion
# IMAP avec l'erreur "namespace configuration error: inbox=yes namespace
# missing" (ce bloc existe par défaut dans le fichier fourni par le paquet
# Dovecot, mais on écrase tout le fichier ci-dessus).
namespace inbox {
    type      = private
    inbox     = yes
    separator = /
}
CONF

# Authentification
cat > /etc/dovecot/conf.d/10-auth.conf <<CONF
# Désactiver l'authentification en clair sans TLS
disable_plaintext_auth = yes
auth_mechanisms = plain login

# Utiliser la base SQL pour l'authentification
!include auth-sql.conf.ext
CONF

cat > /etc/dovecot/conf.d/auth-sql.conf.ext <<CONF
passdb {
    driver = sql
    args   = /etc/dovecot/dovecot-sql.conf.ext
}
userdb {
    driver = static
    args   = uid=vmail gid=vmail home=${VMAIL_DIR}/%d/%n
}
CONF

cat > /etc/dovecot/dovecot-sql.conf.ext <<CONF
driver          = mysql
connect         = host=127.0.0.1 dbname=vmail user=vmail password=${VMAIL_DB_PASS}
default_pass_scheme = SHA512-CRYPT
password_query  = SELECT email AS user, password FROM users WHERE email='%u' AND active=1
CONF
chmod 600 /etc/dovecot/dovecot-sql.conf.ext

# SSL/TLS
cat > /etc/dovecot/conf.d/10-ssl.conf <<CONF
ssl          = required
ssl_cert     = <${SSL_CERT}
ssl_key      = <${SSL_KEY}
ssl_min_protocol = TLSv1.2
ssl_cipher_list  = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
CONF

# LMTP (livraison depuis Postfix)
cat > /etc/dovecot/conf.d/20-lmtp.conf <<CONF
protocol lmtp {
    postmaster_address = ${ADMIN_EMAIL}
}
CONF

# Socket d'authentification partagé avec Postfix
cat > /etc/dovecot/conf.d/10-master.conf <<CONF
service imap-login {
    inet_listener imap {
        port = 0             # IMAP non-TLS désactivé
    }
    inet_listener imaps {
        port = 993           # IMAPS (TLS)
    }
}
service pop3-login {
    inet_listener pop3 {
        port = 0             # POP3 non-TLS désactivé
    }
    inet_listener pop3s {
        port = 995           # POP3S (TLS)
    }
}
service lmtp {
    unix_listener /var/spool/postfix/private/dovecot-lmtp {
        mode  = 0600
        user  = postfix
        group = postfix
    }
}
service auth {
    unix_listener /var/spool/postfix/private/auth {
        mode  = 0660
        user  = postfix
        group = postfix
    }
    unix_listener auth-userdb {
        mode  = 0600
        user  = vmail
    }
}
service auth-worker {
    user = vmail
}
CONF

log OK "Dovecot configuré."

# ---------------------------------------------------------------------------
# 8. OpenDKIM — Signature des mails sortants
# ---------------------------------------------------------------------------
log STEP "Configuration d'OpenDKIM (signature DKIM)"

mkdir -p "$DKIM_DIR"

# Génération de la paire de clés DKIM (sélecteur : "mail")
if [[ ! -f "${DKIM_DIR}/mail.private" ]]; then
    opendkim-genkey -D "$DKIM_DIR" -d "$DOMAIN" -s mail
    chown -R opendkim:opendkim "$DKIM_DIR"
    chmod 700 "$DKIM_DIR"
    chmod 600 "${DKIM_DIR}/mail.private"
    log OK "Clés DKIM générées dans $DKIM_DIR"
else
    log INFO "Clés DKIM déjà présentes."
fi

# Configuration principale d'OpenDKIM
cat > /etc/opendkim.conf <<CONF
# OpenDKIM — Configuration
Domain                  ${DOMAIN}
KeyFile                 ${DKIM_DIR}/mail.private
Selector                mail
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
UserID                  opendkim:opendkim
UMask                   007
LogWhy                  yes
Syslog                  yes
SyslogSuccess           yes
Mode                    sv
SubDomains              no
AutoRestart             yes
AutoRestartRate         10/1M
Background              yes

# Tables
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/TrustedHosts
CONF

mkdir -p /etc/opendkim

cat > /etc/opendkim/KeyTable <<TABLE
mail._domainkey.${DOMAIN} ${DOMAIN}:mail:${DKIM_DIR}/mail.private
TABLE

cat > /etc/opendkim/SigningTable <<TABLE
*@${DOMAIN} mail._domainkey.${DOMAIN}
TABLE

cat > /etc/opendkim/TrustedHosts <<HOSTS
127.0.0.1
localhost
${DOMAIN}
mail.${DOMAIN}
HOSTS

# Socket dans /etc/default/opendkim
sed -i 's|^SOCKET=.*|SOCKET="inet:8891@localhost"|' /etc/default/opendkim 2>/dev/null || \
    echo 'SOCKET="inet:8891@localhost"' >> /etc/default/opendkim

# /run/opendkim (tmpfs) doit exister pour que le PidFile soit accessible.
# Sans ceci, systemd (service de type "forking") ne trouve jamais le PID
# et l'unité part en timeout après ~90s, même si le démon tourne bien.
mkdir -p /run/opendkim
chown opendkim:opendkim /run/opendkim
cat > /etc/tmpfiles.d/opendkim.conf <<TMPFILES
d /run/opendkim 0750 opendkim opendkim -
TMPFILES
systemd-tmpfiles --create /etc/tmpfiles.d/opendkim.conf

log OK "OpenDKIM configuré."

# ---------------------------------------------------------------------------
# 9. Fail2Ban — Protection contre les attaques brute-force
# ---------------------------------------------------------------------------
log STEP "Configuration de Fail2Ban"

cat > /etc/fail2ban/jail.d/mail.conf <<CONF
[postfix]
enabled  = true
port     = smtp,465,submission
logpath  = /var/log/mail.log
maxretry = 5
bantime  = 3600

[dovecot]
enabled  = true
port     = imap3,imaps,pop3,pop3s
logpath  = /var/log/mail.log
maxretry = 5
bantime  = 3600
CONF

systemctl enable --now fail2ban
log OK "Fail2Ban configuré pour Postfix et Dovecot."

# ---------------------------------------------------------------------------
# 10. Ajout du domaine et d'un premier compte mail
# ---------------------------------------------------------------------------
log STEP "Création du premier compte mail"

# Insertion du domaine
mysql vmail -e "INSERT IGNORE INTO domains (domain) VALUES ('${DOMAIN}');"

# Hachage du mot de passe avec doveadm
MAIL_PASS_HASH=$(doveadm pw -s SHA512-CRYPT -p "${SYS_PASS}")

# Compte admin@domaine
mysql vmail -e "INSERT IGNORE INTO users (domain, email, password) \
    VALUES ('${DOMAIN}', 'admin@${DOMAIN}', '${MAIL_PASS_HASH}');"

# Alias postmaster → admin (requis par les RFC)
mysql vmail -e "INSERT IGNORE INTO aliases (source, destination) \
    VALUES ('postmaster@${DOMAIN}', 'admin@${DOMAIN}');"

log OK "Compte mail créé : admin@${DOMAIN}"

# ---------------------------------------------------------------------------
# 11. Démarrage des services
# ---------------------------------------------------------------------------
log STEP "Démarrage des services mail"
systemctl enable --now postfix dovecot opendkim
systemctl restart postfix dovecot opendkim fail2ban
log OK "Services démarrés."

# ---------------------------------------------------------------------------
# 12. Enregistrements DNS à configurer chez OVH / hébergeur
# ---------------------------------------------------------------------------
DKIM_TXT=$(grep -v '^;' "${DKIM_DIR}/mail.txt" | tr -d '\n' | sed 's/\s\+/ /g' | \
           sed 's/.*(\(.*\))/\1/' | tr -d '"' | tr -d ' ')

log STEP "Enregistrements DNS à ajouter chez votre hébergeur (OVH, etc.)"
echo -e "\n${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║   Enregistrements DNS pour : ${DOMAIN}"
printf "  ║%-68s║\n" ""
echo "  ║  A     : mail          → ${SERVER_IP}"
echo "  ║  MX    : @             → 10 mail.${DOMAIN}."
echo "  ║  TXT   : @             → \"v=spf1 mx ip4:${SERVER_IP} ~all\""
echo "  ║  TXT   : mail._domainkey → (voir ci-dessous)"
echo "  ║  TXT   : _dmarc        → \"v=DMARC1; p=quarantine; rua=mailto:${ADMIN_EMAIL}\""
echo "  ║  PTR   : ${SERVER_IP}   → mail.${DOMAIN}  (à configurer chez OVH)"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "  ${BOLD}Enregistrement DKIM complet :${RESET}"
echo    "  Nom  : mail._domainkey.${DOMAIN}"
echo    "  Type : TXT"
echo    "  Valeur : $(cat "${DKIM_DIR}/mail.txt" | grep -v '^;')"

echo -e "\n  ${YELLOW}⚠  Attendez la propagation DNS (quelques minutes à 48h) avant d'envoyer.${RESET}"
echo -e "  ${GREEN}✉  Testez votre score : https://mail-tester.com${RESET}"
echo -e "  ${GREEN}🔍 Vérifiez vos ports  : https://mxtoolbox.com/SuperTool.aspx${RESET}"

# ---------------------------------------------------------------------------
# Récapitulatif
# ---------------------------------------------------------------------------
log STEP "Serveur mail configuré"
echo -e "  Compte mail   : ${GREEN}admin@${DOMAIN}${RESET}"
echo -e "  Mot de passe  : ${YELLOW}(même que le compte système $SYS_USER)${RESET}"
echo -e "  IMAP (SSL)    : ${BOLD}mail.${DOMAIN}:993${RESET}"
echo -e "  SMTP (STARTTLS): ${BOLD}mail.${DOMAIN}:587${RESET}"
echo -e "  Logs mail     : ${BOLD}sudo tail -f /var/log/mail.log${RESET}"
echo
echo -e "  ${CYAN}Pour ajouter des comptes mail :${RESET}"
echo -e "  ${BOLD}sudo bash $(dirname "$0")/manage_mail.sh${RESET}   (ou option [9] du menu install.sh)"
