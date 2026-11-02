#!/bin/bash
# =============================================================================
#  manage_subdomains.sh — Sous-domaines Apache + certificats Let's Encrypt
#  Auteur  : Laurent Lebarbier
#  Version : 1.0
# =============================================================================
#
#  À utiliser APRÈS install_lamp.sh. Pour chaque sous-domaine (ex : blog) :
#    - crée le VirtualHost Apache  blog.<domaine>
#        • type "site"  : dossier /var/www/blog.<domaine>/public_html
#        • type "proxy" : redirige vers une appli locale (ex : 127.0.0.1:3000)
#    - (option) crée l'enregistrement DNS A chez OVH via l'API — si les
#      identifiants OVH sont déjà dans server.conf (voir install_dns_ovh.sh)
#    - obtient le certificat Let's Encrypt + redirection HTTP → HTTPS
#
#  La suppression retire le VirtualHost, le certificat, (option) le DNS OVH
#  et (option) les fichiers du site — archivés avant effacement.
#
#  Usage interactif (menu) :
#      sudo bash manage_subdomains.sh
#
#  Usage en ligne de commande :
#      sudo bash manage_subdomains.sh add    blog                     # site web
#      sudo bash manage_subdomains.sh add    app  --proxy 3000        # proxy vers 127.0.0.1:3000
#      sudo bash manage_subdomains.sh list
#      sudo bash manage_subdomains.sh ssl    blog                     # (re)demande le certificat
#      sudo bash manage_subdomains.sh dns    blog                     # (re)crée le A chez OVH
#      sudo bash manage_subdomains.sh delete blog
#
#  Options : --proxy PORT|HOST:PORT   --no-dns (ne touche pas au DNS OVH)
#            --no-ssl (pas de certificat)   -y (pas de confirmation)
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
    local ts; ts=$(date '+%H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO ]${RESET} $ts — $*" ;;
        WARN)  echo -e "${YELLOW}[WARN ]${RESET} $ts — $*" ;;
        ERROR) echo -e "${RED}[ERROR]${RESET} $ts — $*" ;;
        STEP)  echo -e "\n${MAGENTA}${BOLD}▶ $*${RESET}" ;;
        OK)    echo -e "${GREEN}${BOLD}  ✔  $*${RESET}" ;;
    esac
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') — manage_subdomains — $*" >> /var/log/install_server.log 2>/dev/null || true
}

