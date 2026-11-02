#!/bin/bash
# =============================================================================
# install_dns_ovh.sh — Sauvegarde puis EFFACE et RECRÉE tous les
# enregistrements DNS (A, MX, SPF, DKIM, DMARC) via l'API OVH.
#
# ⚠️ Ce script est destructif : il supprime tous les enregistrements de la
# zone (sauf NS) avant de les recréer avec la configuration mail standard.
# Une sauvegarde JSON de la zone est écrite avant toute suppression.
#
# Objectif : contourner le bug observé dans l'éditeur de zone web d'OVH, qui
# tronque certains caractères "/" lors du redécoupage interne des longues
# valeurs TXT (clé DKIM). En passant par l'API, on pose la valeur brute
# directement — cela DEVRAIT éviter le bug (probablement propre au formulaire
# web), mais ce n'est pas garanti à 100% si la troncature vient du moteur de
# génération de zone côté OVH plutôt que du formulaire lui-même. Vérifiez
# toujours le résultat avec `dig` + `opendkim-testkey` après exécution.
#
# Prérequis : une application OVH API (https://eu.api.ovh.com/createApp/)
# Usage : sudo bash install_dns_ovh.sh              # remise à zéro + vérification
#         sudo bash install_dns_ovh.sh --verifier   # vérification SEULE (rien n'est modifié)
#
# La vérification compare 3 sources :
#   1. la zone telle que configurée chez OVH (API)
#   2. ce que publient réellement les serveurs DNS d'OVH, et un résolveur public
#   3. les valeurs attendues : IP du serveur, clé DKIM locale, reverse (PTR)
# et signale : enregistrement manquant / faux / en double, clé DKIM tronquée,
# MX parasite (ex : MX OVH par défaut), SPF multiple, CNAME en conflit,
# domaine qui n'utilise pas les DNS OVH, zone pas encore appliquée, PTR absent.
# Code de sortie : 0 si aucune erreur, 1 sinon (utilisable dans un cron).
# =============================================================================
set -euo pipefail

# Journal d'installation : tout l'affichage est aussi écrit dans
# /var/log/install_server/ (voir lib_log.sh)
# shellcheck source=lib_log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_log.sh" 2>/dev/null && start_install_log "$@"
IFS=$'\n\t'

MODE="reset"
case "${1:-}" in
    --verifier|--verif|--check|verifier|check) MODE="check" ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "Option inconnue : $1 (voir --help)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/server.conf"

