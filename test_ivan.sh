#!/usr/bin/env bash
set -euo pipefail

APP_URL="https://kalmanrobotics.io"
REGISTER_URL="https://kalmanrobotics.io/api/robots/setup/register"
SETUP_TOKEN="AXeoKUTunkcIAw7xcYgc6CzfMs565Vftcih21FqDUchbD26xTCBL42VUEGfhDpEB"
ROBOT_ID="01K9Q0HH3RHJX5TB2D2VZQJZ2S"
ROBOT_HOSTNAME="raspberry-lab1"
JOIN_CODE="fc94:b01d:1803:8dd8:b293:5c7d:7639:932a/5p56i2vYyW8Uz7W7NnHPXC"
ROS_DISTRO="humble"
ROSBRIDGE_PORT="9090"
SCRIPT_VERSION="2026-03-09"

if [ "$(id -u)" -ne 0 ]; then
  echo "Este script requiere sudo. Ejecuta: curl -fsSL <url> | sudo bash"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y curl jq ca-certificates lsb-release gnupg

if ! command -v husarnet >/dev/null 2>&1; then
  curl -fsSL https://install.husarnet.com | bash
fi

# Siempre reescribir la clave y el source para evitar conflictos GPG
curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  -o /usr/share/keyrings/ros-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo "$UBUNTU_CODENAME") main" \
  > /etc/apt/sources.list.d/ros2.list

# Limpiar cualquier entrada duplicada o con formato antiguo en sources.list principal
sed -i '/packages.ros.org/d' /etc/apt/sources.list

apt-get update -y
apt-get install -y "ros-${ROS_DISTRO}-ros-base" "ros-${ROS_DISTRO}-rosbridge-server"

hostnamectl set-hostname "${ROBOT_HOSTNAME}"

if ! husarnet join "${JOIN_CODE}" "${ROBOT_HOSTNAME}"; then
  husarnet claim "${JOIN_CODE}" "${ROBOT_HOSTNAME}"
fi

cat > /etc/systemd/system/kalman-rosbridge.service <<SERVICE
[Unit]
Description=Kalman ROSBridge
After=network.target husarnet.service
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/bin/bash -lc 'source /opt/ros/${ROS_DISTRO}/setup.bash && ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:=${ROSBRIDGE_PORT}'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now kalman-rosbridge.service

sleep 5

HUSARNET_IPV6="$(ip -6 addr show dev hnet0 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | head -n1 || true)"
OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-linux}")"
ROSBRIDGE_READY="false"
if systemctl is-active --quiet kalman-rosbridge.service; then
  ROSBRIDGE_READY="true"
fi

PAYLOAD="$(jq -n \
  --arg setup_token "${SETUP_TOKEN}" \
  --arg husarnet_hostname "${ROBOT_HOSTNAME}" \
  --arg husarnet_ipv6 "${HUSARNET_IPV6}" \
  --arg ros_distro "${ROS_DISTRO}" \
  --arg systemd_service "kalman-rosbridge.service" \
  --arg script_version "${SCRIPT_VERSION}" \
  --arg os "${OS_NAME}" \
  --argjson rosbridge_port "${ROSBRIDGE_PORT}" \
  --argjson rosbridge_ready "${ROSBRIDGE_READY}" \
  '{
    setup_token: $setup_token,
    husarnet_hostname: $husarnet_hostname,
    husarnet_ipv6: $husarnet_ipv6,
    ros_distro: $ros_distro,
    rosbridge_port: $rosbridge_port,
    rosbridge_ready: $rosbridge_ready,
    systemd_service: $systemd_service,
    script_version: $script_version,
    os: $os
  }')"

curl -fsSL -X POST "${REGISTER_URL}" \
  -H "Authorization: Bearer ${SETUP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}"

echo
echo "Robot ${ROBOT_ID} provisionado. Hostname: ${ROBOT_HOSTNAME}"
echo "ROSBridge listo en ws://${ROBOT_HOSTNAME}:${ROSBRIDGE_PORT}"