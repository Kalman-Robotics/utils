# Kalman Robotics — Arquitectura Técnica v2.1

## 1. Proyecto
Plataforma educativa de laboratorios remotos. Estudiantes acceden a robots físicos (myCobot Pro 450, TurtleBot4) via ROS2 sobre VPN Husarnet P2P.

## 2. Dispositivos por sesión
| Dispositivo | Rol |
|---|---|
| Raspberry Pi | Agente 24/7, ejecuta ROS2, WebSocket hacia AWS |
| AWS EC2 | Backend + Robot Manager + rosbridge :9090 |
| PC estudiante | Ejecuta student-setup.sh al inicio de sesión |

## 3. Red Husarnet
- Versión: nightly 2.0.335+ — `HUSARNET_INSTANCE_FQDN=beta.husarnet.com`
- Interfaz: `hnet0` — IPv6 permanentes basados en clave pública
- `/etc/hosts` gestionado automáticamente por el daemon (líneas `# managed by Husarnet`)
- **Límite de dispositivos por cuenta: ilimitado** (`max_devices: 2147483647`)
- **El script del estudiante NO modifica /etc/hosts manualmente**

### Hostnames fijos por sesión
Cada dispositivo usa un hostname fijo en Husarnet. Husarnet los resuelve en `/etc/hosts` automáticamente:
- `robot_instance` → el robot asignado a la sesión
- `aws_instance` → el servidor AWS EC2
- `alumno_instance` → el PC del estudiante

El `cyclonedds.xml` usa estos nombres fijos y **nunca necesita regenerarse**.

## 4. Modelo de seguridad y flujo

### Claim de dispositivos
- **Robot**: `husarnet claim <claim_code>` una sola vez (setup inicial) → dispositivo permanente en la cuenta
- **Estudiante**: `husarnet claim <claim_code>` en cada sesión → registra el dispositivo en la cuenta con su `fc94:`

El claim code registra el dispositivo en la cuenta Kalman pero **no lo mete en ningún grupo**. El grupo join code NUNCA sale del servidor — AWS lo usa internamente via Dashboard API para hacer `attach-device`.

> ⚠ Exponer el claim code es aceptable: solo añade el dispositivo a la cuenta, no compromete ninguna sesión activa.
> ⚠ Exponer el group join code sería peligroso: permitiría a terceros unirse a la sesión del estudiante.

### Flujo de sesión completo
1. Backend crea grupo Husarnet temporal via Dashboard API
2. Backend hace `attach` de robot + `aws-server` al grupo (sus `fc94:` son conocidos y permanentes)
3. Estudiante ejecuta `student-setup.sh SESSION_TOKEN`
4. Backend entrega `claim_code` + `robot_hostname` + `aws_hostname` al script
5. Script ejecuta `husarnet claim <claim_code>` → dispositivo queda en la cuenta con su `fc94:`
6. Script notifica el `fc94:` al backend → AWS hace `attach-device` del estudiante al grupo
7. Script verifica que robot y aws-server aparezcan como peers en `localhost:16216/api/status`
8. Script genera `cyclonedds.xml` y exporta variables ROS2
9. Script reporta `student-ready` → frontend avanza stepper
10. Al terminar: backend hace `detach` de los tres dispositivos y elimina el grupo

> ⚠ El estudiante puede tener múltiples dispositivos. Todos hacen claim; el backend adjunta el que acaba de hacer claim en esta sesión.

### Purga diaria de dispositivos (cron en AWS, 2am)
- `GET /v3/web/devices` → lista todos los dispositivos
- Whitelist protegida: `aws-server` + todos los `raspberry-*`
- Elimina dispositivos: offline + sin contacto > 30 días + no en grupo activo
- Comando: `husarnet --json device unclaim <hostname>`
- Log: `/var/log/kalman-purge.log`

## 5. Husarnet Dashboard API v3
- **Daemon-proxied** (desde AWS): `X-Husarnet-Secret: $SECRET` → `localhost:16216/api/forward/v3/web/...`
- **JWT directo** (futuro): `Authorization: Bearer $JWT` → `https://api.beta.husarnet.com/v3/web/...`

Endpoints confirmados:
- `GET /v3/web/groups` — lista grupos
- `GET /v3/web/devices` — lista dispositivos
- `POST /v3/web/groups` — crear grupo
- `DELETE /v3/web/groups/{id}` — eliminar grupo
- `POST /v3/web/groups/attach-device` — adjuntar dispositivo (requiere `groupId` + `deviceIp`)
- `POST /v3/web/groups/detach-device` — desadjuntar dispositivo

Daemon API local (`localhost:16216`):
- `GET /api/status` → estado completo; peers en `.result.config.dashboard.peers[].{address,hostname}`
- `GET /hi` — test de conectividad

> ⚠ En nightly 2.0.335 el endpoint `/api/join` devuelve 404. Join SOLO via CLI: `sudo husarnet join <code> <hostname>`
> ⚠ CLI confirmado: `husarnet --json device unclaim <hostname>` ✅ | `husarnet status --json` ✅

