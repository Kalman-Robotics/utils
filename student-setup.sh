#!/bin/bash

# ─────────────────────────────────────────────
#  Kalman Robotics - Student Setup Script
#  Usage: bash <(curl -sSL https://kalmanrobotics.io/setup.sh) SESSION_TOKEN
# ─────────────────────────────────────────────

DEV_MODE=false
SESSION_TOKEN=""
DEV_CLAIM_CODE=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        --dev) DEV_MODE=true ;;
        --claim-code)
            i=$((i+1))
            DEV_CLAIM_CODE="${args[$i]}"
            ;;
        *) SESSION_TOKEN="${args[$i]}" ;;
    esac
    i=$((i+1))
done

BACKEND_URL="https://kalmanrobotics.io"
KALMAN_DIR="/var/lib/kalman"
KALMAN_HOSTNAME="alumno-instance"
ROBOT_HOSTNAME="robot-instance"
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
# 1. Verificar sudo
# ─────────────────────────────────────────────
function check_is_sudo() {
    log_info "Verificando permisos sudo..."
    set -e
    sudo echo
    set +e
    log_ok "Permisos sudo verificados."
}

# ─────────────────────────────────────────────
# 2. Verificar token
# ─────────────────────────────────────────────
function check_token() {
    if $DEV_MODE; then
        log_warn "Modo dev: saltando validación de token."
        return
    fi
    if [ -z "${SESSION_TOKEN}" ]; then
        log_err "Token de sesión requerido."
        echo "Uso: bash <(curl -sSL ${BACKEND_URL}/setup.sh) SESSION_TOKEN"
        exit 1
    fi
    log_ok "Token de sesión recibido."
}

# ─────────────────────────────────────────────
# 3. Detectar entorno
# ─────────────────────────────────────────────
function detect_environment() {
    log_info "Detectando entorno..."
    if grep -qEi "microsoft|wsl" /proc/version 2>/dev/null; then
        ENVIRONMENT="WSL"
        log_ok "Entorno detectado: WSL2"
    else
        ENVIRONMENT="Linux"
        log_ok "Entorno detectado: Linux nativo"
    fi
}

# ─────────────────────────────────────────────
# 4. Habilitar systemd en WSL2
# ─────────────────────────────────────────────
function enable_systemd_wsl() {
    if [ "${ENVIRONMENT}" != "WSL" ]; then return; fi

    log_info "Verificando systemd en WSL2..."
    if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then
        log_ok "systemd ya está habilitado en WSL2."
    else
        log_info "Habilitando systemd en WSL2..."
        if ! grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
            echo -e "[boot]\nsystemd=true" | sudo tee /etc/wsl.conf > /dev/null
        fi

        log_warn "systemd fue habilitado. Es necesario reiniciar WSL2."
        log_warn "Ejecuta en PowerShell: wsl --shutdown"
        log_warn "Luego vuelve a ejecutar este comando."
        exit 0
    fi

    # Corregir problema de DNS en WSL2
    log_info "Configurando hostname en /etc/hosts..."
    local current_hostname=$(hostname)
    if ! grep -q "127.0.0.1.*${current_hostname}" /etc/hosts; then
        echo "127.0.0.1 ${current_hostname}" | sudo tee -a /etc/hosts > /dev/null
        log_ok "Hostname agregado a /etc/hosts"
    else
        log_ok "Hostname ya configurado en /etc/hosts"
    fi
}

# ─────────────────────────────────────────────
# 5. Instalar dependencias básicas
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
# 6. Instalar Husarnet
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

            # Detener el servicio antes de desinstalar
            log_info "Deteniendo servicio Husarnet..."
            sudo systemctl stop husarnet 2>/dev/null || true
            sudo systemctl disable husarnet 2>/dev/null || true

            log_info "Desinstalando versión anterior..."
            sudo apt-get remove -y husarnet 2>/dev/null || true
            sudo apt-get purge -y husarnet 2>/dev/null || true
            sudo apt-get autoremove -y 2>/dev/null || true

            log_info "Instalando versión nightly..."
            if curl -s https://nightly.husarnet.com/install.sh | sudo bash -; then
                log_ok "Husarnet actualizado a nightly."
            else
                log_err "No se pudo actualizar Husarnet a nightly."
                exit 1
            fi
        fi
    else
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
# 7. Instalar ROS2
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
    sudo apt-get install -y ros-humble-desktop ros-humble-rmw-cyclonedds-cpp

    ROS_DISTRO="humble"
    log_ok "ROS2 Humble instalado."
}

# ─────────────────────────────────────────────
# 8. Obtener claim code del backend
#    Retorna: CLAIM_CODE
# ─────────────────────────────────────────────
function connect_to_session() {
    if $DEV_MODE; then
        log_warn "Modo dev: usando datos de sesión ficticios."
        CLAIM_CODE="${DEV_CLAIM_CODE}"
        log_ok "Datos de sesión ficticios cargados."
        return
    fi

    log_info "Conectando con backend..."

    local output status_code body

    for count in $(seq 1 10); do
        echo "  Intento ${count}/10..."
        output=$(curl -s -w "\n%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${SESSION_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"hostname\":\"${KALMAN_HOSTNAME}\"}" \
            "${BACKEND_URL}/api/session/connect")

        status_code=$(echo "${output}" | tail -n1)
        body=$(echo "${output}" | head -n-1)

        if [ "${status_code}" = "200" ]; then
            CLAIM_CODE=$(echo "${body}" | jq -r '.claim_code')
            log_ok "Sesión iniciada."
            return
        elif echo "401 403" | grep -q "${status_code}"; then
            log_err "Token inválido o sesión expirada (${status_code})."
            exit 1
        fi

        log_warn "Backend no disponible (${status_code}). Reintentando en 12s..."
        sleep 12
    done

    log_err "No se pudo conectar con el backend después de 10 intentos."
    exit 1
}

