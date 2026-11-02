#!/bin/bash
# =============================================================================
#  restore_server.sh — Restauration d'une sauvegarde de backup_server.sh
#  Auteur  : Laurent Lebarbier
#  Version : 1.0
# =============================================================================
#
#  Migration vers un nouveau serveur (ou réinstallation) en 3 commandes :
#
#    1) sudo bash restore_server.sh prepare <archive>
#         → remet server.conf (mêmes mots de passe, mêmes clés OVH) et met
#           à jour l'IP. À faire AVANT install.sh, pour que les scripts
#           réutilisent les mêmes mots de passe que l'ancien serveur.
#
#    2) sudo bash install.sh
#         → répondre « n » à « Reconfigurer depuis zéro ? »
#         → menu [5] Installation complète  (PAS WordPress : il est restauré)
#
#    3) sudo bash restore_server.sh <archive>
#         → bases + comptes MariaDB, mails, clé DKIM, sites, FTP, cron
#         → DNS OVH (install_dns_ovh.sh), sous-domaines, certificats SSL
#
#  Commande séparée, si les certificats n'ont pas pu être obtenus (DNS pas
#  encore propagé) :
#    sudo bash restore_server.sh ssl
#
#  Options (étape 3) : --skip-dns  --skip-ssl  -y (sans confirmation)
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
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') — restore_server — $*" >> /var/log/install_server.log 2>/dev/null || true
}

ASSUME_YES=0
confirm() {
    [[ "$ASSUME_YES" == 1 ]] && return 0
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

# ---------------------------------------------------------------------------
# Lecture de l'archive (chiffrée ou non)
# ---------------------------------------------------------------------------
PASSPHRASE=""
is_encrypted() { [[ "$(head -c 8 "$1")" == "Salted__" ]]; }

ask_passphrase() {
    local archive="$1"
    is_encrypted "$archive" || return 0
    while true; do
        read -rsp "$(echo -e "  ${CYAN}Mot de passe de l'archive : ${RESET}")" PASSPHRASE; echo
        # Test rapide : avec le bon mot de passe, le flux déchiffré commence
        # par la signature gzip (1f 8b)
        local magic
        magic=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 -in "$archive" 3<<< "$PASSPHRASE" 2>/dev/null \
                | head -c 2 | od -An -tx1 | tr -d ' \n' || true)
        [[ "$magic" == "1f8b" ]] && return 0
        log WARN "Mot de passe incorrect, réessayez."
    done
}

# extract ARCHIVE DEST [membres…]
extract() {
    local archive="$1" dest="$2"; shift 2
    if is_encrypted "$archive"; then
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 -in "$archive" 3<<< "$PASSPHRASE" \
            | tar -xzf - -C "$dest" "$@"
    else
        tar -xzf "$archive" -C "$dest" "$@"
    fi
}

check_archive() {
    local archive="$1"
    [[ -f "$archive" ]] || { log ERROR "Archive introuvable : ${archive}"; exit 1; }
    if [[ -f "${archive}.sha256" ]]; then
        (cd "$(dirname "$archive")" && sha256sum -c --status "$(basename "$archive").sha256") \
            && log OK "Empreinte SHA-256 correcte." \
            || { log ERROR "Empreinte SHA-256 différente : archive corrompue ou incomplète."; exit 1; }
    fi
}

# Copie le contenu d'un dossier en conservant droits et propriétaires
copy_tree() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 0
    mkdir -p "$dst"
    if command -v rsync &>/dev/null; then
        rsync -a "${src}/" "${dst}/"
    else
        cp -a "${src}/." "${dst}/"
    fi
}