log()  { echo -e "$*"; }
die()  { echo -e "❌ $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Ce script doit être lancé avec sudo (lecture des clés DKIM)."
[[ -f "$CONFIG_FILE" ]] || die "server.conf introuvable — lancez d'abord install.sh."
# shellcheck source=/dev/null
source "$CONFIG_FILE"
[[ -n "${DOMAIN:-}" ]]    || die "DOMAIN manquant dans server.conf."
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP manquant dans server.conf."

# Serveur cloud : la zone (site, MX, SPF, DKIM) appartient au serveur web +
# mail. Une remise à zéro d'ici ferait pointer le site et le MAIL vers ce
# serveur, qui n'en a pas. Ses sous-domaines (cloud., photos.) sont créés
# un par un par manage_subdomains.sh, sans toucher au reste.
if [[ "${SERVER_ROLE:-web}" == "cloud" ]]; then
    die "Serveur au rôle « cloud » : lancez install_dns_ovh.sh sur le serveur web + mail (VPS).
   Ici, les DNS se gèrent sous-domaine par sous-domaine : sudo bash manage_subdomains.sh"
fi

command -v curl    >/dev/null || die "curl requis."
command -v sha1sum >/dev/null || die "sha1sum requis."
command -v python3 >/dev/null || die "python3 requis (échappement JSON)."

OVH_ENDPOINT="https://eu.api.ovh.com/1.0"

# -----------------------------------------------------------------------------
# 1. Identifiants API OVH — réutilisés depuis server.conf si déjà présents
# -----------------------------------------------------------------------------
if ! grep -q '^OVH_APP_KEY=' "$CONFIG_FILE"; then
    log "=== Identifiants API OVH ==="
    log "Créez une application sur https://eu.api.ovh.com/createApp/ si ce n'est pas déjà fait."
    read -rp "Application Key    : " OVH_APP_KEY
    read -rsp "Application Secret : " OVH_APP_SECRET; echo
    {
        echo "OVH_APP_KEY=\"${OVH_APP_KEY}\""
        echo "OVH_APP_SECRET=\"${OVH_APP_SECRET}\""
    } >> "$CONFIG_FILE"
else
    OVH_APP_KEY=$(grep    '^OVH_APP_KEY='     "$CONFIG_FILE" | cut -d'"' -f2)
    OVH_APP_SECRET=$(grep '^OVH_APP_SECRET='  "$CONFIG_FILE" | cut -d'"' -f2)
fi

if ! grep -q '^OVH_CONSUMER_KEY=' "$CONFIG_FILE"; then
    log "Génération d'une Consumer Key (droits limités à la gestion de zone DNS)..."
    REQ=$(curl -s -X POST "${OVH_ENDPOINT}/auth/credential" \
        -H "X-Ovh-Application: ${OVH_APP_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"accessRules":[
            {"method":"GET","path":"/domain/zone/*"},
            {"method":"POST","path":"/domain/zone/*"},
            {"method":"PUT","path":"/domain/zone/*"},
            {"method":"DELETE","path":"/domain/zone/*"}
        ]}')
    VALIDATION_URL=$(echo "$REQ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["validationUrl"])')
    OVH_CONSUMER_KEY=$(echo "$REQ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["consumerKey"])')
    log "Ouvrez ce lien pour autoriser l'application (connectez-vous à votre compte OVH) :"
    log "  ${VALIDATION_URL}"
    read -rp "Appuyez sur Entrée une fois l'autorisation validée dans le navigateur..." _
    echo "OVH_CONSUMER_KEY=\"${OVH_CONSUMER_KEY}\"" >> "$CONFIG_FILE"
else
    OVH_CONSUMER_KEY=$(grep '^OVH_CONSUMER_KEY=' "$CONFIG_FILE" | cut -d'"' -f2)
fi

chmod 600 "$CONFIG_FILE"

# -----------------------------------------------------------------------------
# 2. Fonction générique d'appel signé à l'API OVH
#    (algorithme de signature documenté sur https://api.ovh.com)
# -----------------------------------------------------------------------------
ovh_api() {
    local method="$1" path="$2" body="${3:-}"
    local ts sig response http_code

    ts=$(curl -s "${OVH_ENDPOINT}/auth/time")
    sig="\$1\$$(printf '%s' "${OVH_APP_SECRET}+${OVH_CONSUMER_KEY}+${method}+${OVH_ENDPOINT}${path}+${body}+${ts}" | sha1sum | cut -d' ' -f1)"

    local curl_args=(-s -w '\n%{http_code}' -X "$method" "${OVH_ENDPOINT}${path}"
        -H "X-Ovh-Application: ${OVH_APP_KEY}"
        -H "X-Ovh-Consumer: ${OVH_CONSUMER_KEY}"
        -H "X-Ovh-Timestamp: ${ts}"
        -H "X-Ovh-Signature: ${sig}"
        -H "Content-Type: application/json")
    [[ -n "$body" ]] && curl_args+=(-d "$body")

    response=$(curl "${curl_args[@]}")

    http_code=$(echo "$response" | tail -n1)
    body_out=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 400 ]]; then
        echo "❌ Erreur API OVH (HTTP ${http_code}) sur ${method} ${path} :" >&2
        echo "$body_out" >&2
        return 1
    fi
    echo "$body_out"
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'
}

