#!/usr/bin/env bash
# =============================================================================
# update_dkim_ovh.sh — Republie UNIQUEMENT la clé publique DKIM dans la zone OVH
#
# Recalcule la clé publique depuis la clé privée réellement utilisée par
# OpenDKIM (correspondance garantie), supprime les anciens enregistrements
# mail._domainkey (TXT et type « DKIM » d'OVH), crée le nouveau TXT puis
# applique la zone. Ne touche à AUCUN autre enregistrement — contrairement à
# install_dns_ovh.sh, qui remet toute la zone à zéro.
#
# Cas d'usage : nouvelle clé générée par install_mail.sh (serveur réinstallé
# sans sauvegarde), clé tronquée par l'éditeur web OVH, rotation de clé.
#
# Usage : sudo bash update_dkim_ovh.sh [domaine]
#         (domaine par défaut : DOMAIN de server.conf)
#
# Identifiants OVH, cherchés dans cet ordre :
#   1. server.conf du projet  : OVH_APP_KEY / OVH_APP_SECRET / OVH_CONSUMER_KEY
#                               (posés par install_dns_ovh.sh)
#   2. ~/.ovh.conf            : OVH_AK / OVH_AS / OVH_CK  (voir .ovh.conf.example)
#   3. variables d'environnement OVH_AK / OVH_AS / OVH_CK
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/server.conf"
SELECTOR="mail"
API="https://eu.api.ovh.com/1.0"
TTL=600

die() { echo "❌ $*" >&2; exit 1; }

# --- Configuration -----------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    OVH_AK="${OVH_AK:-${OVH_APP_KEY:-}}"
    OVH_AS="${OVH_AS:-${OVH_APP_SECRET:-}}"
    OVH_CK="${OVH_CK:-${OVH_CONSUMER_KEY:-}}"
fi

# ~/.ovh.conf : celui de l'utilisateur qui lance sudo, sinon celui de root
for f in "${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ovh.conf}" "$HOME/.ovh.conf"; do
    if [[ -n "$f" && -f "$f" && ( -z "${OVH_AK:-}" || -z "${OVH_AS:-}" || -z "${OVH_CK:-}" ) ]]; then
        # shellcheck source=/dev/null
        source "$f"
    fi
done

ZONE="${1:-${DOMAIN:-}}"
[[ -n "$ZONE" ]] || die "Domaine inconnu : passez-le en argument ou lancez install.sh (server.conf)."
: "${OVH_AK:?OVH_AK / OVH_APP_KEY manquant (server.conf ou ~/.ovh.conf)}"
: "${OVH_AS:?OVH_AS / OVH_APP_SECRET manquant (server.conf ou ~/.ovh.conf)}"
: "${OVH_CK:?OVH_CK / OVH_CONSUMER_KEY manquant (server.conf ou ~/.ovh.conf)}"

SUB="${SELECTOR}._domainkey"
KEYFILE="/etc/dkimkeys/${ZONE}/${SELECTOR}.private"

command -v jq      >/dev/null || die "jq requis : sudo apt install jq"
command -v openssl >/dev/null || die "openssl requis."

SUDO=""
[[ $EUID -eq 0 ]] || SUDO="sudo"

# --- Appel signé à l'API OVH : ovh METHODE /chemin [corps_json] ---------------
ovh() {
    local method=$1 path=$2 body=${3:-}
    local url="${API}${path}" ts sig
    ts=$(curl -sS "${API}/auth/time")
    sig='$1$'$(printf '%s' "${OVH_AS}+${OVH_CK}+${method}+${url}+${body}+${ts}" | sha1sum | cut -d' ' -f1)
    local args=(-sS -X "$method"
        -H "X-Ovh-Application: ${OVH_AK}"
        -H "X-Ovh-Consumer: ${OVH_CK}"
        -H "X-Ovh-Timestamp: ${ts}"
        -H "X-Ovh-Signature: ${sig}"
        -H "Content-Type: application/json")
    [[ -n "$body" ]] && args+=(--data "$body")
    curl "${args[@]}" "$url"
}

# --- 1. Clé publique calculée depuis la clé privée ---------------------------
$SUDO test -f "$KEYFILE" || die "Clé privée introuvable : $KEYFILE (install_mail.sh lancé ?)"
P=$($SUDO openssl rsa -in "$KEYFILE" -pubout -outform der 2>/dev/null | openssl base64 -A)
[[ -n "$P" ]] || die "Impossible de lire $KEYFILE"
TARGET="v=DKIM1; k=rsa; p=${P}"
echo "Domaine : ${ZONE} — clé publique : ${#P} caractères"

# Vérifie que les identifiants fonctionnent avant de supprimer quoi que ce soit
check=$(ovh GET "/domain/zone/${ZONE}/record?fieldType=TXT&subDomain=${SUB}")
echo "$check" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || die "Accès API refusé ou zone inconnue : $check"

# --- 2. Suppression des anciens enregistrements (TXT et type DKIM d'OVH) ------
for type in TXT DKIM; do
    for id in $(ovh GET "/domain/zone/${ZONE}/record?fieldType=${type}&subDomain=${SUB}" | jq -r '.[]?'); do
        echo "Suppression ${type} #${id}"
        ovh DELETE "/domain/zone/${ZONE}/record/${id}" >/dev/null
    done
done

# --- 3. Création du nouvel enregistrement ------------------------------------
body=$(jq -nc --arg s "$SUB" --arg t "$TARGET" --argjson ttl "$TTL" \
    '{fieldType:"TXT", subDomain:$s, target:$t, ttl:$ttl}')
res=$(ovh POST "/domain/zone/${ZONE}/record" "$body")
if echo "$res" | jq -e '.id' >/dev/null 2>&1; then
    echo "✔ Créé : #$(echo "$res" | jq -r '.id')"
else
    die "Erreur API : $res"
fi

# --- 4. Application de la zone -----------------------------------------------
ovh POST "/domain/zone/${ZONE}/refresh" >/dev/null
echo "✔ Zone rafraîchie. Vérifiez dans quelques minutes :"
echo "  dig +short TXT ${SUB}.${ZONE}"
echo "  sudo opendkim-testkey -d ${ZONE} -s ${SELECTOR} -vvv"
echo "  sudo bash install_dns_ovh.sh --verifier"
