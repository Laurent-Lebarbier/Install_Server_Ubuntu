#!/bin/bash
# =============================================================================
#  install_firewall.sh — Configuration du pare-feu UFW
#  Auteur  : Laurent Lebarbier
#  Version : 2.0
# =============================================================================
#
#  Ce script configure UFW (Uncomplicated Firewall) avec les règles
#  nécessaires pour un serveur web + mail + FTP sécurisé.
#
#  Ports ouverts :
#    - 22/tcp   → SSH
#    - 80/tcp   → HTTP  (Apache)
#    - 443/tcp  → HTTPS (Apache + SSL)
#    - 25/tcp   → SMTP  (réception de mails entrants)
#    - 587/tcp  → SMTP Submission (envoi authentifié — clients mail)
#    - 993/tcp  → IMAP over TLS  (lecture des mails)
#    - 995/tcp  → POP3 over TLS  (lecture des mails alternatif)
#    - 53/tcp+udp → DNS (si bind9 installé)
#    - 20/tcp   → FTP data
#    - 21/tcp   → FTP commande
#    - 40000:50000/tcp → FTP passif
#
#  Rôle « cloud » (server.conf : SERVER_ROLE="cloud") : seulement 22, 80, 443
#  — pas de mail ni de FTP sur ce serveur.
#  Note : Docker (Immich) contourne UFW pour ses ports publiés ; install_cloud.sh
#  ne publie donc le port d'Immich que sur 127.0.0.1.
#
#  Usage : sudo bash install_firewall.sh
#          Ou via le menu principal install.sh
# =============================================================================

set -euo pipefail

# Journal d'installation : tout l'affichage est aussi écrit dans
# /var/log/install_server/ (voir lib_log.sh)
# shellcheck source=lib_log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_log.sh" 2>/dev/null && start_install_log "$@"
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Couleurs & helpers (dupliqués pour usage standalone)
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
# Vérifications
# ---------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"; exit 1
fi

# Rôle du serveur (facultatif : sans server.conf, profil web + mail complet)
SERVER_ROLE="web"
CONFIG_FILE="$(dirname "$0")/server.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=./server.conf
    source "$CONFIG_FILE"
    SERVER_ROLE="${SERVER_ROLE:-web}"
fi

log STEP "Configuration du pare-feu UFW (rôle : ${SERVER_ROLE})"

# ---------------------------------------------------------------------------
# Installation de UFW si absent
# ---------------------------------------------------------------------------
if ! command -v ufw &>/dev/null; then
    log INFO "Installation de UFW..."
    apt-get install -y -qq ufw
fi

# ---------------------------------------------------------------------------
# Réinitialisation (optionnel — évite les règles dupliquées)
# ---------------------------------------------------------------------------
log INFO "Réinitialisation des règles UFW..."
ufw --force reset

# Politique par défaut : tout refuser en entrée, tout autoriser en sortie
ufw default deny incoming
ufw default allow outgoing

# ---------------------------------------------------------------------------
# Règles — SSH
# ---------------------------------------------------------------------------
log INFO "Autorisation de SSH (port 22)..."
ufw allow 22/tcp comment "SSH — accès administrateur"

# ---------------------------------------------------------------------------
# Règles — Web (Apache)
# ---------------------------------------------------------------------------
log INFO "Autorisation HTTP/HTTPS (Apache)..."
ufw allow 80/tcp  comment "HTTP  — Apache"
ufw allow 443/tcp comment "HTTPS — Apache + SSL"

if [[ "$SERVER_ROLE" == "cloud" ]]; then
    log INFO "Rôle cloud : pas de ports mail ni FTP."
else
    # ---------------------------------------------------------------------------
    # Règles — Serveur mail
    # ---------------------------------------------------------------------------
    log INFO "Autorisation des ports mail..."

    # Port 25  : SMTP entrant (réception des mails depuis d'autres serveurs)
    ufw allow 25/tcp  comment "SMTP — réception mails entrants (MTA → MTA)"

    # Port 587 : SMTP Submission (envoi authentifié par vos clients mail : Thunderbird, Outlook...)
    #            Préféré à 465 (SMTPS implicite, obsolète) pour l'envoi des utilisateurs
    ufw allow 587/tcp comment "SMTP Submission — envoi authentifié (clients mail)"

    # Port 993 : IMAP sécurisé (lecture des mails via TLS — recommandé)
    ufw allow 993/tcp comment "IMAPS — lecture mails sécurisée"

    # Port 995 : POP3 sécurisé (téléchargement des mails — moins courant qu'IMAP)
    ufw allow 995/tcp comment "POP3S — téléchargement mails sécurisé"

    # ---------------------------------------------------------------------------
    # Règles — FTP (Pure-FTPd)
    # ---------------------------------------------------------------------------
    log INFO "Autorisation des ports FTP..."
    ufw allow 21/tcp comment "FTP — contrôle"
    ufw allow 20/tcp comment "FTP — données (mode actif)"

    # Mode passif FTP : plage de ports à configurer aussi dans Pure-FTPd
    # (voir install_ftp.sh — PassivePortRange 40000 50000)
    ufw allow 40000:50000/tcp comment "FTP passif — plage de ports"

fi

# ---------------------------------------------------------------------------
# Règles — DNS (décommenter si vous installez bind9)
# ---------------------------------------------------------------------------
# log INFO "Autorisation du service DNS..."
# ufw allow 53/tcp comment "DNS — TCP"
# ufw allow 53/udp comment "DNS — UDP"

# ---------------------------------------------------------------------------
# Activation de UFW
# ---------------------------------------------------------------------------
log INFO "Activation de UFW..."
ufw --force enable

# ---------------------------------------------------------------------------
# Affichage du statut
# ---------------------------------------------------------------------------
log STEP "État final du pare-feu"
ufw status verbose

log OK "Pare-feu UFW configuré et activé avec succès."