ASSUME_YES=0
confirm() {
    [[ "$ASSUME_YES" == 1 ]] && return 0
    local answer
    read -rp "$(echo -e "${YELLOW}  ❓ ${1:-Continuer ?} [o/N] : ${RESET}")" answer
    [[ "${answer,,}" =~ ^(o|oui|y|yes)$ ]]
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
SYS_USER="${SYS_USER:-root}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"

readonly SITES_AVAIL="/etc/apache2/sites-available"
readonly SITES_ENABLED="/etc/apache2/sites-enabled"
readonly WWW_ROOT="/var/www"
readonly BACKUP_DIR="/root/backups/subdomains"
readonly MANAGED_TAG="# Géré par manage_subdomains.sh"
# Noms gérés ailleurs (install_lamp.sh / install_mail.sh) : jamais touchés ici
readonly PROTECTED_SUBS=("www" "mail")

command -v apache2ctl &>/dev/null || { log ERROR "Apache absent. Lancez d'abord install_lamp.sh."; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# "Blog" / "blog.exemple.fr" / "api.dev" → "blog" / "blog" / "api.dev"
normalize_sub() {
    local s="${1,,}"
    s="${s// /}"
    s="${s%.}"
    s="${s%."${DOMAIN}"}"
    echo "$s"
}

valid_sub() {
    local s="$1" p
    if [[ -z "$s" || "$s" == "$DOMAIN" ]] \
       || [[ ! "$s" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; then
        log ERROR "Sous-domaine invalide : '${s}' (lettres, chiffres et tirets uniquement)"
        return 1
    fi
    for p in "${PROTECTED_SUBS[@]}"; do
        if [[ "$s" == "$p" ]]; then
            log ERROR "« ${s} » est géré par les scripts d'installation — non modifiable ici."
            return 1
        fi
    done
}

ask_sub() {
    local s
    read -rp "$(echo -e "  ${CYAN}${1} (ex : blog → blog.${DOMAIN}) : ${RESET}")" s
    normalize_sub "$s"
}

# IPv4 publique vue par les DNS (pas /etc/hosts), via un résolveur public
resolve_ip() {
    local fqdn="$1"
    if command -v dig &>/dev/null; then
        dig +short A "$fqdn" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true
    else
        getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1{print $1}' || true
    fi
}

# Attend que le sous-domaine pointe sur ce serveur (utile juste après
# la création du DNS). Retourne 1 si toujours pas bon après $2 secondes.
wait_dns() {
    local fqdn="$1" timeout="${2:-0}" waited=0 ip
    while true; do
        ip=$(resolve_ip "$fqdn")
        [[ "$ip" == "$SERVER_IP" ]] && return 0
        (( waited >= timeout )) && break
        [[ "$waited" == 0 ]] && log INFO "Attente de la propagation DNS de ${fqdn} (max ${timeout}s)…"
        sleep 10; waited=$((waited + 10))
    done
    log WARN "${fqdn} → ${ip:-(introuvable)} au lieu de ${SERVER_IP}."
    return 1
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

cert_expiry() {
    local pem="/etc/letsencrypt/live/$1/cert.pem"
    [[ -f "$pem" ]] || { echo "-"; return; }
    date -d "$(openssl x509 -enddate -noout -in "$pem" | cut -d= -f2)" '+%d/%m/%Y' 2>/dev/null || echo "?"
}

# ---------------------------------------------------------------------------
# DNS OVH (facultatif — uniquement si les clés API sont dans server.conf)
# ---------------------------------------------------------------------------
readonly OVH_ENDPOINT="https://eu.api.ovh.com/1.0"

ovh_enabled() {
    [[ -n "${OVH_APP_KEY:-}" && -n "${OVH_APP_SECRET:-}" && -n "${OVH_CONSUMER_KEY:-}" ]] \
        && command -v curl &>/dev/null && command -v python3 &>/dev/null
}

ovh_api() {
    local method="$1" path="$2" body="${3:-}"
    local ts sig response http_code out
    ts=$(curl -s "${OVH_ENDPOINT}/auth/time")
    sig="\$1\$$(printf '%s' "${OVH_APP_SECRET}+${OVH_CONSUMER_KEY}+${method}+${OVH_ENDPOINT}${path}+${body}+${ts}" | sha1sum | cut -d' ' -f1)"
    local args=(-s -w '\n%{http_code}' -X "$method" "${OVH_ENDPOINT}${path}"
        -H "X-Ovh-Application: ${OVH_APP_KEY}"
        -H "X-Ovh-Consumer: ${OVH_CONSUMER_KEY}"
        -H "X-Ovh-Timestamp: ${ts}"
        -H "X-Ovh-Signature: ${sig}"
        -H "Content-Type: application/json")
    [[ -n "$body" ]] && args+=(-d "$body")
    response=$(curl "${args[@]}")
    http_code=$(tail -n1 <<< "$response")
    out=$(sed '$d' <<< "$response")
    if [[ "$http_code" -ge 400 ]]; then
        # vers stderr : sur stdout, le message partait dans le « | json_ids »
        # et ne laissait voir qu'une trace Python illisible
        log ERROR "API OVH (HTTP ${http_code}) ${method} ${path} : ${out}" >&2
        return 1
    fi
    if [[ "$http_code" == "000" ]]; then
        log ERROR "API OVH injoignable (${OVH_ENDPOINT}) — réseau ou DNS du serveur ?" >&2
        return 1
    fi
    echo "$out"
}

json_ids() {
    python3 -c 'import json,sys
d = sys.stdin.read().strip()
for i in (json.loads(d) if d else []): print(i)'
}

# Crée (ou corrige) l'enregistrement A sub → SERVER_IP
ovh_dns_add() {
    local sub="$1" ids id
    ids=$(ovh_api GET "/domain/zone/${DOMAIN}/record?fieldType=A&subDomain=${sub}" | json_ids) || return 1
    local body; body=$(printf '{"fieldType":"A","subDomain":"%s","target":"%s","ttl":3600}' "$sub" "$SERVER_IP")
    if [[ -n "$ids" ]]; then
        id=$(head -n1 <<< "$ids")
        ovh_api PUT "/domain/zone/${DOMAIN}/record/${id}" "$(printf '{"target":"%s","ttl":3600}' "$SERVER_IP")" >/dev/null || return 1
        log OK "DNS OVH : ${sub} (A) mis à jour → ${SERVER_IP}"
    else
        # Un CNAME du même nom empêcherait l'enregistrement A
        if [[ -n "$(ovh_api GET "/domain/zone/${DOMAIN}/record?fieldType=CNAME&subDomain=${sub}" | json_ids)" ]]; then
            log ERROR "Un CNAME existe déjà pour ${sub}.${DOMAIN} chez OVH — supprimez-le d'abord."; return 1
        fi
        ovh_api POST "/domain/zone/${DOMAIN}/record" "$body" >/dev/null || return 1
        log OK "DNS OVH : ${sub} (A) créé → ${SERVER_IP}"
    fi
    ovh_api POST "/domain/zone/${DOMAIN}/refresh" >/dev/null || true
}

# Supprime les enregistrements A / AAAA / CNAME du sous-domaine
ovh_dns_del() {
    local sub="$1" type id n=0
    for type in A AAAA CNAME; do
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            ovh_api DELETE "/domain/zone/${DOMAIN}/record/${id}" >/dev/null && n=$((n + 1))
        done < <(ovh_api GET "/domain/zone/${DOMAIN}/record?fieldType=${type}&subDomain=${sub}" | json_ids)
    done
    ovh_api POST "/domain/zone/${DOMAIN}/refresh" >/dev/null || true
    log OK "DNS OVH : ${n} enregistrement(s) supprimé(s) pour ${sub}.${DOMAIN}"
}

# ---------------------------------------------------------------------------
# Certificat Let's Encrypt
# ---------------------------------------------------------------------------
request_cert() {
    local fqdn="$1"
    if ! command -v certbot &>/dev/null; then
        log STEP "Installation de Certbot"
        apt-get install -y -qq certbot python3-certbot-apache
    fi
    log STEP "Certificat Let's Encrypt pour ${fqdn}"
    if certbot --apache --non-interactive --agree-tos \
            --email "$ADMIN_EMAIL" \
            --cert-name "$fqdn" -d "$fqdn" \
            --redirect; then
        log OK "HTTPS actif : https://${fqdn} (renouvellement automatique)"
    else
        log WARN "Certbot a échoué (le DNS pointe-t-il bien vers ${SERVER_IP} ?)."
        log WARN "Le site reste accessible en HTTP. Relancez plus tard : $0 ssl ${fqdn%."${DOMAIN}"}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

# add_subdomain SUB [PROXY_TARGET]
add_subdomain() {
    local sub; sub=$(normalize_sub "${1:-}")
    local proxy="${2:-}"
    valid_sub "$sub" || return 1
    local fqdn="${sub}.${DOMAIN}"
    local conf="${SITES_AVAIL}/${fqdn}.conf"

    if [[ -f "$conf" ]]; then
        log WARN "${fqdn} existe déjà (${conf}). Pour le certificat seul : $0 ssl ${sub}"
        return 1
    fi

    # Cible du proxy : "3000" → 127.0.0.1:3000
    if [[ -n "$proxy" ]]; then
        [[ "$proxy" =~ ^[0-9]+$ ]] && proxy="127.0.0.1:${proxy}"
        if [[ ! "$proxy" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
            log ERROR "Cible proxy invalide : '${proxy}' (attendu : PORT ou HOTE:PORT)"; return 1
        fi
    fi

    log STEP "Création de ${fqdn}${proxy:+ (proxy → ${proxy})}"

    # 1. DNS
    local dns_created=0
    if [[ "${NO_DNS:-0}" != 1 ]] && ovh_enabled; then
        if [[ "$(resolve_ip "$fqdn")" == "$SERVER_IP" ]]; then
            log INFO "DNS déjà correct : ${fqdn} → ${SERVER_IP}"
        elif confirm "Créer l'enregistrement DNS ${sub} (A → ${SERVER_IP}) chez OVH ?"; then
            ovh_dns_add "$sub" && dns_created=1
        fi
    elif [[ "$(resolve_ip "$fqdn")" != "$SERVER_IP" ]]; then
        log WARN "${fqdn} ne pointe pas (encore) vers ${SERVER_IP}."
        echo -e "     Ajoutez chez votre hébergeur DNS :  ${BOLD}${sub}  A  ${SERVER_IP}${RESET}"
        ovh_enabled || echo -e "     (ou lancez install_dns_ovh.sh une fois pour enregistrer les clés API OVH —"
        ovh_enabled || echo -e "      ce script pourra ensuite créer le DNS automatiquement)"
    fi

    # 2. Contenu / VirtualHost HTTP
    local docroot="${WWW_ROOT}/${fqdn}/public_html"
    if [[ -z "$proxy" ]]; then
        mkdir -p "$docroot"
        if [[ ! -e "${docroot}/index.html" && ! -e "${docroot}/index.php" ]]; then
            cat > "${docroot}/index.html" <<HTML
<!DOCTYPE html>
<html lang="fr">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${fqdn}</title>
<style>body{font-family:sans-serif;text-align:center;padding:60px;background:#f8f8f8;color:#333}</style>
</head>
<body><h1>${fqdn}</h1><p>Sous-domaine opérationnel.</p></body>
</html>
HTML
        fi
        chown -R "${SYS_USER}:www-data" "${WWW_ROOT}/${fqdn}"
        chmod -R 755 "${WWW_ROOT}/${fqdn}"

        cat > "$conf" <<VHOST
${MANAGED_TAG} — type: site — créé le $(date '+%d/%m/%Y')
<VirtualHost *:80>
    ServerAdmin   ${ADMIN_EMAIL}
    ServerName    ${fqdn}
    DocumentRoot  ${docroot}

    <Directory ${docroot}>
        Options       -Indexes +FollowSymLinks
        AllowOverride All
        Require       all granted
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/${fqdn}-error.log
    CustomLog \${APACHE_LOG_DIR}/${fqdn}-access.log combined
</VirtualHost>
VHOST
    else
        a2enmod -q proxy proxy_http proxy_wstunnel headers >/dev/null
        cat > "$conf" <<VHOST
${MANAGED_TAG} — type: proxy ${proxy} — créé le $(date '+%d/%m/%Y')
<VirtualHost *:80>
    ServerAdmin   ${ADMIN_EMAIL}
    ServerName    ${fqdn}

    # Let's Encrypt doit pouvoir répondre lui-même au challenge HTTP
    ProxyPass        /.well-known/acme-challenge/ !
    ProxyPreserveHost On
    RequestHeader    set X-Forwarded-Proto expr=%{REQUEST_SCHEME}
    ProxyPass        / http://${proxy}/ upgrade=websocket
    ProxyPassReverse / http://${proxy}/

    ErrorLog  \${APACHE_LOG_DIR}/${fqdn}-error.log
    CustomLog \${APACHE_LOG_DIR}/${fqdn}-access.log combined
</VirtualHost>
VHOST
    fi

    a2ensite -q "${fqdn}.conf" >/dev/null
    if ! apache_reload; then
        a2dissite -q "${fqdn}.conf" >/dev/null || true
        rm -f "$conf"
        log ERROR "VirtualHost retiré, rien n'a été modifié côté Apache."
        return 1
    fi
    log OK "VirtualHost ${fqdn} actif (HTTP)."

    # 3. Certificat
    if [[ "${NO_SSL:-0}" == 1 ]]; then
        log INFO "Certificat non demandé (--no-ssl). Plus tard : $0 ssl ${sub}"
    else
        local wait=0; [[ "$dns_created" == 1 ]] && wait=180
        if wait_dns "$fqdn" "$wait" || confirm "Tenter quand même le certificat maintenant ?"; then
            request_cert "$fqdn" || true
        else
            log INFO "Certificat à demander quand le DNS sera propagé : $0 ssl ${sub}"
        fi
    fi

    echo
    [[ -z "$proxy" ]] && echo -e "  Dossier du site : ${BOLD}${docroot}${RESET}"
    echo -e "  Adresse         : ${BOLD}http$( [[ -f /etc/letsencrypt/live/${fqdn}/cert.pem ]] && echo s)://${fqdn}${RESET}"
}

ssl_subdomain() {
    local sub; sub=$(normalize_sub "${1:-}")
    valid_sub "$sub" || return 1
    local fqdn="${sub}.${DOMAIN}"
    [[ -f "${SITES_AVAIL}/${fqdn}.conf" ]] || { log ERROR "${fqdn} n'existe pas (ajoutez-le d'abord)."; return 1; }
    wait_dns "$fqdn" 0 || confirm "Tenter quand même ?" || return 1
    request_cert "$fqdn"
}

list_subdomains() {
    log STEP "Sous-domaines de ${DOMAIN}"
    printf "  ${BOLD}%-34s %-8s %-22s %-12s %s${RESET}\n" "SOUS-DOMAINE" "ÉTAT" "TYPE" "SSL JUSQU'AU" "DNS"
    local conf fqdn state type ip dnsmark found=0
    for conf in "${SITES_AVAIL}"/*."${DOMAIN}".conf; do
        [[ -f "$conf" ]] || continue
        [[ "$conf" == *-le-ssl.conf ]] && continue
        fqdn=$(basename "$conf" .conf)
        found=1
        if [[ -e "${SITES_ENABLED}/${fqdn}.conf" ]]; then state="${GREEN}actif${RESET}  "; else state="${RED}inactif${RESET}"; fi
        if grep -q '^ *ProxyPass  *\/ ' "$conf"; then
            type="proxy → $(grep -oP '^ *ProxyPass +/ +http://\K[^/ ]+' "$conf" | head -n1)"
        else
            type="site"
        fi
        grep -q "^${MANAGED_TAG}" "$conf" || type="${type} (manuel)"
        ip=$(resolve_ip "$fqdn")
        if [[ "$ip" == "$SERVER_IP" ]]; then dnsmark="${GREEN}OK${RESET}"; else dnsmark="${RED}${ip:-absent}${RESET}"; fi
        printf "  %-34s %b %-22s %-12s %b\n" "$fqdn" "$state" "$type" "$(cert_expiry "$fqdn")" "$dnsmark"
    done
    [[ "$found" == 0 ]] && echo "  (aucun sous-domaine)"
    echo
}

delete_subdomain() {
    local sub; sub=$(normalize_sub "${1:-}")
    valid_sub "$sub" || return 1
    local fqdn="${sub}.${DOMAIN}"
    local conf="${SITES_AVAIL}/${fqdn}.conf"
    local ssl_conf="${SITES_AVAIL}/${fqdn}-le-ssl.conf"
    local site_dir="${WWW_ROOT}/${fqdn}"

    if [[ ! -f "$conf" && ! -f "$ssl_conf" && ! -d "/etc/letsencrypt/live/${fqdn}" ]]; then
        log ERROR "${fqdn} n'existe pas sur ce serveur."; return 1
    fi

    echo -e "  ${RED}${BOLD}Suppression de ${fqdn}${RESET}"
    confirm "Retirer le VirtualHost et le certificat de ${fqdn} ?" || { log INFO "Annulé."; return 0; }

    # 1. Apache
    a2dissite -q "${fqdn}.conf" "${fqdn}-le-ssl.conf" >/dev/null 2>&1 || true
    rm -f "$conf" "$ssl_conf"
    apache_reload || true
    log OK "VirtualHost ${fqdn} supprimé."

    # 2. Certificat (révocation inutile : il expirera seul, on le supprime juste)
    if [[ -d "/etc/letsencrypt/renewal" && -f "/etc/letsencrypt/renewal/${fqdn}.conf" ]]; then
        certbot delete --non-interactive --cert-name "$fqdn" >/dev/null 2>&1 \
            && log OK "Certificat ${fqdn} supprimé (plus de renouvellement)." \
            || log WARN "certbot delete a échoué — vérifiez : certbot certificates"
    fi

    # 3. Fichiers du site (archive avant effacement)
    if [[ -d "$site_dir" ]]; then
        if confirm "Supprimer aussi les fichiers ${site_dir} ($(du -sh "$site_dir" | cut -f1)) ? Une archive sera conservée"; then
            mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
            local archive; archive="${BACKUP_DIR}/${fqdn}_$(date +%Y%m%d_%H%M%S).tar.gz"
            tar -czf "$archive" -C "$WWW_ROOT" "$fqdn"
            rm -rf -- "$site_dir"
            log OK "Fichiers supprimés — archive : ${archive}"
        else
            log INFO "Fichiers conservés dans ${site_dir}."
        fi
    fi

    # 4. DNS OVH
    if [[ "${NO_DNS:-0}" != 1 ]] && ovh_enabled; then
        confirm "Supprimer aussi l'enregistrement DNS ${sub} chez OVH ?" && { ovh_dns_del "$sub" || true; }
    else
        log INFO "Pensez à retirer l'enregistrement DNS « ${sub} » chez votre hébergeur si besoin."
    fi
    log OK "${fqdn} supprimé."
}

# ---------------------------------------------------------------------------
# Menu interactif
# ---------------------------------------------------------------------------
menu() {
    while true; do
        echo -e "\n${CYAN}${BOLD}  🌐 Sous-domaines — ${DOMAIN}${RESET}"
        ovh_enabled && echo -e "     DNS OVH : ${GREEN}automatique${RESET}" \
                    || echo -e "     DNS OVH : ${YELLOW}manuel${RESET} (clés API absentes de server.conf)"
        echo
        echo -e "  ${CYAN}[1]${RESET} Ajouter un sous-domaine (site web)"
        echo -e "  ${CYAN}[2]${RESET} Ajouter un sous-domaine (proxy vers une appli locale)"
        echo -e "  ${CYAN}[3]${RESET} Lister les sous-domaines"
        echo -e "  ${CYAN}[4]${RESET} (Re)demander le certificat SSL"
        echo -e "  ${CYAN}[5]${RESET} Supprimer un sous-domaine"
        echo -e "  ${CYAN}[0]${RESET} Retour\n"
        local choice sub port
        read -rp "$(echo -e "  ${BOLD}Votre choix : ${RESET}")" choice
        case "$choice" in
            1) add_subdomain "$(ask_sub "Nom du sous-domaine")" || true ;;
            2)
                sub=$(ask_sub "Nom du sous-domaine")
                read -rp "$(echo -e "  ${CYAN}Port local de l'appli (ex : 3000, ou hôte:port) : ${RESET}")" port
                add_subdomain "$sub" "$port" || true ;;
            3) list_subdomains ;;
            4) ssl_subdomain "$(ask_sub "Sous-domaine")" || true ;;
            5) delete_subdomain "$(ask_sub "Sous-domaine à supprimer")" || true ;;
            0|q) return 0 ;;
            *) log WARN "Choix invalide : ${choice}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
cmd="${1:-menu}"; [[ $# -gt 0 ]] && shift
ARG=""; PROXY=""; NO_DNS=0; NO_SSL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy)  PROXY="${2:?--proxy attend un PORT ou HOTE:PORT}"; shift 2 ;;
        --no-dns) NO_DNS=1; shift ;;
        --no-ssl) NO_SSL=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        *)        ARG="$1"; shift ;;
    esac
done

case "$cmd" in
    menu)           menu ;;
    add)            add_subdomain "${ARG:?Usage : $0 add NOM [--proxy PORT]}" "$PROXY" ;;
    list|ls)        list_subdomains ;;
    ssl)            ssl_subdomain "${ARG:?Usage : $0 ssl NOM}" ;;
    dns)
        ARG="${ARG:?Usage : $0 dns NOM}"
        ovh_enabled || { log ERROR "Clés API OVH absentes de server.conf."; exit 1; }
        ovh_dns_add "$ARG" ;;
    delete|del|rm)  delete_subdomain "${ARG:?Usage : $0 delete NOM}" ;;
    -h|--help|help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) log ERROR "Commande inconnue : ${cmd} (voir : $0 help)"; exit 1 ;;
esac
