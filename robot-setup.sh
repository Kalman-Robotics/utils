#!/bin/bash

# ─────────────────────────────────────────────
#  Kalman Robotics - Robot Setup Script
#  Ejecutar UNA SOLA VEZ durante la configuración inicial del robot.
#  Usage: bash robot-setup.sh CLAIM_CODE
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
        log_err "Uso: bash robot-setup.sh CLAIM_CODE"
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

    curl --version &>/dev/null || pkgs+=(curl)
    jq --version &>/dev/null   || pkgs+=(jq)

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
        log_ok "Husarnet ya instalado: $(husarnet version | head -1)"
    else
        log_info "Instalando Husarnet nightly..."
        curl -s https://install.husarnet.com/nightly.sh | sudo bash
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
# 5. Instalar ROS2 Humble
# ─────────────────────────────────────────────
function install_ros2() {
    log_info "Verificando ROS2..."

    if [ -d /opt/ros ]; then
        ROS_DISTRO=$(ls /opt/ros/ | head -n1)
        if [ -n "${ROS_DISTRO}" ]; then
            log_ok "ROS2 ya instalado: ${ROS_DISTRO}"
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
# 6. Claim permanente en la cuenta Kalman
# ─────────────────────────────────────────────
function husarnet_claim() {
    log_info "Configurando hostname a '${KALMAN_HOSTNAME}'..."
    sudo hostnamectl set-hostname "${KALMAN_HOSTNAME}"
    sudo systemctl restart husarnet
    sleep 3

    log_info "Registrando robot en la cuenta Kalman como '${KALMAN_HOSTNAME}'..."
    timeout 60 sudo husarnet claim "${CLAIM_CODE}"
    if [ $? -ne 0 ]; then
        log_err "No se pudo registrar el robot."
        exit 1
    fi

    local robot_ipv6
    robot_ipv6=$(curl -s http://localhost:16216/api/status \
        | jq -r '.result.live.local_ip' 2>/dev/null || echo "")

    log_ok "Robot registrado como '${KALMAN_HOSTNAME}'. fc94: ${robot_ipv6}"
    log_warn "Guarda este fc94: en el backend: ${robot_ipv6}"
}

# ─────────────────────────────────────────────
# 7. Configurar CycloneDDS
# ─────────────────────────────────────────────
function configure_cyclonedds() {
    sudo mkdir -p "${KALMAN_DIR}"
    if [ -f "${KALMAN_DIR}/cyclonedds.xml" ]; then
        log_ok "CycloneDDS ya configurado — sin cambios."
        return
    fi
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
                <Peer address="${AWS_HOSTNAME}"/>
                <Peer address="${ALUMNO_HOSTNAME}"/>
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

    log_ok "CycloneDDS configurado con peers: ${AWS_HOSTNAME} y ${ALUMNO_HOSTNAME}"
}

# ─────────────────────────────────────────────
# 8. Exportar variables ROS2 en .bashrc (idempotente)
# ─────────────────────────────────────────────
function export_ros_env() {
    log_info "Configurando variables de entorno ROS2..."

    local ros_distro=${ROS_DISTRO:-humble}

    declare -A ros_vars=(
        ["source /opt/ros/${ros_distro}/setup.bash"]="source /opt/ros/${ros_distro}/setup.bash"
        ["RMW_IMPLEMENTATION"]="export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
        ["CYCLONEDDS_URI"]="export CYCLONEDDS_URI=file://${KALMAN_DIR}/cyclonedds.xml"
        ["ROS_DOMAIN_ID"]="export ROS_DOMAIN_ID=0"
        ["ROS_IPV6"]="export ROS_IPV6=on"
    )

    for key in "${!ros_vars[@]}"; do
        if ! grep -q "${key}" ~/.bashrc 2>/dev/null; then
            echo "${ros_vars[$key]} # Added by Kalman" >> ~/.bashrc
        fi
    done

    log_ok "Variables ROS2 configuradas en ~/.bashrc"
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
function main() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Kalman Robotics - Robot Setup (una sola vez)${NC}"
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

    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Robot configurado correctamente${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  Hostname: ${KALMAN_HOSTNAME}"
    echo -e "  Peers:    ${AWS_HOSTNAME}, ${ALUMNO_HOSTNAME}"
    echo
    echo -e "  Recarga variables de entorno:"
    echo -e "  ${YELLOW}source ~/.bashrc${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main
