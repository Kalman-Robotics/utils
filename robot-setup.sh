#!/bin/bash

# ─────────────────────────────────────────────
#  Kalman Robotics - Robot Setup Script
#  Ejecutar UNA SOLA VEZ durante la configuración inicial del robot.
#  Usage: bash <(curl -sSL https://raw.githubusercontent.com/Kalman-Robotics/utils/master/robot-setup.sh) CLAIM_CODE
# ─────────────────────────────────────────────

CLAIM_CODE="${1:-}"

BACKEND_URL="https://kalmanrobotics.io"
KALMAN_DIR="/var/lib/kalman"
KALMAN_HOSTNAME="robot-instance"
ALUMNO_HOSTNAME="alumno-instance"
AWS_HOSTNAME="aws-instance"

# ─────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────
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
# 1. Verificar argumentos
# ─────────────────────────────────────────────
function check_args() {
    if [ -z "${CLAIM_CODE}" ]; then
        log_err "Claim code requerido."
        echo "Uso: bash <(curl -sSL https://raw.githubusercontent.com/Kalman-Robotics/utils/master/robot-setup.sh) CLAIM_CODE"
        exit 1
    fi
    log_ok "Claim code recibido."
}

# ─────────────────────────────────────────────
# 2. Verificar sudo
# ─────────────────────────────────────────────
function check_is_sudo() {
    log_info "Verificando permisos sudo..."
    set -e
    sudo echo
    set +e
    log_ok "Permisos sudo verificados."
}