detect_ip() { curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# ÉTAPE 1 — prepare : remet server.conf avant install.sh
# ---------------------------------------------------------------------------
cmd_prepare() {
    local archive="${1:?Usage : $0 prepare <archive>}"
    check_archive "$archive"
    ask_passphrase "$archive"

    log STEP "Récupération de server.conf"
    local tmp; tmp=$(mktemp -d); chmod 700 "$tmp"
    extract "$archive" "$tmp" meta/server.conf meta/info.txt
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        log INFO "server.conf existant sauvegardé (.bak)."
    fi
    cp "$tmp/meta/server.conf" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log OK "server.conf restauré (sauvegarde du $(grep '^date=' "$tmp/meta/info.txt" | cut -d= -f2))."
    rm -rf "$tmp"

    # Nouvelle IP
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    local new_ip; new_ip=$(detect_ip)
    echo -e "\n  Ancienne IP : ${BOLD}${SERVER_IP:-?}${RESET}"
    read -rp "$(echo -e "  ${CYAN}IP publique de CE serveur [${new_ip}] : ${RESET}")" ip
    ip="${ip:-$new_ip}"
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        sed -i "s|^SERVER_IP=.*|SERVER_IP=\"${ip}\"|" "$CONFIG_FILE"
        log OK "SERVER_IP = ${ip}"
    else
        log WARN "IP invalide — modifiez SERVER_IP dans server.conf à la main."
    fi

    log STEP "Étape suivante"
    echo -e "  1. ${BOLD}sudo bash ${SCRIPT_DIR}/install.sh${RESET}"
    echo -e "     → « Reconfigurer depuis zéro ? » : ${BOLD}n${RESET}"
    echo -e "     → menu ${BOLD}[5]${RESET} Installation complète (pas WordPress, il sera restauré)"
    echo -e "  2. ${BOLD}sudo bash ${SCRIPT_DIR}/restore_server.sh ${archive}${RESET}"
}

# ---------------------------------------------------------------------------
# Certificats SSL (aussi utilisable seul : restore_server.sh ssl)
# ---------------------------------------------------------------------------

# Ajoute au certificat mail.<domaine> (obtenu en mode standalone) les hooks
# qui arrêtent Apache le temps du renouvellement — sans eux, le
# renouvellement automatique échoue (port 80 occupé) au bout de 90 jours.
fix_mail_renewal() {
    local conf="/etc/letsencrypt/renewal/mail.${DOMAIN}.conf"
    [[ -f "$conf" ]] || return 0
    grep -q '^authenticator *= *standalone' "$conf" || return 0
    grep -q '^pre_hook' "$conf" || sed -i '/^\[renewalparams\]/a pre_hook = systemctl stop apache2' "$conf"
    grep -q '^post_hook' "$conf" || sed -i '/^\[renewalparams\]/a post_hook = systemctl start apache2' "$conf"
    grep -q '^renew_hook' "$conf" || sed -i '/^\[renewalparams\]/a renew_hook = systemctl reload postfix dovecot' "$conf"
}

cmd_ssl() {
    [[ -f "$CONFIG_FILE" ]] || { log ERROR "server.conf introuvable."; exit 1; }
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    command -v certbot &>/dev/null || apt-get install -y -qq certbot python3-certbot-apache
    local le="/etc/letsencrypt/live" failed=0

    log STEP "Certificats SSL"

    # Domaine principal + www
    if [[ ! -d "${le}/${DOMAIN}" ]]; then
        certbot --apache --non-interactive --agree-tos --email "$ADMIN_EMAIL" \
            --cert-name "$DOMAIN" -d "$DOMAIN" -d "www.${DOMAIN}" --redirect \
            && log OK "HTTPS : ${DOMAIN}" || { log WARN "Échec pour ${DOMAIN}"; failed=1; }
    else
        log INFO "Certificat déjà présent : ${DOMAIN}"
    fi

    # mail.<domaine> (Postfix / Dovecot)
    if [[ ! -d "${le}/mail.${DOMAIN}" ]]; then
        certbot certonly --standalone --non-interactive --agree-tos --email "$ADMIN_EMAIL" \
            --pre-hook "systemctl stop apache2" --post-hook "systemctl start apache2" \
            --deploy-hook "systemctl reload postfix dovecot" \
            -d "mail.${DOMAIN}" \
            && log OK "Certificat : mail.${DOMAIN}" || { log WARN "Échec pour mail.${DOMAIN}"; failed=1; }
    fi
    fix_mail_renewal

    # Remplace le certificat auto-signé (posé par install_mail.sh si le DNS
    # ne pointait pas encore ici) par celui de Let's Encrypt
    if [[ -d "${le}/mail.${DOMAIN}" ]]; then
        local cert="${le}/mail.${DOMAIN}/fullchain.pem" key="${le}/mail.${DOMAIN}/privkey.pem"
        if grep -q 'snakeoil' /etc/postfix/main.cf 2>/dev/null; then
            sed -i -e "s|^smtpd_tls_cert_file *=.*|smtpd_tls_cert_file       = ${cert}|" \
                   -e "s|^smtpd_tls_key_file *=.*|smtpd_tls_key_file        = ${key}|" /etc/postfix/main.cf
            systemctl reload postfix
            log OK "Postfix utilise le certificat Let's Encrypt."
        fi
        if grep -q 'snakeoil' /etc/dovecot/conf.d/10-ssl.conf 2>/dev/null; then
            sed -i -e "s|^ssl_cert *=.*|ssl_cert     = <${cert}|" \
                   -e "s|^ssl_key *=.*|ssl_key      = <${key}|" /etc/dovecot/conf.d/10-ssl.conf
            systemctl reload dovecot
            log OK "Dovecot utilise le certificat Let's Encrypt."
        fi
    fi

    # FTP (Pure-FTPd utilise le certificat du domaine principal)
    if [[ -d "${le}/${DOMAIN}" && -d /etc/pure-ftpd ]]; then
        cat "${le}/${DOMAIN}/fullchain.pem" "${le}/${DOMAIN}/privkey.pem" > /etc/ssl/private/pure-ftpd.pem
        chmod 600 /etc/ssl/private/pure-ftpd.pem
        systemctl restart pure-ftpd 2>/dev/null || true
    fi

    # Sous-domaines sans certificat
    local conf fqdn
    for conf in /etc/apache2/sites-available/*."${DOMAIN}".conf; do
        [[ -f "$conf" && "$conf" != *-le-ssl.conf ]] || continue
        grep -q '^# Géré par manage_subdomains.sh' "$conf" || continue
        fqdn=$(basename "$conf" .conf)
        [[ -d "${le}/${fqdn}" ]] && continue
        bash "${SCRIPT_DIR}/manage_subdomains.sh" ssl "${fqdn%."${DOMAIN}"}" -y || failed=1
    done

    if [[ "$failed" == 1 ]]; then
        log WARN "Certains certificats manquent : le DNS ne pointe sans doute pas encore ici."
        log WARN "Relancez plus tard : sudo bash $0 ssl"
        return 1
    fi
    log OK "Tous les certificats sont en place."
}

# ---------------------------------------------------------------------------
# ÉTAPE 3 — restauration complète
# ---------------------------------------------------------------------------
cmd_restore() {
    local archive="$1"
    [[ -f "$CONFIG_FILE" ]] || { log ERROR "server.conf absent : lancez d'abord « $0 prepare ${archive} » puis install.sh."; exit 1; }
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    check_archive "$archive"
    ask_passphrase "$archive"

    local STAGE; STAGE="/root/restore_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$STAGE"; chmod 700 "$STAGE"
    log STEP "Extraction de l'archive dans ${STAGE}"
    extract "$archive" "$STAGE"
    log OK "Archive extraite ($(du -sh "$STAGE" | cut -f1))."

    # Garde-fous
    local bdomain; bdomain=$(grep '^domain=' "$STAGE/meta/info.txt" | cut -d= -f2)
    if [[ "$bdomain" != "$DOMAIN" ]]; then
        log ERROR "Cette sauvegarde est celle de ${bdomain}, ce serveur est configuré pour ${DOMAIN}."
        exit 1
    fi
    local vpass_old vpass_new
    vpass_old=$(grep '^VMAIL_DB_PASS=' "$STAGE/meta/server.conf" | cut -d'"' -f2 || true)
    vpass_new="${VMAIL_DB_PASS:-}"
    if [[ -n "$vpass_old" && "$vpass_old" != "$vpass_new" ]]; then
        log WARN "server.conf ne vient pas de cette sauvegarde (« prepare » non lancé ?)."
        log WARN "Les mots de passe des bases ne correspondront pas forcément aux sites restaurés."
        confirm "Continuer quand même ?" || exit 1
    fi
    local has_mysql=0 has_mail=0 has_apache=0
    mysql -e "SELECT 1" &>/dev/null && has_mysql=1
    id vmail &>/dev/null && has_mail=1
    command -v apache2ctl &>/dev/null && has_apache=1
    (( has_mysql ))  || log WARN "MariaDB absent : bases ignorées (install_lamp.sh lancé ?)."
    (( has_mail ))   || log WARN "Serveur mail absent : mails et DKIM ignorés (install_mail.sh lancé ?)."
    (( has_apache )) || log WARN "Apache absent : sous-domaines ignorés."

    echo -e "\n  ${BOLD}Restauration de ${DOMAIN}${RESET} (sauvegarde du $(grep '^date=' "$STAGE/meta/info.txt" | cut -d= -f2))"
    echo -e "  ${YELLOW}Les données actuelles de ce serveur (bases, mails, sites) seront remplacées.${RESET}"
    confirm "Lancer la restauration ?" || exit 0

    # --- 1. Bases de données --------------------------------------------------
    if (( has_mysql )) && compgen -G "$STAGE/db/*.sql" >/dev/null; then
        log STEP "Bases de données"
        local f db
        for f in "$STAGE"/db/*.sql; do
            db=$(basename "$f" .sql)
            [[ "$db" == "users" ]] && continue
            if [[ "$db" == "vmail" ]] && (( ! has_mail )); then continue; fi
            mysql -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
            mysql "$db" < "$f"
            log OK "Base ${db}"
        done
        if [[ -s "$STAGE/db/users.sql" ]]; then
            mysql < "$STAGE/db/users.sql"
            mysql -e "FLUSH PRIVILEGES"
            log OK "Comptes MariaDB et droits restaurés."
        fi
    fi

    # --- 2. Mails + DKIM -------------------------------------------------------
    if (( has_mail )); then
        log STEP "Mails et clé DKIM"
        copy_tree "$STAGE/var/vmail" /var/vmail
        chown -R vmail:vmail /var/vmail
        log OK "Boîtes mail restaurées ($(du -sh /var/vmail | cut -f1))."
        if [[ -d "$STAGE/etc/dkimkeys" ]]; then
            copy_tree "$STAGE/etc/dkimkeys" /etc/dkimkeys
            copy_tree "$STAGE/etc/opendkim" /etc/opendkim
            chown -R opendkim:opendkim /etc/dkimkeys
            find /etc/dkimkeys -name '*.private' -exec chmod 600 {} +
            log OK "Clé DKIM d'origine restaurée (l'enregistrement DNS DKIM ne change pas)."
        fi
        systemctl restart opendkim dovecot postfix || log WARN "Redémarrage des services mail à vérifier."
    fi

    # --- 3. Sites ---------------------------------------------------------------
    if [[ -d "$STAGE/var/www" ]]; then
        log STEP "Sites web"
        copy_tree "$STAGE/var/www" /var/www
        log OK "/var/www restauré ($(du -sh /var/www | cut -f1))."
    fi

    # --- 3bis. Serveur cloud : Immich + données (si incluses) --------------------
    local immich_dump=""
    if [[ -d "$STAGE/opt/immich" ]]; then
        log STEP "Immich (configuration)"
        copy_tree "$STAGE/opt/immich" /opt/immich
        chmod 600 /opt/immich/.env 2>/dev/null || true
        log OK "/opt/immich restauré (docker-compose.yml + .env)."
    fi
    if [[ -f "$STAGE/db/immich.sql.gz" ]]; then
        immich_dump="/root/immich_db_$(grep '^date=' "$STAGE/meta/info.txt" | cut -d= -f2 | tr -d ' :-').sql.gz"
        cp "$STAGE/db/immich.sql.gz" "$immich_dump"; chmod 600 "$immich_dump"
        log OK "Sauvegarde de la base Immich copiée : ${immich_dump} (restauration : voir bilan)."
    fi
    local d
    for d in srv/nextcloud srv/immich/library; do
        if [[ -d "$STAGE/$d" ]]; then
            log STEP "Données /${d}"
            copy_tree "$STAGE/$d" "/$d"
            log OK "/${d} restauré ($(du -sh "/$d" | cut -f1))."
        fi
    done
    [[ -d /srv/nextcloud ]] && chown -R www-data:www-data /srv/nextcloud

    # --- 4. FTP -----------------------------------------------------------------
    if [[ -d "$STAGE/home/ftpusers" ]]; then
        log STEP "FTP"
        copy_tree "$STAGE/home/ftpusers" /home/ftpusers
        local ftp_user="${SYS_USER}_ftp"
        if [[ -f "$STAGE/meta/pureftpd.passwd" && -f /etc/pure-ftpd/pureftpd.passwd ]] && command -v pure-pw &>/dev/null; then
            local old_hash
            old_hash=$(awk -F: -v u="$ftp_user" '$1==u {print $2}' "$STAGE/meta/pureftpd.passwd")
            if [[ -n "$old_hash" ]] && grep -q "^${ftp_user}:" /etc/pure-ftpd/pureftpd.passwd; then
                awk -F: -v OFS=: -v u="$ftp_user" -v h="$old_hash" '$1==u {$2=h} {print}' \
                    /etc/pure-ftpd/pureftpd.passwd > /etc/pure-ftpd/pureftpd.passwd.new
                mv /etc/pure-ftpd/pureftpd.passwd.new /etc/pure-ftpd/pureftpd.passwd
                chmod 600 /etc/pure-ftpd/pureftpd.passwd
                pure-pw mkdb >/dev/null
                log OK "Mot de passe FTP d'origine restauré pour ${ftp_user}."
            fi
        fi
        log OK "Fichiers FTP restaurés."
    fi

    # --- 5. Crontabs --------------------------------------------------------------
    if [[ -f "$STAGE/meta/crontab.root" ]] && ! crontab -l -u root &>/dev/null; then
        crontab -u root "$STAGE/meta/crontab.root" && log OK "Crontab root restaurée."
    fi
    if [[ -f "$STAGE/meta/crontab.user" && -n "${SYS_USER:-}" ]] && id "$SYS_USER" &>/dev/null \
            && ! crontab -l -u "$SYS_USER" &>/dev/null; then
        crontab -u "$SYS_USER" "$STAGE/meta/crontab.user" && log OK "Crontab ${SYS_USER} restaurée."
    fi

    (( has_apache )) && systemctl reload apache2 || true

    # --- 6. DNS OVH ---------------------------------------------------------------
    if [[ "$SKIP_DNS" != 1 && "${SERVER_ROLE:-web}" == "cloud" ]]; then
        log STEP "DNS"
        log INFO "Rôle cloud : la zone n'est PAS remise à zéro (elle appartient au serveur web)."
        log INFO "Les sous-domaines ci-dessous sont recréés un par un (A → ${SERVER_IP})."
    elif [[ "$SKIP_DNS" != 1 ]]; then
        log STEP "DNS"
        if [[ -n "${OVH_APP_KEY:-}" && -n "${OVH_CONSUMER_KEY:-}" ]]; then
            echo -e "  Les clés API OVH sont dans server.conf : la zone peut être mise à jour"
            echo -e "  avec la nouvelle IP ${BOLD}${SERVER_IP}${RESET} et la clé DKIM restaurée."
            echo -e "  ${YELLOW}⚠  install_dns_ovh.sh remet TOUTE la zone à zéro (sauvegarde JSON faite avant) ;${RESET}"
            echo -e "  ${YELLOW}   les sous-domaines sont recréés juste après par ce script.${RESET}"
            if confirm "Lancer install_dns_ovh.sh maintenant ?"; then
                bash "${SCRIPT_DIR}/install_dns_ovh.sh" || log WARN "install_dns_ovh.sh a échoué — à relancer à la main."
            fi
        else
            log WARN "Pas de clés API OVH dans server.conf : changez l'IP à la main chez votre registrar :"
            echo -e "     @, www, mail (A) → ${BOLD}${SERVER_IP}${RESET}   SPF : ip4:${SERVER_IP}"
            echo -e "     DKIM : inchangé (clé d'origine restaurée)"
        fi
    fi

    # --- 7. Sous-domaines ---------------------------------------------------------
    if (( has_apache )) && [[ -s "$STAGE/meta/subdomains.txt" ]]; then
        log STEP "Sous-domaines"
        local line sub type target opts
        while IFS= read -r line; do
            IFS='|' read -r sub type target <<< "$line"
            [[ -z "$sub" ]] && continue
            if [[ -f "/etc/apache2/sites-available/${sub}.${DOMAIN}.conf" ]]; then
                log INFO "${sub}.${DOMAIN} existe déjà."; continue
            fi
            opts=(-y)
            [[ "$type" == "proxy" ]] && opts+=(--proxy "$target")
            [[ "$SKIP_DNS" == 1 ]] && opts+=(--no-dns)
            [[ "$SKIP_SSL" == 1 ]] && opts+=(--no-ssl)
            bash "${SCRIPT_DIR}/manage_subdomains.sh" add "$sub" "${opts[@]}" || log WARN "Échec pour ${sub}"
        done < "$STAGE/meta/subdomains.txt"
    fi

    # VirtualHosts écrits à la main sur l'ancien serveur : non recréés
    local manual=() c n
    if [[ -d "$STAGE/meta/apache-sites" ]]; then
        for c in "$STAGE"/meta/apache-sites/*.conf; do
            [[ -f "$c" ]] || continue
            n=$(basename "$c")
            case "$n" in 000-default.conf|default-ssl.conf|"${DOMAIN}.conf"|*-le-ssl.conf) continue ;; esac
            grep -q '^# Géré par manage_subdomains.sh' "$c" && continue
            manual+=("$n")
        done
    fi

    # --- 8. Certificats -----------------------------------------------------------
    local ssl_ok=1
    if [[ "$SKIP_SSL" != 1 ]]; then
        cmd_ssl || ssl_ok=0
    fi

    # --- Bilan --------------------------------------------------------------------
    log STEP "Restauration terminée"
    echo -e "  ${BOLD}À faire :${RESET}"
    if [[ "${SERVER_ROLE:-web}" != "web" ]]; then
        (( ssl_ok )) || echo -e "  • Certificats : ${BOLD}sudo bash $0 ssl${RESET} une fois le DNS propagé"
        echo -e "  • Réappliquer les réglages Nextcloud / Immich (VirtualHosts, cron, cache) :"
        echo -e "      ${BOLD}sudo bash ${SCRIPT_DIR}/install_cloud.sh tout${RESET}"
        echo -e "  • Si les données Nextcloud ont été recopiées à la main dans /srv/nextcloud :"
        echo -e "      ${BOLD}sudo -u www-data php /var/www/${NC_SUB:-cloud}.${DOMAIN}/public_html/occ files:scan --all${RESET}"
        if [[ -n "$immich_dump" ]]; then
            echo -e "  • Base Immich (albums, visages, utilisateurs) — à faire UNE fois, Immich démarré :"
            echo -e "      cd /opt/immich && docker compose down"
            echo -e "      rm -rf ${IMMICH_DATA:-/srv/immich}/postgres      # base vide (les photos ne sont PAS touchées)"
            echo -e "      docker compose create"
            echo -e "      docker start immich_postgres && sleep 10"
            echo -e "      gunzip --stdout ${immich_dump} \\"
            echo -e "        | sed \"s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g\" \\"
            echo -e "        | docker exec -i immich_postgres psql --dbname=postgres --username=postgres"
            echo -e "      docker compose up -d"
        fi
    else
        echo -e "  • Reverse DNS (PTR) de ${SERVER_IP} → mail.${DOMAIN} dans l'espace client OVH"
        echo -e "    (IP → ⚙ → Modifier le reverse) — indispensable pour la délivrabilité."
        (( ssl_ok )) || echo -e "  • Certificats : ${BOLD}sudo bash $0 ssl${RESET} une fois le DNS propagé"
        echo -e "  • Vérifier le DNS : ${BOLD}sudo bash ${SCRIPT_DIR}/install_dns_ovh.sh --verifier${RESET}"
        echo -e "  • Tester : https://${DOMAIN}, un mail vers Gmail, https://mail-tester.com"
        echo -e "  • Garder l'ancien serveur 24–48 h : des mails peuvent encore y arriver"
        echo -e "    pendant la propagation DNS (récupérables par IMAP sur l'ancien serveur)."
    fi
    if (( ${#manual[@]} )); then
        echo -e "  • VirtualHosts manuels non recréés (copie dans ${STAGE}/meta/apache-sites) :"
        printf "      %s\n" "${manual[@]}"
    fi
    echo
    if (( ${#manual[@]} == 0 )) && confirm "Supprimer le dossier temporaire ${STAGE} (contient des secrets) ?"; then
        rm -rf "$STAGE"; log OK "Dossier temporaire supprimé."
    else
        log WARN "Pensez à supprimer ${STAGE} une fois terminé (il contient des secrets)."
    fi
}

# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
SKIP_DNS=0; SKIP_SSL=0; ARGS=()
for a in "$@"; do
    case "$a" in
        --skip-dns) SKIP_DNS=1 ;;
        --skip-ssl) SKIP_SSL=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        *)          ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

case "${1:-}" in
    prepare)         cmd_prepare "${2:-}" ;;
    ssl)             cmd_ssl ;;
    ""|-h|--help|help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)               cmd_restore "$1" ;;
esac
