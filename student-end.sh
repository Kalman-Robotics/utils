#!/bin/bash

# ─────────────────────────────────────────────
#  Kalman Robotics - Student End Session Script
#  Restaura el entorno del estudiante al terminar la sesión.
#  Usage: bash student-end.sh
# ─────────────────────────────────────────────

KALMAN_DIR="/var/lib/kalman"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
function log_info() { echo -e "${BLUE}[..] $1${NC}"; }
function log_warn() { echo -e "${YELLOW}[!!] $1${NC}"; }
function log_err()  { echo -e "${RED}[ERROR] $1${NC}"; }

# ─────────────────────────────────────────────
# 1. Restaurar hostname original
# ─────────────────────────────────────────────
function restore_hostname() {
    if [ ! -f "${KALMAN_DIR}/original_hostname" ]; then
        log_warn "No se encontró hostname original — sin cambios."
        return
    fi

    local original
    original=$(cat "${KALMAN_DIR}/original_hostname")
    log_info "Restaurando hostname a '${original}'..."
    sudo hostnamectl set-hostname "${original}"
    sudo rm -f "${KALMAN_DIR}/original_hostname"
    log_ok "Hostname restaurado: ${original}"
}

# ─────────────────────────────────────────────
# 2. Eliminar archivo de entorno Kalman
# ─────────────────────────────────────────────
function remove_env_file() {
    if [ -f "${KALMAN_DIR}/env.bash" ]; then
        sudo rm -f "${KALMAN_DIR}/env.bash"
        log_ok "Entorno Kalman desactivado (env.bash eliminado)."
    else
        log_warn "No había entorno Kalman activo."
    fi
}

# ─────────────────────────────────────────────
# 3. Eliminar archivos de sesión Kalman
# ─────────────────────────────────────────────
function cleanup_kalman_files() {
    log_info "Eliminando archivos de sesión..."
    sudo rm -f "${KALMAN_DIR}/env.bash"
    sudo rm -f "${KALMAN_DIR}/cyclonedds.xml"
    log_ok "Archivos de sesión eliminados."
}

# ─────────────────────────────────────────────
# 4. Reiniciar Husarnet para aplicar hostname
# ─────────────────────────────────────────────
function restart_husarnet() {
    log_info "Reiniciando Husarnet con hostname original..."
    sudo systemctl restart husarnet
    log_ok "Husarnet reiniciado."
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
function main() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Kalman Robotics - Fin de sesión${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo

    restore_hostname
    remove_env_file
    cleanup_kalman_files
    restart_husarnet

    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Entorno restaurado correctamente${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  Abre una nueva terminal para aplicar los cambios."
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main