# ─────────────────────────────────────────────
# 3. Instalar dependencias básicas
# ─────────────────────────────────────────────
function install_dependencies() {
    log_info "Verificando dependencias básicas..."
    local pkgs=()

    curl --version &>/dev/null   || pkgs+=(curl)
    jq --version &>/dev/null     || pkgs+=(jq)

    if [ ${#pkgs[@]} -gt 0 ]; then
        log_info "Instalando: ${pkgs[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y --no-install-recommends "${pkgs[@]}"
    fi

    log_ok "Dependencias listas."
}

# ─────────────────────────────────────────────
# 4. Instalar Husarnet
# ─────────────────────────────────────────────
function install_husarnet() {
    log_info "Verificando Husarnet..."
    if husarnet version &>/dev/null; then
        local current_version=$(husarnet version | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
        log_ok "Husarnet ya instalado: versión ${current_version}"

        # Si el patch es menor a 300 (ej: 2.0.180), es versión antigua — actualizar a nightly
        local patch=$(echo "${current_version}" | cut -d. -f3)
        if [ "${patch}" -lt 300 ] 2>/dev/null; then
            log_warn "Versión antigua detectada (${current_version}). Actualizando a nightly..."

            log_info "Deteniendo servicio Husarnet..."
            sudo systemctl stop husarnet 2>/dev/null || true
            sudo systemctl disable husarnet 2>/dev/null || true

            log_info "Desinstalando versión anterior..."
            sudo apt-get remove -y husarnet 2>/dev/null || true
            sudo apt-get purge -y husarnet 2>/dev/null || true
            sudo apt-get autoremove -y 2>/dev/null || true

            log_info "Actualizando índice de paquetes..."
            sudo apt-get update -qq
            log_info "Instalando versión nightly..."
            if curl -s https://nightly.husarnet.com/install.sh | sudo bash -; then
                log_ok "Husarnet actualizado a nightly."
            else
                log_err "No se pudo actualizar Husarnet a nightly."
                exit 1
            fi
        fi
    else
        log_info "Actualizando índice de paquetes..."
        sudo apt-get update -qq
        log_info "Instalando Husarnet..."
        curl -s https://nightly.husarnet.com/install.sh | sudo bash -
        if ! husarnet version &>/dev/null; then
            log_err "Husarnet no se instaló correctamente."
            exit 1
        fi
        log_ok "Husarnet instalado."
    fi

    log_info "Iniciando servicio Husarnet..."
    sudo systemctl enable husarnet --quiet
    sudo systemctl restart husarnet
    sleep 3
    log_ok "Servicio Husarnet activo."
}

# ─────────────────────────────────────────────
# 5. Instalar ROS2
# ─────────────────────────────────────────────
function install_ros2() {
    log_info "Verificando ROS2..."

    if [ -d /opt/ros ]; then
        ROS_DISTRO=$(ls /opt/ros/ | head -n1)
        if [ -n "${ROS_DISTRO}" ]; then
            log_ok "ROS2 ya instalado: ${ROS_DISTRO}"
            # Verificar CycloneDDS aunque ROS2 ya esté instalado
            if ! dpkg -l ros-humble-rmw-cyclonedds-cpp &>/dev/null; then
                log_info "Instalando ros-humble-rmw-cyclonedds-cpp..."
                sudo apt-get install -y ros-humble-rmw-cyclonedds-cpp
                log_ok "CycloneDDS RMW instalado."
            fi
            return
        fi
    fi

    log_info "Instalando ROS2 Humble..."

    sudo apt-get install -y locales
    sudo locale-gen en_US en_US.UTF-8
    sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

    sudo apt-get install -y software-properties-common
    sudo add-apt-repository universe -y
    sudo apt-get update -qq
    sudo apt-get install -y curl gnupg lsb-release

    sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        -o /usr/share/keyrings/ros-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
        http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
        | sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y ros-humble-ros-base ros-humble-rmw-cyclonedds-cpp

    ROS_DISTRO="humble"
    log_ok "ROS2 Humble instalado."
}

# ─────────────────────────────────────────────
# 6. Hacer claim permanente en la cuenta Kalman
# ─────────────────────────────────────────────
function husarnet_claim() {
    # husarnet claim usa el hostname del sistema — lo fijamos antes de hacer claim
    log_info "Configurando hostname a '${KALMAN_HOSTNAME}'..."
    sudo hostnamectl set-hostname "${KALMAN_HOSTNAME}"
    sudo systemctl restart husarnet
    sudo husarnet daemon restart

    sleep 3

    log_info "Registrando robot en la cuenta Kalman como '${KALMAN_HOSTNAME}'..."
    local claim_output
    claim_output=$(timeout 60 sudo husarnet claim "${CLAIM_CODE}" 2>&1)

    if echo "${claim_output}" | grep -qi "already claimed by someone else"; then
        log_warn "Dispositivo pertenece a otra cuenta. Liberando..."
        sudo husarnet device unclaim
        sleep 3

        log_info "Reintentando claim..."
        claim_output=$(timeout 60 sudo husarnet claim "${CLAIM_CODE}" 2>&1)
    fi

    if ! echo "${claim_output}" | grep -qi "success"; then
        log_err "No se pudo registrar el dispositivo."
        echo "${claim_output}"
        exit 1
    fi

    if echo "${claim_output}" | grep -qi "already claimed this device"; then
        log_warn "Dispositivo ya estaba en esta cuenta — continuando."
    fi
    log_ok "Robot registrado en la cuenta Kalman como '${KALMAN_HOSTNAME}'."
}

# ─────────────────────────────────────────────
# 7. Generar CycloneDDS XML
# ─────────────────────────────────────────────
function configure_cyclonedds() {
    sudo mkdir -p "${KALMAN_DIR}"
    log_info "Configurando CycloneDDS..."

cat <<EOF | sudo tee "${KALMAN_DIR}/cyclonedds.xml" > /dev/null
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="https://cdds.io/config https://raw.githubusercontent.com/eclipse-cyclonedds/cyclonedds/master/etc/cyclonedds.xsd">
    <Domain id="any">
        <General>
            <NetworkInterfaceAddress>hnet0</NetworkInterfaceAddress>
            <AllowMulticast>false</AllowMulticast>
            <MaxMessageSize>65500B</MaxMessageSize>
            <FragmentSize>4000B</FragmentSize>
            <Transport>udp6</Transport>
        </General>
        <Discovery>
            <Peers>
                <Peer address="${ALUMNO_HOSTNAME}"/>
                <Peer address="${AWS_HOSTNAME}"/>
                <Peer address="${KALMAN_HOSTNAME}"/>
            </Peers>
            <MaxAutoParticipantIndex>100</MaxAutoParticipantIndex>
            <ParticipantIndex>auto</ParticipantIndex>
        </Discovery>
        <Internal>
            <Watermarks>
                <WhcHigh>500kB</WhcHigh>
            </Watermarks>
        </Internal>
        <Tracing>
            <Verbosity>severe</Verbosity>
            <OutputFile>stdout</OutputFile>
        </Tracing>
    </Domain>
</CycloneDDS>
EOF

    log_ok "CycloneDDS configurado con peers: ${ALUMNO_HOSTNAME} y ${AWS_HOSTNAME}"
}

# ─────────────────────────────────────────────
# 8. Exportar variables ROS2 en .bashrc
# ─────────────────────────────────────────────
function export_ros_env() {
    log_info "Configurando variables de entorno ROS2..."

    local ros_distro=${ROS_DISTRO:-humble}
    sudo mkdir -p "${KALMAN_DIR}"

    cat <<EOF | sudo tee "${KALMAN_DIR}/env.bash" > /dev/null
_K_GREEN='\033[0;32m'
_K_NC='\033[0m'
echo ""
echo -e "\${_K_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${_K_NC}"
echo -e "\${_K_GREEN}  Kalman Robotics — Robot activo\${_K_NC}"
echo -e "\${_K_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${_K_NC}"
echo -e "  Hostname: ${KALMAN_HOSTNAME}"
echo -e "  Peers:    ${ALUMNO_HOSTNAME}, ${AWS_HOSTNAME}"
echo -e "\${_K_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${_K_NC}"
echo ""
source /opt/ros/${ros_distro}/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file://${KALMAN_DIR}/cyclonedds.xml
export ROS_DOMAIN_ID=0
export ROS_IPV6=on
EOF

    if ! grep -q "kalman/env.bash" ~/.bashrc 2>/dev/null; then
        echo "" >> ~/.bashrc
        echo "# Configuración de entorno para Kalman Robotics" >> ~/.bashrc
        echo "[ -f ${KALMAN_DIR}/env.bash ] && source ${KALMAN_DIR}/env.bash" >> ~/.bashrc
    fi

    log_ok "Entorno ROS2 configurado. Se activará automáticamente en cada nueva terminal."
}

# ─────────────────────────────────────────────
# 9. Reiniciar daemon ROS2
# ─────────────────────────────────────────────
function restart_ros_daemon() {
    local ros_distro=${ROS_DISTRO:-humble}
    local ros_setup="/opt/ros/${ros_distro}/setup.bash"

    if [ ! -f "${ros_setup}" ]; then
        log_warn "ROS2 setup.bash no encontrado — saltando ros2 daemon stop."
        return
    fi

    log_info "Limpiando cache del daemon ROS2..."
    bash -c "source ${ros_setup} && ros2 daemon stop" 2>/dev/null || true
    log_ok "Daemon ROS2 detenido. Se reiniciará con la nueva configuración."
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
function main() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Kalman Robotics - Configuracion inicial del robot${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo

    check_args
    check_is_sudo
    install_dependencies
    install_husarnet
    install_ros2
    husarnet_claim
    configure_cyclonedds
    export_ros_env
    restart_ros_daemon

    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Robot configurado correctamente${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  Hostname: ${KALMAN_HOSTNAME}"
    echo -e "  Peers:    ${ALUMNO_HOSTNAME}, ${AWS_HOSTNAME}"
    echo
    echo -e "  Abre una nueva terminal para activar el entorno ROS2."
    echo
    echo -e "  Verifica los topicos:"
    echo -e "  ${YELLOW}ros2 topic list${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main
