#!/bin/bash
# =============================================================================
#  manage_mail.sh — Gestion des comptes mail virtuels (base vmail)
#  Auteur  : Laurent Lebarbier
#  Version : 1.0
# =============================================================================
#
#  À utiliser APRÈS install_mail.sh. Gère les boîtes et alias stockés dans
#  MariaDB (base vmail) et lus par Postfix/Dovecot — aucun redémarrage de
#  service n'est nécessaire : les changements sont pris en compte immédiatement.
#
#  Usage interactif (menu) :
#      sudo bash manage_mail.sh
#
#  Usage en ligne de commande :
#      sudo bash manage_mail.sh add      prenom@domaine.fr     # demande le mot de passe
#      sudo bash manage_mail.sh list
#      sudo bash manage_mail.sh passwd   prenom@domaine.fr
#      sudo bash manage_mail.sh disable  prenom@domaine.fr
#      sudo bash manage_mail.sh enable   prenom@domaine.fr
#      sudo bash manage_mail.sh delete   prenom@domaine.fr
#      sudo bash manage_mail.sh alias    contact@domaine.fr prenom@domaine.fr
#      sudo bash manage_mail.sh unalias  contact@domaine.fr
#      sudo bash manage_mail.sh import   comptes.txt
#
#  Format du fichier d'import (une ligne par compte, # = commentaire) :
#      prenom@domaine.fr                  → mot de passe généré et affiché
#      prenom@domaine.fr;MotDePasse12345  → mot de passe imposé
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
    # Les mots de passe ne passent jamais par log() : rien de sensible ici.
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') — manage_mail — $*" >> /var/log/install_server.log 2>/dev/null || true
}

confirm() {
    local answer
    read -rp "$(echo -e "${YELLOW}  ❓ ${1:-Continuer ?} [o/N] : ${RESET}")" answer
    [[ "${answer,,}" =~ ^(o|oui|y|yes)$ ]]
}

# ---------------------------------------------------------------------------
# Vérifications
# ---------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"; exit 1
fi

CONFIG_FILE="$(dirname "$0")/server.conf"
readonly CONFIG_FILE
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
fi
DOMAIN="${DOMAIN:-}"

readonly VMAIL_DIR="/var/vmail"
readonly MIN_PASS_LEN=10

# Accès root à MariaDB via unix_socket (comme install_mail.sh)
db() { mysql --batch --skip-column-names vmail -e "$1"; }

if ! db "SELECT 1 FROM users LIMIT 1" &>/dev/null; then
    log ERROR "Base vmail inaccessible. Lancez d'abord install_mail.sh."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Validation stricte : la valeur est ensuite insérée dans du SQL, on