# Pré-découpe une valeur TXT de plus de 255 octets en segments explicites
# entre guillemets ("seg1" "seg2" "seg3"), comme le fait nativement
# opendkim-genkey. Nécessaire car l'API OVH, quand on lui envoie une longue
# chaîne brute en un seul bloc, ne la redécoupe pas correctement : elle la
# tronque silencieusement au-delà d'une certaine longueur au lieu de créer
# les segments supplémentaires (bug constaté : 142 caractères de la clé DKIM
# perdus, alors que l'éditeur web — lui — ne perdait que 3 caractères).
build_txt_target() {
    local value="$1"
    if (( ${#value} <= 255 )); then
        printf '%s' "$value"
    else
        python3 - "$value" <<'PYEOF'
import sys
value = sys.argv[1]
size = 255
chunks = [value[i:i+size] for i in range(0, len(value), size)]
escaped = [c.replace('\\', '\\\\').replace('"', '\\"') for c in chunks]
print(' '.join('"' + c + '"' for c in escaped))
PYEOF
    fi
}

# -----------------------------------------------------------------------------
# 3. Créer ou mettre à jour un enregistrement DNS (idempotent)
# -----------------------------------------------------------------------------
dns_set_record() {
    local subdomain="$1" type="$2" target="$3" ttl="${4:-3600}"
    local existing_id target_formatted target_json body

    existing_id=$(ovh_api GET "/domain/zone/${DOMAIN}/record?fieldType=${type}&subDomain=${subdomain}" \
        | python3 -c 'import json,sys; ids=json.load(sys.stdin); print(ids[0] if ids else "")')

    target_formatted=$(build_txt_target "$target")
    target_json=$(printf '%s' "$target_formatted" | json_escape)
    body=$(printf '{"fieldType":"%s","subDomain":"%s","target":%s,"ttl":%s}' \
        "$type" "$subdomain" "$target_json" "$ttl")

    if [[ -n "$existing_id" ]]; then
        log "  → Mise à jour de '${subdomain:-@}' (${type}), id=${existing_id}"
        ovh_api PUT "/domain/zone/${DOMAIN}/record/${existing_id}" "$body" > /dev/null
    else
        log "  → Création de '${subdomain:-@}' (${type})"
        ovh_api POST "/domain/zone/${DOMAIN}/record" "$body" > /dev/null
    fi
}

# -----------------------------------------------------------------------------
# 3bis. VÉRIFICATION DE LA ZONE DNS (lecture seule)
# -----------------------------------------------------------------------------
CHK_OK=0; CHK_WARN=0; CHK_ERR=0
chk_ok()   { echo -e "  \033[0;32m✔\033[0m $*"; CHK_OK=$((CHK_OK + 1)); }
chk_warn() { echo -e "  \033[1;33m⚠\033[0m $*"; CHK_WARN=$((CHK_WARN + 1)); }
chk_err()  { echo -e "  \033[0;31m✖\033[0m $*"; CHK_ERR=$((CHK_ERR + 1)); }
chk_title(){ echo -e "\n\033[1m$*\033[0m"; }

# Recolle une valeur TXT découpée en segments : "abc" "def" → abcdef
# (lit une valeur par ligne sur stdin)
txt_join() {
    python3 -c '
import re, sys
for line in sys.stdin:
    line = line.rstrip("\n")
    parts = re.findall(r"\"((?:[^\"\\\\]|\\\\.)*)\"", line)
    print("".join(parts) if parts else line)'
}

# Extrait la valeur p= d'une clé DKIM (sans espaces)
dkim_p() { tr -d ' \t' | grep -oP '(?<=p=)[A-Za-z0-9+/=]*' | head -n1 || true; }

norm_host() { local h="${1%.}"; echo "${h,,}"; }

# Zone OVH → fichier TSV : type <TAB> sous-domaine <TAB> valeur
ZONE_TSV=""
load_zone() {
    ZONE_TSV=$(mktemp)
    local id rec
    for id in $(ovh_api GET "/domain/zone/${DOMAIN}/record" \
                | python3 -c 'import json,sys; [print(i) for i in json.load(sys.stdin)]'); do
        rec=$(ovh_api GET "/domain/zone/${DOMAIN}/record/${id}")
        python3 -c 'import json,sys; r=json.load(sys.stdin); print("\t".join([r["fieldType"], r.get("subDomain") or "", str(r["target"]).replace("\t"," ")]))' \
            <<< "$rec" >> "$ZONE_TSV"
    done
}

# zone_get TYPE SOUS-DOMAINE → une valeur par ligne
zone_get() { awk -F'\t' -v t="$1" -v s="$2" '$1==t && $2==s {print $3}' "$ZONE_TSV"; }
zone_count() { zone_get "$1" "$2" | grep -c . || true; }

# dig_short TYPE NOM [SERVEUR]
dig_short() {
    local srv=()
    [[ -n "${3:-}" ]] && srv=("@$3")
    dig +short +time=3 +tries=2 "$1" "$2" "${srv[@]}" 2>/dev/null || true
}

verify_dns() {
    CHK_OK=0; CHK_WARN=0; CHK_ERR=0
    local mail_host="mail.${DOMAIN}"
    local local_dkim=""
    if [[ -f "/etc/dkimkeys/${DOMAIN}/mail.txt" ]]; then
        local_dkim=$(grep -v '^;' "/etc/dkimkeys/${DOMAIN}/mail.txt" | txt_join | tr -d '\n' | dkim_p)
    fi

    echo
    log "=== Vérification DNS de ${DOMAIN} (IP attendue : ${SERVER_IP}) ==="
    load_zone
    log "  $(wc -l < "$ZONE_TSV") enregistrements lus dans la zone OVH."

    # --- 1. Zone OVH : enregistrements A ---------------------------------------
    chk_title "1. Zone OVH — adresses (A)"
    local sub label n vals
    for sub in "" "www" "mail"; do
        label="${sub:-@}"
        n=$(zone_count A "$sub"); vals=$(zone_get A "$sub" | paste -sd' ')
        if (( n == 0 )); then
            chk_err "A ${label} : absent"
        elif (( n > 1 )); then
            chk_err "A ${label} : ${n} valeurs (${vals}) — une seule attendue (${SERVER_IP})"
        elif [[ "$(zone_get A "$sub")" != "$SERVER_IP" ]]; then
            chk_err "A ${label} : ${vals} au lieu de ${SERVER_IP}"
        else
            chk_ok "A ${label} → ${SERVER_IP}"
        fi
        if (( $(zone_count AAAA "$sub") > 0 )); then
            chk_warn "AAAA ${label} présent ($(zone_get AAAA "$sub" | paste -sd' ')) : les clients IPv6 iront à cette adresse — à supprimer si ce n'est pas ce serveur"
        fi
        if (( $(zone_count CNAME "$sub") > 0 )); then
            chk_err "CNAME ${label} présent en plus du A — conflit, à supprimer"
        fi
    done

    # --- 2. Zone OVH : MX ----------------------------------------------------------
    chk_title "2. Zone OVH — réception des mails (MX)"
    local mx found_ours=0 others=()
    while IFS= read -r mx; do
        [[ -z "$mx" ]] && continue
        if [[ "$(norm_host "${mx##* }")" == "$mail_host" ]]; then found_ours=1
        else others+=("$mx"); fi
    done < <(zone_get MX "")
    (( found_ours )) && chk_ok "MX @ → ${mail_host}" || chk_err "MX @ vers ${mail_host} : absent"
    for mx in "${others[@]+"${others[@]}"}"; do
        chk_err "MX parasite : « ${mx} » — une partie des mails partirait ailleurs (MX OVH par défaut ?)"
    done

    # --- 3. Zone OVH : SPF ---------------------------------------------------------
    chk_title "3. Zone OVH — SPF"
    local spf; spf=$( { zone_get TXT ""; zone_get SPF ""; } | txt_join | grep '^v=spf1' || true)
    n=$(grep -c . <<< "$spf" || true)
    if (( n == 0 )); then
        chk_err "SPF absent (TXT @ « v=spf1 … »)"
    elif (( n > 1 )); then
        chk_err "${n} enregistrements SPF : invalide (permerror) — n'en garder qu'un"
        sed 's/^/        /' <<< "$spf"
    else
        if grep -q "ip4:${SERVER_IP}\b" <<< "$spf"; then
            chk_ok "SPF autorise ${SERVER_IP} : ${spf}"
        elif grep -qw 'mx' <<< "$spf"; then
            chk_warn "SPF sans ip4:${SERVER_IP} (couvert par « mx » seulement) : ${spf}"
        else
            chk_err "SPF n'autorise pas ${SERVER_IP} : ${spf}"
        fi
        grep -q -- '-all\|~all' <<< "$spf" || chk_warn "SPF sans « ~all » ni « -all » à la fin"
    fi

    # --- 4. Zone OVH : DKIM --------------------------------------------------------
    chk_title "4. Zone OVH — DKIM (mail._domainkey)"
    local dkim_zone p_zone
    dkim_zone=$( { zone_get TXT "mail._domainkey"; zone_get DKIM "mail._domainkey"; } | txt_join)
    n=$(grep -c . <<< "$dkim_zone" || true)
    if (( n == 0 )); then
        chk_err "DKIM absent"
    else
        (( n > 1 )) && chk_err "${n} enregistrements DKIM pour le sélecteur « mail » — un seul attendu"
        p_zone=$(head -n1 <<< "$dkim_zone" | dkim_p)
        if [[ -z "$local_dkim" ]]; then
            chk_warn "Clé locale introuvable (/etc/dkimkeys/${DOMAIN}/mail.txt) — comparaison impossible"
            [[ -n "$p_zone" ]] && chk_ok "DKIM présent (${#p_zone} caractères)"
        elif [[ "$p_zone" == "$local_dkim" ]]; then
            chk_ok "DKIM identique à la clé du serveur (${#p_zone} caractères)"
        elif [[ "$local_dkim" == "$p_zone"* || ${#p_zone} -lt ${#local_dkim} ]]; then
            chk_err "DKIM TRONQUÉ dans la zone : ${#p_zone} caractères au lieu de ${#local_dkim} (bug OVH) — relancez ce script sans --verifier"
        else
            chk_err "DKIM différent de la clé du serveur (ancienne clé ?) — relancez ce script sans --verifier"
        fi
    fi

    # --- 5. Zone OVH : DMARC -------------------------------------------------------
    chk_title "5. Zone OVH — DMARC"
    local dmarc; dmarc=$(zone_get TXT "_dmarc" | txt_join | grep '^v=DMARC1' || true)
    n=$(grep -c . <<< "$dmarc" || true)
    if (( n == 1 )); then chk_ok "DMARC : ${dmarc}"
    elif (( n == 0 )); then chk_err "DMARC absent (TXT _dmarc)"
    else chk_err "${n} enregistrements DMARC — un seul autorisé"; fi

    # --- 6. Sous-domaines gérés par manage_subdomains.sh ---------------------------
    local conf fqdn s subs=0
    for conf in /etc/apache2/sites-available/*."${DOMAIN}".conf; do
        [[ -f "$conf" && "$conf" != *-le-ssl.conf ]] || continue
        grep -q '^# Géré par manage_subdomains.sh' "$conf" || continue
        (( subs++ == 0 )) && chk_title "6. Zone OVH — sous-domaines du serveur"
        fqdn=$(basename "$conf" .conf); s="${fqdn%."${DOMAIN}"}"
        if [[ "$(zone_get A "$s" | head -n1)" == "$SERVER_IP" ]]; then
            chk_ok "A ${s} → ${SERVER_IP}"
        elif (( $(zone_count CNAME "$s") > 0 )); then
            chk_warn "${s} est un CNAME ($(zone_get CNAME "$s" | head -n1)) — vérifiez qu'il mène bien à ce serveur"
        else
            chk_err "A ${s} absent ou faux ($(zone_get A "$s" | paste -sd' ')) — relancez ce script sans --verifier (il recrée les sous-domaines)"
        fi
    done

    # --- 7. Ce que publie réellement Internet -----------------------------------------
    chk_title "7. DNS publiés (serveurs OVH + résolveur public)"
    if ! command -v dig &>/dev/null; then
        apt-get install -y -qq dnsutils >/dev/null 2>&1 || true
    fi
    if ! command -v dig &>/dev/null; then
        chk_warn "dig indisponible (paquet dnsutils) — vérification publique ignorée"
    else
        local ns_zone ns_pub auth
        ns_zone=$(ovh_api GET "/domain/zone/${DOMAIN}" \
            | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("nameServers", [])))' || true)
        ns_pub=$(dig_short NS "$DOMAIN" 1.1.1.1)
        auth=$(head -n1 <<< "$ns_zone"); auth="${auth%.}"

        # Le domaine utilise-t-il bien les DNS de cette zone OVH ?
        local nz np
        nz=$(sed 's/\.$//' <<< "$ns_zone" | tr 'A-Z' 'a-z' | sort | grep . || true)
        np=$(sed 's/\.$//' <<< "$ns_pub"  | tr 'A-Z' 'a-z' | sort | grep . || true)
        if [[ -z "$np" ]]; then
            chk_warn "Serveurs NS publics introuvables (domaine expiré ou réseau ?)"
        elif [[ "$nz" == "$np" ]]; then
            chk_ok "Le domaine utilise bien les DNS OVH ($(paste -sd' ' <<< "$np"))"
        else
            chk_err "Le domaine N'UTILISE PAS ces serveurs DNS : publics = $(paste -sd' ' <<< "$np"), zone OVH = $(paste -sd' ' <<< "$nz") — les changements faits ici sont sans effet"
        fi

        if [[ -n "$auth" ]]; then
            # Serveur faisant autorité : la zone a-t-elle été appliquée ?
            local name got
            for name in "$DOMAIN" "www.${DOMAIN}" "$mail_host"; do
                got=$(dig_short A "$name" "$auth" | paste -sd' ')
                [[ "$got" == "$SERVER_IP" ]] && chk_ok "${auth} : A ${name} → ${got}" \
                    || chk_err "${auth} publie A ${name} → ${got:-(rien)} (zone pas encore appliquée ? attendre 1-2 min)"
            done
            got=$(dig_short MX "$DOMAIN" "$auth" | awk '{print $2}' | sed 's/\.$//' | paste -sd' ')
            [[ "$got" == "$mail_host" ]] && chk_ok "${auth} : MX → ${got}" \
                || chk_err "${auth} publie MX → ${got:-(rien)}"
            if [[ -n "$local_dkim" ]]; then
                got=$(dig_short TXT "mail._domainkey.${DOMAIN}" "$auth" | txt_join | dkim_p)
                [[ "$got" == "$local_dkim" ]] && chk_ok "${auth} : DKIM publié complet (${#got} caractères)" \
                    || chk_err "${auth} publie un DKIM de ${#got} caractères au lieu de ${#local_dkim} (tronqué ou ancien)"
            fi
        fi

        # Résolveur public : propagation
        local pub; pub=$(dig_short A "$mail_host" 1.1.1.1 | tail -n1)
        if [[ "$pub" == "$SERVER_IP" ]]; then
            chk_ok "Résolveur public (1.1.1.1) : ${mail_host} → ${pub}"
        else
            chk_warn "Résolveur public (1.1.1.1) : ${mail_host} → ${pub:-(rien)} — propagation en cours (jusqu'au TTL)"
        fi

        # Reverse DNS (PTR) — se règle dans l'espace client OVH, pas dans la zone
        local ptr; ptr=$(norm_host "$(dig_short -x "$SERVER_IP" | head -n1)")
        if [[ "$ptr" == "$mail_host" ]]; then
            chk_ok "Reverse (PTR) ${SERVER_IP} → ${ptr}"
        else
            chk_err "Reverse (PTR) ${SERVER_IP} → ${ptr:-(rien)} au lieu de ${mail_host} — espace client OVH : IP → ⚙ → Modifier le reverse"
        fi
    fi

    # --- 8. Test DKIM d'OpenDKIM -----------------------------------------------------
    if command -v opendkim-testkey &>/dev/null && [[ -n "$local_dkim" ]]; then
        chk_title "8. Test OpenDKIM"
        local out; out=$(opendkim-testkey -d "$DOMAIN" -s mail -vvv 2>&1 || true)
        if grep -q 'key OK' <<< "$out"; then
            chk_ok "opendkim-testkey : key OK"
        elif grep -q 'key not secure' <<< "$out" && ! grep -qi 'error\|mismatch' <<< "$out"; then
            chk_ok "opendkim-testkey : clé valide (« not secure » = pas de DNSSEC, normal)"
        else
            chk_err "opendkim-testkey : $(tail -n1 <<< "$out")"
        fi
    fi

    rm -f "$ZONE_TSV"

    echo
    echo -e "  \033[1mBilan : \033[0;32m${CHK_OK} OK\033[0m, \033[1;33m${CHK_WARN} avertissement(s)\033[0m, \033[0;31m${CHK_ERR} erreur(s)\033[0m"
    if (( CHK_ERR > 0 )); then
        echo -e "  Les erreurs des sections 1 à 6 se corrigent en relançant ce script sans --verifier"
        echo -e "  (⚠ il remet TOUTE la zone à zéro — sauvegarde JSON faite avant — : notez d'abord"
        echo -e "   vos enregistrements personnels, ex. TXT de vérification Google)."
        echo -e "  Le reverse (PTR) se règle dans l'espace client OVH ; les erreurs de publication"
        echo -e "  (section 7) disparaissent d'elles-mêmes après quelques minutes."
        return 1
    fi
    return 0
}

# Mode vérification seule : on s'arrête là, rien n'est modifié
if [[ "$MODE" == "check" ]]; then
    verify_dns && exit 0 || exit 1
fi

# -----------------------------------------------------------------------------
# 4. Sauvegarde de la zone actuelle (avant toute suppression)
# -----------------------------------------------------------------------------
BACKUP_FILE="${SCRIPT_DIR}/dns_backup_${DOMAIN}_$(date +%Y%m%d_%H%M%S).json"
log "=== Sauvegarde de la zone ${DOMAIN} avant remise à zéro ==="

ALL_IDS=$(ovh_api GET "/domain/zone/${DOMAIN}/record")
echo "[" > "$BACKUP_FILE"
first=true
for id in $(echo "$ALL_IDS" | python3 -c 'import json,sys; [print(i) for i in json.load(sys.stdin)]'); do
    rec=$(ovh_api GET "/domain/zone/${DOMAIN}/record/${id}")
    [[ "$first" == true ]] && first=false || echo "," >> "$BACKUP_FILE"
    echo "$rec" >> "$BACKUP_FILE"
done
echo "]" >> "$BACKUP_FILE"
log "→ Sauvegarde écrite dans : ${BACKUP_FILE}"
log "  (conservez ce fichier — il permet de recréer manuellement les enregistrements en cas de problème)"

# -----------------------------------------------------------------------------
# 5. Confirmation explicite avant suppression complète
# -----------------------------------------------------------------------------
log ""
log "⚠️  Vous êtes sur le point de SUPPRIMER TOUS les enregistrements DNS"
log "    de la zone ${DOMAIN} (sauf les NS, jamais touchés), puis de les"
log "    recréer avec la configuration mail standard (A, MX, SPF, DKIM, DMARC)."
log "    Toute autre configuration DNS existante (sous-domaines, autres TXT,"
log "    CNAME, etc.) sera perdue si elle n'a pas déjà été notée."
log ""
read -rp "Tapez SUPPRIMER en majuscules pour confirmer : " CONFIRM
[[ "$CONFIRM" == "SUPPRIMER" ]] || die "Opération annulée."

# -----------------------------------------------------------------------------
# 6. Suppression de tous les enregistrements (hors NS)
# -----------------------------------------------------------------------------
log "=== Suppression des enregistrements existants ==="
for id in $(echo "$ALL_IDS" | python3 -c 'import json,sys; [print(i) for i in json.load(sys.stdin)]'); do
    rec=$(ovh_api GET "/domain/zone/${DOMAIN}/record/${id}")
    rtype=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fieldType"])')
    rsub=$(echo "$rec"  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("subDomain") or "@")')

    if [[ "$rtype" == "NS" ]]; then
        log "  ⏭  Conservé : ${rsub} (NS) — jamais supprimé"
        continue
    fi

    log "  🗑  Suppression : ${rsub} (${rtype}), id=${id}"
    ovh_api DELETE "/domain/zone/${DOMAIN}/record/${id}" > /dev/null
done

# -----------------------------------------------------------------------------
# 7. Recréation complète avec la configuration standard
# -----------------------------------------------------------------------------
log ""
log "=== Recréation des enregistrements DNS pour ${DOMAIN} ==="

dns_set_record ""     "A"  "${SERVER_IP}"
dns_set_record "www"  "A"  "${SERVER_IP}"
dns_set_record "mail" "A"  "${SERVER_IP}"
dns_set_record ""     "MX" "10 mail.${DOMAIN}."
dns_set_record ""     "TXT" "v=spf1 mx ip4:${SERVER_IP} ~all"
dns_set_record "_dmarc" "TXT" "v=DMARC1; p=quarantine; rua=mailto:admin@${DOMAIN}"

if [[ -f "/etc/dkimkeys/${DOMAIN}/mail.txt" ]]; then
    DKIM_KEY=$(grep -oP '(?<=p=)[A-Za-z0-9+/=]+' "/etc/dkimkeys/${DOMAIN}/mail.txt" | tr -d '\n')
    dns_set_record "mail._domainkey" "TXT" "v=DKIM1; h=sha256; k=rsa; p=${DKIM_KEY}"
else
    log "⚠️  Clé DKIM introuvable (/etc/dkimkeys/${DOMAIN}/mail.txt) — lancez d'abord install_mail.sh."
fi

# Sous-domaines créés par manage_subdomains.sh : la remise à zéro vient de
# les effacer, on les recrée tout de suite
for conf in /etc/apache2/sites-available/*."${DOMAIN}".conf; do
    [[ -f "$conf" && "$conf" != *-le-ssl.conf ]] || continue
    grep -q '^# Géré par manage_subdomains.sh' "$conf" || continue
    sub=$(basename "$conf" .conf); sub="${sub%."${DOMAIN}"}"
    dns_set_record "$sub" "A" "${SERVER_IP}"
done

log "→ Application des changements (refresh de la zone)..."
ovh_api POST "/domain/zone/${DOMAIN}/refresh" > /dev/null

log "✅ Zone DNS mise à jour."

# Vérification automatique (les serveurs OVH mettent quelques secondes à
# publier la nouvelle zone)
log "Attente de 30 s que les serveurs DNS d'OVH appliquent la zone..."
sleep 30
if ! verify_dns; then
    log ""
    log "Si seules les sections 7 (publication / propagation) sont en erreur, attendez"
    log "quelques minutes puis relancez : sudo bash $0 --verifier"
fi
