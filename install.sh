#!/bin/bash
# =============================================================================
#  Install_Server_Ubuntu — Script principal d'installation
#  Auteur   : Laurent Lebarbier
#  Version  : 2.1
#  Licence  : MIT
# =============================================================================
#
#  Deux rôles possibles, choisis à la configuration initiale :
#    • web   : serveur web + mail (VPS) — sites, WordPress, mail, FTP
#    • cloud : serveur de stockage (dédié) — Nextcloud + Immich, sans mail
#              ni FTP ; le mail du domaine reste sur le serveur « web »
#
#  Ce script orchestre l'installation complète d'un serveur Ubuntu :
#    1. Vérification du compte système existant (aucun compte ni mot de
#       passe système créé : connexion SSH par clé sur le compte actuel)
#    2. Configuration du pare-feu UFW (ports selon le rôle)
#    3. Stack LAMP (Apache, MariaDB, PHP, phpMyAdmin — sans phpMyAdmin
#       ni site principal en rôle cloud)
#    4. Serveur mail (Postfix + Dovecot + OpenDKIM)          — rôle web
#    5. Serveur FTP sécurisé (Pure-FTPd + SFTP)              — rôle web
#    6. Sécurisation SSH (authentification par clé uniquement)
#    7. Installation de WordPress                            — rôle web
#    8. Gestion des comptes mail     (manage_mail.sh       — menu [9])
#    9. Gestion des sous-domaines    (manage_subdomains.sh — menu [10],
#                                     Apache + certificat Let's Encrypt)
#   10. Sauvegarde du serveur        (backup_server.sh     — menu [11])
#       Restauration / migration     (restore_server.sh, voir README)
#   11. Serveur cloud                (install_cloud.sh     — menu [12],
#                                     Nextcloud, Immich, RAID, alertes)
#   12. Sauvegarde croisée           (backup_remote.sh     — menu [13],
#                                     envoi chiffré nocturne vers l'autre serveur)
#
#  Usage : sudo bash install.sh
# =============================================================================

set -euo pipefail          # Arrêt immédiat sur erreur, variable non définie, ou pipe cassé

# Journal d'installation : tout l'affichage est aussi écrit dans
# /var/log/install_server/ (voir lib_log.sh)
# shellcheck source=lib_log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_log.sh" 2>/dev/null && start_install_log "$@"
IFS=$'\n\t'                # Séparateur de champ sûr

# ---------------------------------------------------------------------------
# 0. COULEURS & HELPERS
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# Affiche une bannière ASCII colorée
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║         🚀  Install Server Ubuntu  v2.2                  ║"
    echo "  ║         Configuration complète & sécurisée               ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# log [NIVEAU] message
log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)    echo -e "${GREEN}[INFO ]${RESET} ${ts} — $*" ;;
        WARN)    echo -e "${YELLOW}[WARN ]${RESET} ${ts} — $*" ;;
        ERROR)   echo -e "${RED}[ERROR]${RESET} ${ts} — $*" ;;
        STEP)    echo -e "\n${MAGENTA}${BOLD}▶ $*${RESET}" ;;
        OK)      echo -e "${GREEN}${BOLD}  ✔  $*${RESET}" ;;
    esac
    # Journalisation dans /var/log/install_server.log
    echo "[$level] $ts — $*" >> /var/log/install_server.log 2>/dev/null || true
}

# Demande une confirmation (O/n)
confirm() {
    local prompt="${1:-Continuer ?}"
    local answer
    read -rp "$(echo -e "${YELLOW}  ❓ $prompt [O/n] : ${RESET}")" answer
    [[ "${answer,,}" =~ ^(o|oui|y|yes|)$ ]]
}

# Vérifie qu'une commande existe
need_cmd() {
    command -v "$1" &>/dev/null || { log ERROR "Commande introuvable : $1"; exit 1; }
}

# Pause avant de continuer
pause() {
    echo -e "\n${BLUE}  Appuyez sur [Entrée] pour continuer...${RESET}"
    read -r
}

# ---------------------------------------------------------------------------
# 1. VÉRIFICATIONS PRÉLIMINAIRES
# ---------------------------------------------------------------------------
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}${BOLD}  ✖  Ce script doit être exécuté en tant que root.${RESET}"
        echo -e "     Relancez avec : ${CYAN}sudo bash $0${RESET}"
        exit 1
    fi
}

