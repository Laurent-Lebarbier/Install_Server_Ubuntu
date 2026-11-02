#!/bin/bash
# =============================================================================
#  install_ftp.sh — Serveur FTP sécurisé (Pure-FTPd + SFTP)
#  Auteur  : Laurent Lebarbier
#  Version : 2.0
# =============================================================================
#
#  Ce script installe et configure deux méthodes d'accès aux fichiers :
#
#  1. Pure-FTPd (FTP)
#     - Utilisateurs virtuels (isolated, sans accès shell)
#     - Mode passif configuré (ports 40000-50000)
#     - Chroot automatique (l'utilisateur ne voit que son dossier)
#     - TLS/SSL sur FTP (FTPS explicite — AUTH TLS sur le port 21 standard,
#       à ne pas confondre avec le FTPS implicite du port 990, non utilisé ici)
#
#  2. SFTP (via OpenSSH)
#     - Chroot strict dans /home/ftpusers/<user>
#     - Accès en écriture uniquement dans le sous-dossier /uploads
#     - Transfert de fichiers uniquement (pas de shell)
#
#  L'utilisateur FTP/SFTP est un compte système dédié ("<SYS_USER>_ftp"),
#  distinct du compte admin sudo créé par install.sh. Cela évite de forcer
#  ForceCommand internal-sftp sur le compte admin et de lui couper son accès
#  shell SSH normal.
#
#  Connexion SFTP :
#    sftp <SYS_USER>_ftp@<SERVER_IP>
#    ou avec FileZilla : protocole SFTP, port 22
#
#  Usage : sudo bash install_ftp.sh
#          Ou via le menu principal install.sh
# =============================================================================

set -euo pipefail

# Journal d'installation : tout l'affichage est aussi écrit dans
# /var/log/install_server/ (voir lib_log.sh)
# shellcheck source=lib_log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_log.sh" 2>/dev/null && start_install_log "$@"
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Couleurs & helpers
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
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

readonly FTP_BASE_DIR="/home/ftpusers"
# Compte FTP/SFTP dédié, DISTINCT du compte admin système ($SYS_USER).
# $SYS_USER a un accès sudo + shell bash (créé par install.sh) : le
# Match User plus bas force ForceCommand internal-sftp, ce qui couperait
# tout accès shell SSH normal si on l'appliquait au même compte.
readonly FTP_USER="${SYS_USER}_ftp"
readonly FTP_HOME="${FTP_BASE_DIR}/${FTP_USER}"

log STEP "Installation du serveur FTP/SFTP"
log INFO "Utilisateur FTP (dédié, distinct de $SYS_USER) : $FTP_USER"
log INFO "Répertoire home : $FTP_HOME"

# ---------------------------------------------------------------------------
# 1. Installation de Pure-FTPd
# ---------------------------------------------------------------------------
log STEP "Installation de Pure-FTPd"
apt-get install -y pure-ftpd pure-ftpd-common openssl
log OK "Pure-FTPd installé."

# ---------------------------------------------------------------------------
# 2. Création du répertoire et de l'utilisateur FTP
# ---------------------------------------------------------------------------
log STEP "Création de l'utilisateur et des répertoires FTP"

mkdir -p "${FTP_HOME}/uploads"

# Création de l'utilisateur système dédié FTP/SFTP (sans shell, sans sudo)
if ! id "$FTP_USER" &>/dev/null; then
    useradd -d "$FTP_HOME" -s /sbin/nologin "$FTP_USER"
fi

# Permissions : la racine appartient à root (requis pour le chroot),
# seul /uploads est accessible en écriture à l'utilisateur
chown root:root "$FTP_HOME"
chmod 755 "$FTP_HOME"
chown "${FTP_USER}:${FTP_USER}" "${FTP_HOME}/uploads"
chmod 750 "${FTP_HOME}/uploads"

log OK "Répertoires créés : $FTP_HOME (racine root) / ${FTP_HOME}/uploads (écriture $FTP_USER)"

# ---------------------------------------------------------------------------
# 3. Création de l'utilisateur virtuel Pure-FTPd
# ---------------------------------------------------------------------------
log STEP "Création de l'utilisateur virtuel Pure-FTPd"

# Supprime l'ancien utilisateur virtuel s'il existe
pure-pw show "$FTP_USER" &>/dev/null && pure-pw userdel "$FTP_USER" || true

# Création de l'utilisateur virtuel avec son mot de passe
# (même mot de passe que le compte système $SYS_USER, par simplicité —
# changez-le ensuite avec : pure-pw passwd FTP_USER)
echo -e "${SYS_PASS}\n${SYS_PASS}" | \
    pure-pw useradd "$FTP_USER" \
        -u "$FTP_USER" \
        -d "$FTP_HOME" \
        -m     # -m : met à jour la base immédiatement

log OK "Utilisateur FTP virtuel $FTP_USER créé."

# ---------------------------------------------------------------------------
# 4. Configuration de Pure-FTPd
# ---------------------------------------------------------------------------
log STEP "Configuration de Pure-FTPd"

# Chroot : chaque utilisateur est enfermé dans son répertoire
echo "yes" | tee /etc/pure-ftpd/conf/ChrootEveryone

# Mode passif : plage de ports (à ouvrir dans le pare-feu)
echo "40000 50000" | tee /etc/pure-ftpd/conf/PassivePortRange

# IP publique annoncée aux clients en mode passif (indispensable sur un VPS,
# sinon les clients FTP peuvent recevoir une IP interne/NAT inutilisable)
echo "${SERVER_IP}" | tee /etc/pure-ftpd/conf/ForcePassiveIP