# ─────────────────────────────────────────────
# 9. Hacer claim en la cuenta Kalman
#    Registra este dispositivo en la cuenta Kalman con su fc94:.
#    El grupo join code NUNCA sale del servidor —
#    AWS usa attach-device API para meter al estudiante al grupo.
# ─────────────────────────────────────────────
function husarnet_claim() {
    if $DEV_MODE && [ -z "${CLAIM_CODE}" ]; then
        log_warn "Modo dev: saltando husarnet claim (no se proporcionó --claim-code)."
        return
    fi

    # husarnet claim usa el hostname del sistema — lo fijamos antes de hacer claim
    log_info "Configurando hostname a '${KALMAN_HOSTNAME}'..."
    sudo hostnamectl set-hostname "${KALMAN_HOSTNAME}"
    sudo systemctl restart husarnet
    sleep 3

    log_info "Registrando dispositivo en la cuenta Kalman como '${KALMAN_HOSTNAME}'..."
    local claim_output
    claim_output=$(timeout 60 sudo husarnet claim "${CLAIM_CODE}" 2>&1)

    if echo "${claim_output}" | grep -qi "already claimed"; then
        log_warn "Dispositivo reclamado por otra cuenta. Liberando identidad..."
        sudo systemctl stop husarnet
        sudo rm -f /var/lib/husarnet/id /var/lib/husarnet/config.db
        sudo systemctl start husarnet
        sleep 5

        log_info "Reintentando claim..."
        claim_output=$(timeout 60 sudo husarnet claim "${CLAIM_CODE}" 2>&1)
    fi

    if ! echo "${claim_output}" | grep -qi "success"; then
        log_err "No se pudo registrar el dispositivo."
        echo "${claim_output}"
        exit 1
    fi
    log_ok "Dispositivo registrado en la cuenta Kalman como '${KALMAN_HOSTNAME}'."
}

# ─────────────────────────────────────────────
# 9b. Notificar fc94: al backend
#     El backend usa este fc94: para hacer attach-device al grupo.
# ─────────────────────────────────────────────
function notify_fc94() {
    if $DEV_MODE; then
        log_warn "Modo dev: saltando notificación de fc94:."
        return
    fi

    log_info "Notificando fc94: al backend..."
    local student_ipv6
    student_ipv6=$(curl -s http://localhost:16216/api/status \
        | jq -r '.result.live.local_ip' 2>/dev/null || echo "")

    if [ -z "${student_ipv6}" ]; then
        log_err "No se pudo obtener el fc94: del daemon Husarnet."
        exit 1
    fi

    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${SESSION_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"ipv6\":\"${student_ipv6}\",\"hostname\":\"${HOSTNAME}\"}" \
        "${BACKEND_URL}/api/session/device-ready")

    if [ "${status_code}" != "200" ]; then
        log_err "Backend no pudo registrar el dispositivo (${status_code})."
        exit 1
    fi

    log_ok "fc94: notificado: ${student_ipv6}. AWS adjuntará el dispositivo al grupo."
}

# ─────────────────────────────────────────────
# 10. Generar CycloneDDS XML
# ─────────────────────────────────────────────
function configure_cyclonedds() {
    sudo mkdir -p "${KALMAN_DIR}"
    if [ -f "${KALMAN_DIR}/cyclonedds.xml" ]; then
        log_ok "CycloneDDS ya configurado — sin cambios."
        return
    fi
    log_info "Configurando CycloneDDS (primera vez)..."

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
                <Peer address="${ROBOT_HOSTNAME}"/>
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

    log_ok "CycloneDDS configurado con peers: ${ROBOT_HOSTNAME} y ${AWS_HOSTNAME}"
}

# ─────────────────────────────────────────────
# 12. Exportar variables ROS2 en .bashrc (idempotente)
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
# 13. Reportar al backend que el estudiante está listo
# ─────────────────────────────────────────────
function report_ready() {
    if $DEV_MODE; then
        log_warn "Modo dev: saltando notificación al backend."
        return
    fi

    log_info "Notificando al backend..."
    local student_ipv6
    student_ipv6=$(curl -s http://localhost:16216/api/status | jq -r '.result.live.local_ip' 2>/dev/null || echo "unknown")

    curl -s -X POST \
        -H "Authorization: Bearer ${SESSION_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"ready\",\"ipv6\":\"${student_ipv6}\",\"hostname\":\"${HOSTNAME}\"}" \
        "${BACKEND_URL}/api/session/student-ready" > /dev/null

    log_ok "Backend notificado. IPv6: ${student_ipv6}"
}

# ─────────────────────────────────────────────
# 14. Instrucciones finales
# ─────────────────────────────────────────────
function next_steps() {
    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN} Kalman Robotics - Conexion establecida${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  Robot:  ${ROBOT_HOSTNAME}"
    echo -e "  AWS:    ${AWS_HOSTNAME}"
    echo
    echo -e "  Recarga las variables de entorno:"
    echo -e "  ${YELLOW}source ~/.bashrc${NC}"
    echo
    echo -e "  Verifica los topicos del robot:"
    echo -e "  ${YELLOW}ros2 topic list${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
function main() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Kalman Robotics - Configuracion de sesion${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo

    check_is_sudo
    check_token
    detect_environment
    enable_systemd_wsl
    install_dependencies
    install_husarnet
    install_ros2
    connect_to_session
    husarnet_claim
    notify_fc94
    configure_cyclonedds
    export_ros_env
    report_ready
    next_steps
}

main