# n'accepte donc aucun guillemet ni caractère exotique.
valid_email() {
    [[ "$1" =~ ^[a-z0-9._%+-]+@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]
}

# Normalise en minuscules (Postfix compare les adresses en minuscules)
normalize() { echo "${1,,}" | tr -d '[:space:]'; }

ask_email() {
    local prompt="$1" default_domain="${DOMAIN}" email
    read -rp "$(echo -e "  ${CYAN}${prompt}${default_domain:+ (ou juste le prénom → @${default_domain})} : ${RESET}")" email
    email=$(normalize "$email")
    # "prenom" seul → prenom@DOMAIN
    if [[ -n "$email" && "$email" != *@* && -n "$default_domain" ]]; then
        email="${email}@${default_domain}"
    fi
    echo "$email"
}

user_exists()  { [[ -n "$(db "SELECT 1 FROM users   WHERE email='$1'")" ]]; }
alias_exists() { [[ -n "$(db "SELECT 1 FROM aliases WHERE source='$1'")" ]]; }

# Hachage SHA512-CRYPT. Le mot de passe passe par stdin (here-string),
# jamais en argument : il n'apparaît donc pas dans `ps`.
hash_password() {
    local hash
    hash=$(openssl passwd -6 -stdin <<< "$1")
    echo "{SHA512-CRYPT}${hash}"
}

gen_password() { openssl rand -base64 24 | tr -d '+/=' | head -c 16; }

# Lit un mot de passe (masqué, confirmé). Vide → généré automatiquement.
# Le résultat est placé dans la variable globale NEW_PASS.
read_password() {
    local p1 p2
    while true; do
        read -rsp "$(echo -e "  ${CYAN}Mot de passe (vide = généré automatiquement) : ${RESET}")" p1; echo
        if [[ -z "$p1" ]]; then
            NEW_PASS=$(gen_password)
            GENERATED=1
            return
        fi
        read -rsp "$(echo -e "  ${CYAN}Confirmez : ${RESET}")" p2; echo
        if [[ "$p1" != "$p2" ]]; then
            log WARN "Les mots de passe ne correspondent pas."
        elif (( ${#p1} < MIN_PASS_LEN )); then
            log WARN "Minimum ${MIN_PASS_LEN} caractères."
        else
            NEW_PASS="$p1"; GENERATED=0
            return
        fi
    done
}

# S'assure que le domaine est géré par le serveur ; propose de l'ajouter.
ensure_domain() {
    local dom="$1"
    if [[ -n "$(db "SELECT 1 FROM domains WHERE domain='${dom}'")" ]]; then
        return 0
    fi
    log WARN "Le domaine ${dom} n'est pas encore géré par ce serveur."
    if [[ "${NONINTERACTIVE:-0}" == 1 ]] || ! confirm "Ajouter le domaine ${dom} ?"; then
        log ERROR "Domaine ${dom} non géré — compte non créé."
        return 1
    fi
    db "INSERT INTO domains (domain) VALUES ('${dom}')"
    log OK "Domaine ${dom} ajouté."
    echo -e "  ${YELLOW}⚠  Pour recevoir/envoyer avec ${dom}, il faut aussi :${RESET}"
    echo -e "     - un enregistrement MX ${dom} → 10 mail.${DOMAIN:-<votre-domaine>}."
    echo -e "     - SPF / DMARC pour ${dom}"
    echo -e "     - une clé DKIM : OpenDKIM ne signe actuellement que @${DOMAIN:-<votre-domaine>}"
    echo -e "       (/etc/opendkim/KeyTable et SigningTable à compléter)."
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

# add_account EMAIL [MOT_DE_PASSE]
add_account() {
    local email; email=$(normalize "${1:-}")
    local pass="${2:-}"
    GENERATED=0

    if ! valid_email "$email"; then
        log ERROR "Adresse invalide : '${email}'"; return 1
    fi
    if user_exists "$email"; then
        log WARN "Le compte ${email} existe déjà (utilisez 'passwd' pour changer son mot de passe)."
        return 1
    fi
    if alias_exists "$email"; then
        log WARN "${email} est déjà un alias — supprimez l'alias d'abord ('unalias')."
        return 1
    fi

    local dom="${email#*@}"
    ensure_domain "$dom" || return 1

    if [[ -z "$pass" ]]; then
        if [[ "${NONINTERACTIVE:-0}" == 1 ]]; then
            pass=$(gen_password); GENERATED=1
        else
            read_password; pass="$NEW_PASS"
        fi
    elif (( ${#pass} < MIN_PASS_LEN )); then
        log ERROR "${email} : mot de passe trop court (min. ${MIN_PASS_LEN})."; return 1
    fi

    local hash; hash=$(hash_password "$pass")
    db "INSERT INTO users (domain, email, password) VALUES ('${dom}', '${email}', '${hash}')"

    log OK "Compte créé : ${email}"
    if [[ "$GENERATED" == 1 ]]; then
        echo -e "     Mot de passe généré : ${YELLOW}${BOLD}${pass}${RESET}  ← notez-le, il ne sera plus affiché"
    fi
}

list_accounts() {
    log STEP "Comptes mail"
    printf "  ${BOLD}%-40s %-8s %s${RESET}\n" "ADRESSE" "ÉTAT" "TAILLE"
    local email active size
    while IFS=$'\t' read -r email active; do
        [[ -z "$email" ]] && continue
        local dir="${VMAIL_DIR}/${email#*@}/${email%@*}"
        size=$( [[ -d "$dir" ]] && du -sh "$dir" 2>/dev/null | cut -f1 || echo "-" )
        if [[ "$active" == 1 ]]; then active="${GREEN}actif${RESET}  "; else active="${RED}inactif${RESET}"; fi
        printf "  %-40s %b %s\n" "$email" "$active" "$size"
    done < <(db "SELECT email, active FROM users ORDER BY domain, email")

    log STEP "Alias (redirections)"
    local src dst
    while IFS=$'\t' read -r src dst active; do
        [[ -z "$src" ]] && continue
        local mark=""; [[ "$active" != 1 ]] && mark=" ${RED}(inactif)${RESET}"
        printf "  %-40s → %s%b\n" "$src" "$dst" "$mark"
    done < <(db "SELECT source, destination, active FROM aliases ORDER BY source")
    echo
}

change_password() {
    local email; email=$(normalize "${1:-}")
    valid_email "$email" && user_exists "$email" || { log ERROR "Compte introuvable : '${email}'"; return 1; }
    GENERATED=0
    read_password
    db "UPDATE users SET password='$(hash_password "$NEW_PASS")' WHERE email='${email}'"
    log OK "Mot de passe modifié pour ${email}"
    [[ "$GENERATED" == 1 ]] && echo -e "     Nouveau mot de passe : ${YELLOW}${BOLD}${NEW_PASS}${RESET}"
    return 0
}

set_active() {
    local email state="$2"; email=$(normalize "${1:-}")
    valid_email "$email" && user_exists "$email" || { log ERROR "Compte introuvable : '${email}'"; return 1; }
    db "UPDATE users SET active=${state} WHERE email='${email}'"
    if [[ "$state" == 1 ]]; then log OK "${email} activé."; else log OK "${email} désactivé (connexion et réception bloquées, mails conservés)."; fi
}

delete_account() {
    local email; email=$(normalize "${1:-}")
    valid_email "$email" && user_exists "$email" || { log ERROR "Compte introuvable : '${email}'"; return 1; }
    local dir="${VMAIL_DIR}/${email#*@}/${email%@*}"

    echo -e "  ${RED}${BOLD}Suppression définitive de ${email}${RESET}"
    confirm "Confirmer la suppression du compte ?" || { log INFO "Annulé."; return 0; }
    db "DELETE FROM users WHERE email='${email}'"
    log OK "Compte ${email} supprimé de la base."

    # Alias qui redirigent vers ce compte (seul ou dans une liste "a,b,c")
    local rows; rows=$(db "SELECT source, destination FROM aliases WHERE FIND_IN_SET('${email}', REPLACE(destination, ' ', ''))")
    if [[ -n "$rows" ]]; then
        log WARN "Alias redirigeant vers ${email} : $(cut -f1 <<< "$rows" | tr '\n' ' ')"
        if confirm "Retirer ${email} de ces alias (alias supprimé s'il ne redirige plus vers personne) ?"; then
            local src dst rest
            while IFS=$'\t' read -r src dst; do
                rest=$(tr -d ' ' <<< "$dst" | tr ',' '\n' | grep -vxF "$email" | paste -sd, || true)
                if [[ -z "$rest" ]]; then
                    db "DELETE FROM aliases WHERE source='${src}'"; log OK "Alias ${src} supprimé."
                else
                    db "UPDATE aliases SET destination='${rest}' WHERE source='${src}'"; log OK "Alias ${src} → ${rest}"
                fi
            done <<< "$rows"
        fi
    fi

    if [[ -d "$dir" ]]; then
        if confirm "Supprimer aussi les mails stockés ($(du -sh "$dir" | cut -f1) dans ${dir}) ?"; then
            rm -rf -- "$dir"
            log OK "Boîte ${dir} supprimée."
        else
            log INFO "Mails conservés dans ${dir}."
        fi
    fi
}

# add_alias SOURCE DEST[,DEST2,...]
add_alias() {
    local src; src=$(normalize "${1:-}")
    local dst; dst=$(normalize "${2:-}")
    valid_email "$src" || { log ERROR "Adresse source invalide : '${src}'"; return 1; }
    [[ -n "$dst" ]] || { log ERROR "Destination manquante."; return 1; }
    local d
    IFS=',' read -ra dests <<< "$dst"
    for d in "${dests[@]}"; do
        valid_email "$d" || { log ERROR "Destination invalide : '${d}'"; return 1; }
    done
    if user_exists "$src"; then
        log ERROR "${src} est une vraie boîte mail — un alias du même nom serait ignoré."; return 1
    fi
    ensure_domain "${src#*@}" || return 1

    if alias_exists "$src"; then
        db "UPDATE aliases SET destination='${dst}', active=1 WHERE source='${src}'"
        log OK "Alias mis à jour : ${src} → ${dst}"
    else
        db "INSERT INTO aliases (source, destination) VALUES ('${src}', '${dst}')"
        log OK "Alias créé : ${src} → ${dst}"
    fi
}

remove_alias() {
    local src; src=$(normalize "${1:-}")
    valid_email "$src" && alias_exists "$src" || { log ERROR "Alias introuvable : '${src}'"; return 1; }
    db "DELETE FROM aliases WHERE source='${src}'"
    log OK "Alias ${src} supprimé."
}

# import FICHIER — une ligne "email" ou "email;motdepasse"
import_file() {
    local file="${1:-}"
    [[ -f "$file" ]] || { log ERROR "Fichier introuvable : '${file}'"; return 1; }
    log STEP "Import des comptes depuis ${file}"
    local ok=0 ko=0 line email pass
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        email="${line%%;*}"; pass=""
        [[ "$line" == *";"* ]] && pass="${line#*;}"
        # Les mots de passe générés sont affichés par add_account
        if NONINTERACTIVE=1 add_account "$email" "$pass"; then
            ok=$((ok + 1))
        else
            ko=$((ko + 1))
        fi
    done < "$file"
    log OK "Import terminé : ${ok} créé(s), ${ko} ignoré(s)."
}

show_client_settings() {
    local host="mail.${DOMAIN:-<votre-domaine>}"
    echo -e "\n  ${CYAN}${BOLD}Réglages à saisir dans le client mail (Thunderbird, téléphone…)${RESET}"
    echo -e "  Identifiant     : l'adresse complète (ex : prenom@${DOMAIN:-domaine.fr})"
    echo -e "  IMAP entrant    : ${BOLD}${host}${RESET}  port ${BOLD}993${RESET}  SSL/TLS"
    echo -e "  SMTP sortant    : ${BOLD}${host}${RESET}  port ${BOLD}587${RESET}  STARTTLS, mot de passe normal"
}

# ---------------------------------------------------------------------------
# Menu interactif
# ---------------------------------------------------------------------------
menu() {
    while true; do
        echo -e "\n${CYAN}${BOLD}  📧 Gestion des comptes mail${DOMAIN:+ — ${DOMAIN}}${RESET}\n"
        echo -e "  ${CYAN}[1]${RESET} Ajouter un compte"
        echo -e "  ${CYAN}[2]${RESET} Lister les comptes et alias"
        echo -e "  ${CYAN}[3]${RESET} Changer un mot de passe"
        echo -e "  ${CYAN}[4]${RESET} Désactiver un compte"
        echo -e "  ${CYAN}[5]${RESET} Réactiver un compte"
        echo -e "  ${CYAN}[6]${RESET} Supprimer un compte"
        echo -e "  ${CYAN}[7]${RESET} Ajouter / modifier un alias (redirection)"
        echo -e "  ${CYAN}[8]${RESET} Supprimer un alias"
        echo -e "  ${CYAN}[9]${RESET} Importer des comptes depuis un fichier"
        echo -e "  ${CYAN}[0]${RESET} Retour\n"
        local choice
        read -rp "$(echo -e "  ${BOLD}Votre choix : ${RESET}")" choice
        case "$choice" in
            1) add_account "$(ask_email "Adresse du nouveau compte")" && show_client_settings || true ;;
            2) list_accounts ;;
            3) change_password "$(ask_email "Adresse du compte")" || true ;;
            4) set_active "$(ask_email "Adresse à désactiver")" 0 || true ;;
            5) set_active "$(ask_email "Adresse à réactiver")" 1 || true ;;
            6) delete_account "$(ask_email "Adresse à supprimer")" || true ;;
            7)
                local src dst
                src=$(ask_email "Adresse de l'alias (ex : contact)")
                read -rp "$(echo -e "  ${CYAN}Rediriger vers (adresses séparées par des virgules) : ${RESET}")" dst
                add_alias "$src" "$dst" || true ;;
            8) remove_alias "$(ask_email "Alias à supprimer")" || true ;;
            9)
                local f
                read -rp "$(echo -e "  ${CYAN}Chemin du fichier : ${RESET}")" f
                import_file "$f" || true ;;
            0|q) return 0 ;;
            *) log WARN "Choix invalide : ${choice}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
cmd="${1:-menu}"
case "$cmd" in
    menu)    menu ;;
    add)     add_account "${2:-$(ask_email "Adresse du nouveau compte")}" && show_client_settings ;;
    list|ls) list_accounts ;;
    passwd)  change_password "${2:?Usage : $0 passwd email}" ;;
    disable) set_active "${2:?Usage : $0 disable email}" 0 ;;
    enable)  set_active "${2:?Usage : $0 enable email}" 1 ;;
    delete|del|rm) delete_account "${2:?Usage : $0 delete email}" ;;
    alias)   add_alias "${2:?Usage : $0 alias source destination}" "${3:?Usage : $0 alias source destination}" ;;
    unalias) remove_alias "${2:?Usage : $0 unalias source}" ;;
    import)  import_file "${2:?Usage : $0 import fichier.txt}" ;;
    -h|--help|help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) log ERROR "Commande inconnue : ${cmd} (voir : $0 help)"; exit 1 ;;
esac