# Nombre maximum de connexions simultanées
echo "50" | tee /etc/pure-ftpd/conf/MaxClientsNumber
echo "8"  | tee /etc/pure-ftpd/conf/MaxClientsPerIP

# Désactiver les connexions anonymes
echo "yes" | tee /etc/pure-ftpd/conf/NoAnonymous

# Activer le lien vers la base d'utilisateurs virtuels
ln -sf /etc/pure-ftpd/conf/PureDB /etc/pure-ftpd/auth/50pure

# TLS/SSL sur FTP (FTPS)
# 0 = pas de TLS  |  1 = TLS optionnel  |  2 = TLS obligatoire
echo "1" | tee /etc/pure-ftpd/conf/TLS

# Certificat auto-signé pour Pure-FTPd (si Let's Encrypt non disponible)
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    cat "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
        "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" \
        > /etc/ssl/private/pure-ftpd.pem
else
    if [[ ! -f /etc/ssl/private/pure-ftpd.pem ]]; then
        openssl req -x509 -nodes -newkey rsa:4096 \
            -keyout /etc/ssl/private/pure-ftpd.pem \
            -out    /etc/ssl/private/pure-ftpd.pem \
            -days   3650 \
            -subj   "/CN=${DOMAIN}/O=Server/C=FR"
    fi
fi
chmod 600 /etc/ssl/private/pure-ftpd.pem

log OK "Pure-FTPd configuré (chroot, passif 40000-50000, FTPS)."

# ---------------------------------------------------------------------------
# 5. Configuration SFTP (via OpenSSH)
# ---------------------------------------------------------------------------
log STEP "Configuration SFTP (OpenSSH)"

SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SFTP_BLOCK_BEGIN="# >>> install_ftp.sh: SFTP pour ${FTP_USER} >>>"
readonly SFTP_BLOCK_END="# <<< install_ftp.sh: SFTP pour ${FTP_USER} <<<"

# Sauvegarde de la configuration SSH existante
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d)"

# Supprime un éventuel bloc précédent pour cet utilisateur (marqueurs
# BEGIN/END uniques, donc suppression complète — commentaires inclus —
# même en cas de ré-exécution répétée du script)
sed -i "\|^${SFTP_BLOCK_BEGIN}\$|,\|^${SFTP_BLOCK_END}\$|d" "$SSHD_CONFIG" 2>/dev/null || true

# Vérifie que le sous-système SFTP est activé
grep -q "^Subsystem sftp" "$SSHD_CONFIG" \
    || echo "Subsystem sftp internal-sftp" >> "$SSHD_CONFIG"

# Ajout du bloc SFTP avec chroot
cat >> "$SSHD_CONFIG" <<SSHD

${SFTP_BLOCK_BEGIN}
# L'utilisateur est limité à son répertoire, sans accès shell.
Match User ${FTP_USER}
    # Chroot dans la racine FTP (appartient à root, requis par OpenSSH)
    ChrootDirectory      ${FTP_HOME}
    # Forcer le sous-système SFTP uniquement (pas de shell)
    ForceCommand         internal-sftp
    # Désactiver les tunnels inutiles
    AllowTcpForwarding   no
    X11Forwarding        no
    PermitTunnel         no
    AllowAgentForwarding no
${SFTP_BLOCK_END}
SSHD

log OK "Configuration SFTP ajoutée dans sshd_config."

# ---------------------------------------------------------------------------
# 6. Démarrage des services
# ---------------------------------------------------------------------------
log STEP "Démarrage des services"
systemctl enable --now pure-ftpd
systemctl restart pure-ftpd

# Vérification de la config SSH avant rechargement
sshd -t && systemctl restart ssh \
    || { log ERROR "Erreur dans sshd_config ! Restauration de la sauvegarde.";
         cp "${SSHD_CONFIG}.bak.$(date +%Y%m%d)" "$SSHD_CONFIG";
         systemctl restart ssh; exit 1; }

log OK "Services Pure-FTPd et SSH démarrés."

# ---------------------------------------------------------------------------
# Récapitulatif
# ---------------------------------------------------------------------------
log STEP "Serveur FTP/SFTP configuré"
echo
echo -e "  ${BOLD}Pure-FTPd (FTPS)${RESET}"
echo -e "  Hôte        : ${GREEN}${SERVER_IP}${RESET} ou ${GREEN}ftp.${DOMAIN}${RESET}"
echo -e "  Port        : ${BOLD}21${RESET} (FTP) — mode passif : 40000-50000"
echo -e "  Utilisateur : ${BOLD}${FTP_USER}${RESET} (compte dédié, distinct de l'admin ${SYS_USER})"
echo -e "  Mot de passe: ${YELLOW}(même que le compte système $SYS_USER, changez-le avec : pure-pw passwd ${FTP_USER})${RESET}"
echo -e "  Répertoire  : ${BOLD}${FTP_HOME}${RESET}"
echo
echo -e "  ${BOLD}SFTP (OpenSSH)${RESET}"
echo -e "  Commande    : ${CYAN}sftp ${FTP_USER}@${SERVER_IP}${RESET}"
echo -e "  Port        : ${BOLD}22${RESET}"
echo -e "  Dossier écriture : ${BOLD}/uploads${RESET} (dans le chroot)"
echo
echo -e "  ${YELLOW}⚠  FileZilla : protocole SFTP, port 22, identifiants ci-dessus.${RESET}"
echo -e "  ${YELLOW}⚠  Ajoutez un enregistrement DNS A : ftp.${DOMAIN} → ${SERVER_IP}${RESET}"
