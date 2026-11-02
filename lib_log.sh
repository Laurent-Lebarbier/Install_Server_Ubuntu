# lib_log.sh — Journal d'installation (sourcé par install.sh, install_*.sh,
# restore_server.sh)
#
# Tout ce qui s'affiche à l'écran (sortie normale ET erreurs) est aussi écrit
# dans /var/log/install_server/<date>_<script>.log, sans les codes couleur.
# Les saisies masquées (mots de passe tapés) n'apparaissent pas : elles ne
# s'affichent pas à l'écran non plus. En revanche les identifiants GÉNÉRÉS
# et affichés en fin d'étape y figurent : le dossier est réservé à root.
#
# Un seul journal par lancement : quand install.sh appelle un sous-script,
# celui-ci écrit dans le journal déjà ouvert (variable INSTALL_LOG exportée).
#
# Désactiver : INSTALL_NO_LOG=1 sudo bash install.sh

start_install_log() {
    [[ -n "${INSTALL_LOG:-}" || -n "${INSTALL_NO_LOG:-}" ]] && return 0
    [[ $EUID -eq 0 ]] || return 0          # pas root : le script s'arrêtera de lui-même
    [[ -t 1 ]] || return 0                 # sortie déjà redirigée (cron, pipe) : rien à faire

    local dir="/var/log/install_server" name
    name="$(basename "${0:-script}" .sh)"
    mkdir -p "$dir" && chmod 700 "$dir" || return 0
    INSTALL_LOG="${dir}/$(date +%Y-%m-%d_%H%M%S)_${name}.log"
    export INSTALL_LOG
    : > "$INSTALL_LOG" && chmod 600 "$INSTALL_LOG" || { unset INSTALL_LOG; return 0; }

    {
        echo "# Journal de ${name}.sh — $(date '+%d/%m/%Y %H:%M:%S')"
        echo "# Machine : $(hostname) — $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
        echo "# Commande : $0 $*"
        echo
    } >> "$INSTALL_LOG"

    # Écran inchangé (couleurs comprises) ; fichier sans codes couleur ni \r
    exec > >(tee >(sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' -e 's/.*\r//' >> "$INSTALL_LOG")) 2>&1

    trap '_install_log_end $?' EXIT
}

_install_log_end() {
    local rc="$1"
    echo
    if (( rc == 0 )); then
        echo "Journal complet : ${INSTALL_LOG}"
    else
        echo "⚠  Arrêt sur erreur (code ${rc}). Journal complet : ${INSTALL_LOG}"
        echo "   Pour le partager : sudo tail -n 80 ${INSTALL_LOG}"
    fi
    # laisse à tee le temps de vider ses tampons avant la fin du script
    sleep 0.3
}