## 6. Agente Robot (Raspberry Pi) — `kalman-agent-robot.py`
Servicio systemd instanciado por robot: `kalman-agent-robot@raspberry-RRBOT.service`
Config en: `/etc/kalman/robot-<id>.env` → variables `ROBOT_ID`, `ROBOT_TOKEN`, `BACKEND_WS_URL`

Estados: `IDLE → JOINING → CONNECTED → LEAVING → IDLE`

Comandos WebSocket recibidos del backend:
- `{"cmd":"join","join_code":"xxx"}` → `husarnet claim xxx` (join al grupo de sesión)
- `{"cmd":"leave"}` → `husarnet leave`
- `{"cmd":"status"}` → responde estado actual

Mensajes enviados al backend: `hello` al conectar, `status` en cada cambio, `heartbeat` cada 30s.

## 7. Script del estudiante — `student-setup.sh`
Ejecutado cada sesión: `bash <(curl -sSL https://kalmanrobotics.io/setup.sh) SESSION_TOKEN`

Pasos:
1. Verificar sudo
2. Verificar `SESSION_TOKEN`
3. Detectar entorno (Linux / WSL2) — habilitar systemd si WSL
4. Instalar deps si faltan: `curl`, `jq`
5. Instalar Husarnet nightly si no está
6. Instalar ROS2 Humble si no está
7. `POST /api/session/connect` → obtiene `claim_code`
8. `husarnet claim <claim_code> alumno_instance` → dispositivo registrado en cuenta Kalman con hostname fijo
9. `POST /api/session/device-ready` con `fc94:` → AWS hace `attach-device` al grupo via Dashboard API
10. Generar `/var/lib/kalman/cyclonedds.xml` con `robot_instance` y `aws_instance` (solo primera vez)
10. Exportar variables ROS2 en `~/.bashrc` (idempotente)
11. `POST /api/session/student-ready` → frontend avanza stepper
12. Mostrar instrucciones finales

Modo dev: `bash student-setup.sh --dev [--claim-code xxx]`

> No instala servicio monitor — heartbeat y fin de sesión los maneja el frontend via WebSocket.

## 8. Frontend — Modal de conexión
- **Idle**: muestra comando + botón Conectar
- **Verificando**: stepper 4 pasos animado
- **Conectado**: nombre robot + tiempo + indicador calidad + botón Desconectar

Stepper:
1. Robot en línea (backend confirma raspberry en grupo)
2. Estudiante en línea (backend detecta `fc94:` del estudiante en grupo)
3. Comunicación establecida (ping6 exitoso)
4. ROS2 disponible (`ros2 topic list` desde AWS)

Calidad: Verde <100ms (P2P) | Amarillo >100ms (relay) — actualiza cada 2s

**Heartbeat y detección de fin de sesión — responsabilidad del frontend:**
- Frontend mantiene WebSocket abierto con el backend durante la sesión
- Envía heartbeat cada 30s via WebSocket
- Si el backend cierra la sesión: frontend notifica al usuario y muestra modal de desconexión
- No hay servicio systemd en el PC del estudiante

## 9. Configuración ROS2
Variables en `~/.bashrc`:
```bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file:///var/lib/kalman/cyclonedds.xml
export ROS_DOMAIN_ID=0
export ROS_IPV6=on
source /opt/ros/humble/setup.bash
```

`/var/lib/kalman/cyclonedds.xml`: interfaz `hnet0`, `udp6`, sin multicast, peers `robot_instance` y `aws_instance` (resueltos via `/etc/hosts` de Husarnet). **Se escribe una sola vez** — nunca cambia entre sesiones.

## 10. Endpoints Backend (a implementar)
- `POST /api/session/connect` — valida token; crea grupo Husarnet; hace `attach` de robot+aws-server al grupo; devuelve `claim_code`, `robot_hostname`, `aws_hostname`
- `POST /api/session/device-ready` — recibe `fc94:` del estudiante; hace `attach-device` del estudiante al grupo
- `POST /api/session/student-ready` — avanza stepper frontend
- `POST /api/session/heartbeat` — mantiene sesión activa
- `GET /api/session/status` — verifica si sesión sigue activa
- `POST /api/session/end` — detach dispositivos + elimina grupo

## 11. Dispositivos registrados
- `aws-server` → `fc94:dc06:61c1:1a95:70df:11e9:16ad:4866` (AccountAdmin)
- `dell-host` → `fc94:3930:7441:7843:82cf:806c:ee57:87c9` (Husarnet 2.0.335)
- `raspberry-RRBOT` → `fc94:4ed9:d82c:5684:cb8f:faf0:c915:2d9d` (offline)

> ⚠ `raspberry-lab1` y `alumno-2` pertenecen a cuenta `ivanrr1991@gmail.com`, no a la cuenta principal.

## 12. Stack
- Husarnet 2.0.335+ nightly | ROS2 Humble | CycloneDDS `rmw_cyclonedds_cpp` | Python 3.10+ | Ubuntu 22.04 / WSL2