check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log ERROR "Système d'exploitation non reconnu."; exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log WARN "Ce script est optimisé pour Ubuntu (détecté : $ID). Continuez à vos risques."
        confirm "Continuer malgré tout ?" || exit 0
    fi
    log INFO "Système : $PRETTY_NAME"
}

# ---------------------------------------------------------------------------
# 2. CONFIGURATION INITIALE — DOMAINE, UTILISATEUR, MOT DE PASSE
# ---------------------------------------------------------------------------

# Fichier de configuration persistant (source par les autres scripts)
CONFIG_FILE="$(dirname "$0")/server.conf"
readonly CONFIG_FILE

collect_config() {
    log STEP "Configuration initiale du serveur"

    # --- Rôle du serveur ---
    echo -e "\n${BOLD}  🧭 Rôle de ce serveur${RESET}"
    echo -e "     ${CYAN}[1]${RESET} Web + mail  (VPS : sites, WordPress, mail, FTP)"
    echo -e "     ${CYAN}[2]${RESET} Cloud       (dédié : Nextcloud + Immich, sans mail ni FTP —"
    echo -e "                   le mail du domaine reste sur le serveur web)"
    echo -e "     ${CYAN}[3]${RESET} Complet     (un seul dédié : sites, WordPress, mail, FTP"
    echo -e "                   + Nextcloud + Immich — remplace VPS + dédié)"
    local role_choice
    read -rp "$(echo -e "  ${CYAN}Rôle [1] : ${RESET}")" role_choice
    case "${role_choice:-1}" in
        2|cloud)   SERVER_ROLE="cloud" ;;
        3|complet) SERVER_ROLE="complet" ;;
        *)         SERVER_ROLE="web" ;;
    esac

    # --- Nom de domaine ---
    local domain_default="exemple.fr"
    echo -e "\n${BOLD}  📌 Nom de domaine principal${RESET}"
    if [[ "$SERVER_ROLE" == "cloud" ]]; then
        echo -e "     (le même que le serveur web : ce serveur n'utilisera que des"
        echo -e "      sous-domaines, ex : cloud.<domaine> et photos.<domaine>)"
    else
        echo -e "     (utilisé pour Apache, le mail, les certificats SSL)"
    fi
    read -rp "$(echo -e "  ${CYAN}Domaine [${domain_default}] : ${RESET}")" DOMAIN
    DOMAIN="${DOMAIN:-$domain_default}"

    # Validation basique du domaine
    if ! echo "$DOMAIN" | grep -qP '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
        log ERROR "Format de domaine invalide : $DOMAIN"; exit 1
    fi

    # --- Compte système (existant, non créé) ---
    # Aucun compte ni mot de passe système n'est créé : on réutilise le compte
    # avec lequel vous êtes connecté en SSH par clé (ex : « ubuntu » chez OVH).
    # Il sert de propriétaire des fichiers des sites, de base au nom du
    # compte FTP et de destination des sauvegardes.
    local user_default="${SUDO_USER:-}"
    [[ -z "$user_default" || "$user_default" == "root" ]] && user_default="ubuntu"
    echo -e "\n${BOLD}  👤 Compte administrateur Linux (existant)${RESET}"
    echo -e "     (le compte avec lequel vous vous connectez en SSH par clé —"
    echo -e "      il n'est ni créé ni modifié, aucun mot de passe n'est demandé)"
    read -rp "$(echo -e "  ${CYAN}Nom d'utilisateur [${user_default}] : ${RESET}")" SYS_USER
    SYS_USER="${SYS_USER:-$user_default}"

    if ! id "$SYS_USER" &>/dev/null; then
        log ERROR "Le compte « $SYS_USER » n'existe pas sur ce serveur."
        log ERROR "Indiquez le compte avec lequel vous vous connectez en SSH (ex : ubuntu)."
        exit 1
    fi

    # --- Compte MariaDB (utilisateur + mot de passe, sans base) ---
    echo -e "\n${BOLD}  🗄️  Compte MariaDB${RESET}"
    echo -e "     (compte administrateur MariaDB, utilisable dans phpMyAdmin —"
    echo -e "      aucune base n'est créée : créez-les ensuite selon vos besoins)"
    read -rp "$(echo -e "  ${CYAN}Utilisateur MariaDB [${SYS_USER}] : ${RESET}")" DB_USER
    DB_USER="${DB_USER:-$SYS_USER}"
    if ! echo "$DB_USER" | grep -qP '^[A-Za-z0-9_]{1,80}$'; then
        log ERROR "Nom d'utilisateur MariaDB invalide (lettres, chiffres, _) : $DB_USER"
        exit 1
    fi
    local DB_PASS DB_PASS2
    while true; do
        read -rsp "$(echo -e "  ${CYAN}Mot de passe MariaDB : ${RESET}")" DB_PASS; echo
        read -rsp "$(echo -e "  ${CYAN}Confirmez           : ${RESET}")" DB_PASS2; echo
        if [[ "$DB_PASS" != "$DB_PASS2" ]]; then
            log WARN "Les mots de passe ne correspondent pas."
        elif [[ ${#DB_PASS} -lt 12 ]]; then
            log WARN "Le mot de passe doit contenir au moins 12 caractères."
        elif [[ "$DB_PASS" == *'"'* || "$DB_PASS" == *'$'* || "$DB_PASS" == *'`'* || "$DB_PASS" == *'\'* ]]; then
            # server.conf est un fichier shell (source) : ces caractères le casseraient
            log WARN "Évitez les caractères \" \$ \` et \\ dans le mot de passe."
        else
            break
        fi
    done

    # --- Adresse e-mail admin ---
    local ADMIN_EMAIL_DEFAULT="admin@${DOMAIN}"
    read -rp "$(echo -e "  ${CYAN}Email administrateur [${ADMIN_EMAIL_DEFAULT}] : ${RESET}")" ADMIN_EMAIL
    ADMIN_EMAIL="${ADMIN_EMAIL:-$ADMIN_EMAIL_DEFAULT}"

    # --- IP publique ---
    local detected_ip
    detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    echo -e "\n${BOLD}  🌐 Adresse IP publique du serveur${RESET}"
    read -rp "$(echo -e "  ${CYAN}IP publique [${detected_ip}] : ${RESET}")" SERVER_IP
    SERVER_IP="${SERVER_IP:-$detected_ip}"

    # --- Récapitulatif ---
    echo -e "\n${CYAN}${BOLD}  ┌─────────────────────────────────────────┐"
    echo    "  │         📋 Récapitulatif                 │"
    echo    "  └─────────────────────────────────────────┘${RESET}"
    echo -e "  Rôle            : ${BOLD}${SERVER_ROLE}${RESET}"
    echo -e "  Domaine         : ${BOLD}${DOMAIN}${RESET}"
    [[ "$SERVER_ROLE" != "cloud" ]] && echo -e "  Hostname mail   : ${BOLD}mail.${DOMAIN}${RESET}"
    echo -e "  Compte système  : ${BOLD}${SYS_USER}${RESET} (existant, non modifié)"
    echo -e "  Compte MariaDB  : ${BOLD}${DB_USER}${RESET}"
    echo -e "  Email admin     : ${BOLD}${ADMIN_EMAIL}${RESET}"
    echo -e "  IP publique     : ${BOLD}${SERVER_IP}${RESET}"
    echo

    confirm "Ces informations sont-elles correctes ?" || { log WARN "Configuration annulée."; exit 0; }

    # Sauvegarde dans server.conf (chargé par les sous-scripts)
    cat > "$CONFIG_FILE" <<EOF
# server.conf — Généré automatiquement par install.sh
# NE PAS modifier manuellement sauf si vous savez ce que vous faites.
SERVER_ROLE="${SERVER_ROLE}"
DOMAIN="${DOMAIN}"
HOSTNAME_MAIL="mail.${DOMAIN}"
SYS_USER="${SYS_USER}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
SERVER_IP="${SERVER_IP}"
EOF
    chmod 600 "$CONFIG_FILE"
    log OK "Configuration sauvegardée dans server.conf"
}

# ---------------------------------------------------------------------------
# 3. VÉRIFICATION DU COMPTE SYSTÈME (aucune création)
# ---------------------------------------------------------------------------
check_system_user() {
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    log STEP "Compte système : ${SYS_USER:-?}"

    if [[ -n "${SYS_USER:-}" ]] && id "$SYS_USER" &>/dev/null; then
        log OK "Le compte $SYS_USER existe — mot de passe et clés SSH laissés inchangés."
        return 0
    fi

    # Cas d'un server.conf restauré depuis un autre serveur dont le compte
    # n'existe pas ici : on propose le compte de la session SSH actuelle.
    log WARN "Le compte « ${SYS_USER:-} » (server.conf) n'existe pas sur ce serveur."
    local current="${SUDO_USER:-}"
    if [[ -n "$current" && "$current" != "root" ]] && id "$current" &>/dev/null \
        && confirm "Utiliser le compte de cette session SSH (« $current ») ?"; then
        if grep -q '^SYS_USER=' "$CONFIG_FILE"; then
            sed -i "s|^SYS_USER=.*|SYS_USER=\"${current}\"|" "$CONFIG_FILE"
        else
            echo "SYS_USER=\"${current}\"" >> "$CONFIG_FILE"
        fi
        log OK "SYS_USER = ${current}"
    else
        log ERROR "Corrigez SYS_USER dans server.conf (compte SSH existant), puis relancez."
        exit 1
    fi
}

# Vérifie que SERVER_IP (server.conf) est bien l'IP publique de CE serveur
check_server_ip() {
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    local current
    current=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    [[ -z "$current" || "$current" == "${SERVER_IP:-}" ]] && return 0
    log WARN "server.conf indique l'IP ${SERVER_IP:-?}, mais ce serveur a l'IP ${current}."
    if confirm "Mettre à jour SERVER_IP avec ${current} ?"; then
        sed -i "s|^SERVER_IP=.*|SERVER_IP=\"${current}\"|" "$CONFIG_FILE"
        log OK "SERVER_IP = ${current}"
    fi
}

# ---------------------------------------------------------------------------
# 3bis. SÉCURISATION SSH — AUTHENTIFICATION PAR CLÉ UNIQUEMENT
# ---------------------------------------------------------------------------
secure_ssh() {
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    log STEP "Sécurisation SSH (authentification par clé uniquement)"

    local authorized_keys_file="/home/${SYS_USER}/.ssh/authorized_keys"
    [[ "$SYS_USER" == "root" ]] && authorized_keys_file="/root/.ssh/authorized_keys"

    if [[ ! -s "$authorized_keys_file" ]]; then
        log WARN "Aucune clé SSH trouvée pour $SYS_USER ($authorized_keys_file absent ou vide)."
        log WARN "Authentification par mot de passe conservée, pour ne pas vous couper l'accès."
        return
    fi

    echo -e "\n${BOLD}  🔐 Authentification SSH par clé uniquement${RESET}"
    echo -e "     Une clé a été détectée pour ${SYS_USER}. Cette étape désactive"
    echo -e "     ${BOLD}la connexion SSH par mot de passe${RESET} (root inclus) sur ce serveur."
    echo -e "     ${YELLOW}⚠  Testez d'abord votre connexion par clé dans un AUTRE terminal${RESET}"
    echo -e "     ${YELLOW}   avant de continuer, pour ne pas vous verrouiller dehors.${RESET}"
    confirm "Désactiver l'authentification SSH par mot de passe ?" || {
        log WARN "Authentification par mot de passe SSH conservée (aucun changement)."
        return
    }

    local sshd_config="/etc/ssh/sshd_config"
    local backup
    backup="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$sshd_config" "$backup"

    sed -i -E 's/^#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' "$sshd_config"
    sed -i -E 's/^#?[[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin prohibit-password/' "$sshd_config"
    sed -i -E 's/^#?[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/' "$sshd_config"
    sed -i -E 's/^#?[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/' "$sshd_config"
    grep -q "^PasswordAuthentication" "$sshd_config" || echo "PasswordAuthentication no" >> "$sshd_config"
    grep -q "^PermitRootLogin"        "$sshd_config" || echo "PermitRootLogin prohibit-password" >> "$sshd_config"

    # Ubuntu 22.04+ inclut souvent un override dans sshd_config.d/ qui
    # prendrait le dessus sur les directives ci-dessus — on l'aligne aussi.
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] || continue
            sed -i -E 's/^#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' "$f"
        done
    fi

    if sshd -t; then
        systemctl restart ssh
        log OK "SSH restreint à l'authentification par clé (mot de passe désactivé)."
    else
        log ERROR "Erreur de syntaxe dans sshd_config — restauration de la sauvegarde."
        cp "$backup" "$sshd_config"
        systemctl restart ssh
        log WARN "Aucun changement appliqué."
    fi
}

# ---------------------------------------------------------------------------
# 4. MENU PRINCIPAL
# ---------------------------------------------------------------------------
# Rôle lu dans server.conf (« web » par défaut pour les anciens fichiers)
server_role() {
    local r
    r=$(grep -m1 '^SERVER_ROLE=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    echo "${r:-web}"
}

show_menu() {
    local role; role=$(server_role)
    banner
    if [[ "$role" == "cloud" ]]; then
        echo -e "  Rôle : ${BOLD}☁️  cloud${RESET} (Nextcloud + Immich, sans mail ni FTP)\n"
    elif [[ "$role" == "complet" ]]; then
        echo -e "  Rôle : ${BOLD}🧩 complet${RESET} (web + mail + FTP + Nextcloud + Immich)\n"
    else
        echo -e "  Rôle : ${BOLD}🌐 web + mail${RESET}\n"
    fi
    echo -e "  ${BOLD}Que souhaitez-vous installer ?${RESET}\n"
    echo -e "  ${CYAN}[1]${RESET} 🔒 Pare-feu UFW"
    if [[ "$role" == "cloud" ]]; then
        echo -e "  ${CYAN}[2]${RESET} 🌐 Stack LAMP  (Apache + MariaDB + PHP — sans phpMyAdmin ni site principal)"
        echo -e "  ${CYAN}[5]${RESET} ✅ Installation complète (1+2+12)"
    else
        echo -e "  ${CYAN}[2]${RESET} 🌐 Stack LAMP  (Apache + MariaDB + PHP + phpMyAdmin + SSL)"
        echo -e "  ${CYAN}[3]${RESET} 📧 Serveur Mail (Postfix + Dovecot + OpenDKIM)"
        echo -e "  ${CYAN}[4]${RESET} 📁 Serveur FTP  (Pure-FTPd + SFTP)"
        if [[ "$role" == "complet" ]]; then
            echo -e "  ${CYAN}[5]${RESET} ✅ Installation complète (1+2+3+4+12)"
        else
            echo -e "  ${CYAN}[5]${RESET} ✅ Installation complète (1+2+3+4)"
        fi
    fi
    echo -e "  ${CYAN}[6]${RESET} 🔐 Sécuriser SSH (clé uniquement, désactive le mot de passe)"
    [[ "$role" == "cloud" ]] || echo -e "  ${CYAN}[7]${RESET} 📝 Installer WordPress (nécessite la stack LAMP)"
    echo -e "  ${CYAN}[8]${RESET} ℹ️  Afficher la configuration actuelle"
    [[ "$role" == "cloud" ]] || echo -e "  ${CYAN}[9]${RESET} 👥 Gérer les comptes mail (ajout, alias, mots de passe…)"
    echo -e "  ${CYAN}[10]${RESET} 🌍 Gérer les sous-domaines (Apache + SSL Let's Encrypt)"
    echo -e "  ${CYAN}[11]${RESET} 💾 Sauvegarder le serveur (pour migration / réinstallation)"
    if [[ "$role" == "cloud" || "$role" == "complet" ]]; then
        echo -e "  ${CYAN}[12]${RESET} ☁️  Cloud : Nextcloud, Immich, RAID, alertes, Fail2Ban"
    fi
    echo -e "  ${CYAN}[13]${RESET} 🔁 Sauvegarde croisée vers l'autre serveur (chaque nuit)"
    echo -e "  ${CYAN}[0]${RESET} 🚪 Quitter\n"
    read -rp "$(echo -e "  ${BOLD}Votre choix : ${RESET}")" CHOICE
}

# Garde-fou : les options mail / FTP / WordPress n'ont rien à faire en rôle cloud
web_only() {
    if [[ "$(server_role)" == "cloud" ]]; then
        log WARN "Option prévue pour le serveur web + mail : ce serveur a le rôle « cloud »."
        log WARN "(un 2e serveur mail pour le même domaine casserait SPF/MX.)"
        confirm "L'installer quand même ?" || return 1
    fi
}

# Un sous-script a échoué : on le signale sans quitter le menu
run_failed() {
    log WARN "$1 s'est arrêté sur une erreur (voir ci-dessus) — relancez-le seul depuis le menu une fois corrigé."
}

show_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        banner
        echo -e "  ${BOLD}Configuration actuelle (server.conf) :${RESET}\n"
        # Masque les mots de passe
        grep -v 'PASS' "$CONFIG_FILE" | grep -v '^#' | grep -v '^$' | \
            sed 's/^/  /' | sed 's/="/ = /;s/"$//'
        grep -o '^[A-Z_]*PASS[A-Z_]*=' "$CONFIG_FILE" | tr -d '=' | while read -r k; do
            echo -e "  ${k} = ${YELLOW}[masqué]${RESET}"
        done
    else
        log WARN "Aucune configuration trouvée. Lancez d'abord la configuration initiale."
    fi
    pause
}

# ---------------------------------------------------------------------------
# 5. POINT D'ENTRÉE
# ---------------------------------------------------------------------------
main() {
    check_root
    banner
    check_ubuntu

    # Configuration initiale si server.conf absent
    if [[ ! -f "$CONFIG_FILE" ]]; then
        collect_config
        check_system_user
    else
        log INFO "Configuration existante détectée (server.conf)."
        if confirm "Reconfigurer depuis zéro ?"; then
            collect_config
            check_system_user
        else
            # Cas d'un server.conf restauré (restore_server.sh prepare) sur un
            # serveur neuf : le compte système peut porter un autre nom, et
            # l'IP publique a pu changer.
            check_system_user
            check_server_ip
        fi
    fi

    # Mise à jour système préliminaire
    log STEP "Mise à jour du système"
    apt-get update -qq && apt-get upgrade -y -qq
    apt-get install -y -qq curl wget unzip gnupg2 software-properties-common \
        ca-certificates apt-transport-https lsb-release
    log OK "Système à jour."

    # Boucle de menu
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    while true; do
        show_menu
        case "$CHOICE" in
            1) bash "$SCRIPT_DIR/install_firewall.sh" || run_failed install_firewall.sh ;;
            2) bash "$SCRIPT_DIR/install_lamp.sh" || run_failed install_lamp.sh ;;
            3) web_only && { bash "$SCRIPT_DIR/install_mail.sh" || run_failed install_mail.sh; } ;;
            4) web_only && { bash "$SCRIPT_DIR/install_ftp.sh" || run_failed install_ftp.sh; } ;;
            5)
                bash "$SCRIPT_DIR/install_firewall.sh" || run_failed install_firewall.sh
                bash "$SCRIPT_DIR/install_lamp.sh"     || run_failed install_lamp.sh
                # « || run_failed » : un sous-script en échec ne fait plus
                # quitter install.sh (set -e) — les étapes suivantes tournent
                case "$(server_role)" in
                    cloud)
                        bash "$SCRIPT_DIR/install_cloud.sh" tout || run_failed install_cloud.sh ;;
                    complet)
                        # Mail AVANT le cloud : install_cloud.sh voit Postfix et
                        # s'en sert pour les alertes (pas de relais msmtp)
                        bash "$SCRIPT_DIR/install_mail.sh"  || run_failed install_mail.sh
                        bash "$SCRIPT_DIR/install_ftp.sh"   || run_failed install_ftp.sh
                        bash "$SCRIPT_DIR/install_cloud.sh" tout || run_failed install_cloud.sh ;;
                    *)
                        bash "$SCRIPT_DIR/install_mail.sh" || run_failed install_mail.sh
                        bash "$SCRIPT_DIR/install_ftp.sh"  || run_failed install_ftp.sh ;;
                esac
                ;;
            6) secure_ssh ;;
            7) web_only && { bash "$SCRIPT_DIR/install_wordpress.sh" || run_failed install_wordpress.sh; } ;;
            8) show_config ;;
            9) bash "$SCRIPT_DIR/manage_mail.sh" || true ;;
            10) bash "$SCRIPT_DIR/manage_subdomains.sh" || true ;;
            11) bash "$SCRIPT_DIR/backup_server.sh" || true ;;
            12) bash "$SCRIPT_DIR/install_cloud.sh" || true ;;
            13) bash "$SCRIPT_DIR/backup_remote.sh" || true ;;
            0) echo -e "\n${GREEN}  Au revoir !${RESET}\n"; exit 0 ;;
            *) log WARN "Choix invalide : $CHOICE" ;;
        esac
        pause
    done
}

main "$@"
