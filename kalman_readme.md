Kalman Robotics
Plataforma de Laboratorios Remotos de Robótica
Documento de Arquitectura y Lineamientos Técnicos

1. Descripción del Proyecto
Kalman Robotics es una plataforma educativa que permite a estudiantes acceder remotamente a robots físicos para practicar ROS2, Python y manipulación robótica. Cada sesión conecta al estudiante con un robot real a través de una red VPN peer-to-peer usando Husarnet.

2. Casos de Uso
Robots soportados
    • myCobot Pro 450
    • TurtleBot4
    • Roadmap: incorporación de más tipos de robots
Flujo de una sesión
    • Estudiante reserva laboratorio en la plataforma web
    • 15 min antes: backend crea grupo Husarnet temporal
    • Robot (Raspberry Pi) hace join automáticamente vía agente
    • AWS EC2 hace join al grupo de sesión
    • Estudiante ejecuta script de conexión → join + configuración ROS2
    • Sesión activa: control via ROS2, Python, SSH y video WebRTC
    • Al terminar: robot sale del grupo, backend elimina el grupo

3. Arquitectura General
Tres dispositivos por sesión
Dispositivo
Rol
Raspberry Pi (robot)
Agente Kalman 24/7 via systemd, ejecuta ROS2
AWS EC2
Backend + ROS2 bridge + rosbridge para frontend
PC del estudiante
Ejecuta script de sesión, conecta via Husarnet

Red Husarnet
    • Grupos temporales creados por sesión via Dashboard API v3
    • Cada dispositivo tiene IPv6 permanente basado en su clave pública
    • Conexión peer-to-peer entre los tres dispositivos
    • Grupo eliminado al terminar la sesión
Comunicación ROS2
    • RMW: CycloneDDS (rmw_cyclonedds_cpp)
    • Interfaz de red: hnet0 (Husarnet)
    • Sin multicast, peers explícitos en cyclonedds.xml
    • rosbridge_suite en AWS expone tópicos al frontend via WebSocket :9090

4. APIs Utilizadas
Husarnet Dashboard API v3
    • Versión requerida: 2.0.335+ (canal nightly)
    • Autenticación: Daemon-proxied (X-Husarnet-Secret) o JWT directo
    • Base URL: https://api.beta.husarnet.com
Endpoints principales
    • POST /v3/web/groups → crear grupo de sesión
    • DELETE /v3/web/groups/{id} → eliminar grupo al terminar
    • POST /v3/web/groups/attach-device → adjuntar robot al grupo
    • POST /v3/web/groups/detach-device → desadjuntar al terminar
Husarnet Daemon API (local)
    • Puerto: localhost:16216
    • Autenticación: secret en body del POST
    • Nota: en versión nightly (2.0.335+) el join se hace via CLI, no API
Endpoints GET disponibles
    • GET /hi → test de conectividad
    • GET /api/status → estado completo del daemon
    • GET /api/whitelist/ls → lista de whitelist
    • GET /api/logs/get → logs en memoria
Backend Kalman (a implementar)
    • POST /api/session/connect → devuelve join_code, robot_ipv6, aws_ipv6
    • POST /api/session/student-ready → notifica que el estudiante está conectado
    • POST /api/session/heartbeat → heartbeat del monitor del estudiante
    • GET /api/session/status → verifica si la sesión sigue activa

5. Agente Kalman (Raspberry Pi)
Servicio systemd que corre 24/7 en cada robot. Se conecta al backend via WebSocket persistente y espera comandos.
Responsabilidades
    • Mantener WebSocket persistente hacia AWS (Robot Manager)
    • Recibir comando join → ejecutar husarnet join via CLI
    • Recibir comando leave → ejecutar husarnet leave
    • Enviar heartbeat cada 30s al backend
    • Reconectarse automáticamente si pierde conexión con AWS
Estados del robot
    • IDLE → esperando sesión
    • JOINING → ejecutando husarnet join
    • CONNECTED → sesión activa
    • LEAVING → saliendo del grupo

6. Script del Estudiante
Comando de ejecución
bash <(curl -sSL https://kalmanrobotics.io/connect.sh) SESSION_TOKEN
kalman-setup.sh — ejecución única por sesión
    • Detectar entorno: Linux nativo o WSL2
    • Habilitar systemd en WSL2 si no está activo
    • Instalar dependencias: curl, jq, coreutils
    • Instalar Husarnet si no está
    • Instalar ROS2 Humble si no está
    • Validar token con backend → obtener join_code, robot_ipv6, aws_ipv6
    • Ejecutar husarnet join con el join code de sesión
    • Actualizar /etc/hosts con aliases: robot-hostname y kalman-aws
    • Generar cyclonedds.xml con peers explícitos (robot + AWS)
    • Exportar variables ROS2 en ~/.bashrc
    • Instalar y activar servicio monitor kalman.service
    • Reportar al backend que el estudiante está listo
kalman-connect.sh — monitor de sesión (systemd)
    • Verificar que Husarnet daemon esté corriendo
    • Loop cada 30s: check sesión activa + check conectividad con robot
    • Reconectar si se pierde conectividad (obtiene nuevo join code del backend)
    • Enviar heartbeat al backend
    • Al terminar sesión: limpiar /etc/hosts y detenerse
Seguridad
    • Token único por sesión + por estudiante
    • Token con máximo 3 usos (soporte para cambio de laptop)
    • Token expira al terminar la sesión
    • Grupo Husarnet limitado a 3 dispositivos: robot, AWS, estudiante
    • Join code nunca expuesto directamente, se obtiene del backend con el token
    • Grupo eliminado al terminar → join code muerto

7. Frontend — Modal de Conexión
Estados del modal
    • Idle → muestra comando de conexión con botón copiar + botón Conectar
    • Verificando → stepper animado de 4 pasos, botón deshabilitado
    • Conectado → indicador de calidad + botón Desconectar
4 pasos de verificación
    • Robot en línea → backend confirma que Raspberry está conectada a Husarnet
    • Estudiante en línea → backend detecta dispositivo del estudiante en el grupo
    • Comunicación establecida → ping6 entre estudiante y robot exitoso
    • ROS2 disponible → ros2 topic list retorna resultados desde AWS
Indicador de calidad de conexión
    • Verde + Excelente → latencia < 100ms (conexión P2P directa)
    • Amarillo + Regular → latencia > 100ms (posible tunneling)
    • Latencia se actualiza cada 2 segundos

8. Configuración ROS2
Variables de entorno (.bashrc)
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file:///var/lib/kalman/cyclonedds.xml
export ROS_DOMAIN_ID=0
export ROS_IPV6=on
source /opt/ros/humble/setup.bash
cyclonedds.xml
    • NetworkInterfaceAddress: hnet0 (interfaz Husarnet)
    • AllowMulticast: false
    • Transport: udp6
    • Peers explícitos: IPv6 del robot + IPv6 de AWS
    • Generado una sola vez al inicio de sesión (IPv6 son permanentes)

9. Versiones y Requisitos
Componente
Versión / Requisito
Husarnet
2.0.335+ (canal nightly)
Dashboard API
v3 (beta.husarnet.com)
ROS2
Humble (Ubuntu 22.04)
CycloneDDS
rmw_cyclonedds_cpp
Python
3.10+
OS estudiante
Ubuntu 22.04 / WSL2
OS robot
Ubuntu 22.04 (Raspberry Pi)
AWS
EC2 Ubuntu 22.04


10. Referencias
    • Husarnet Dashboard API v3: https://husarnet.com/docs/dashboard-api/
    • Husarnet Daemon API: https://husarnet.com/docs/client_api/
    • Husarnet Beta docs: https://husarnet.com/docs/beta-docs/
    • husarnet-ros2router: https://github.com/husarnet/husarnet-ros2router
    • Referencia ERC2025: https://github.com/husarion/erc2025
    • TheConstruct RRL (referencia de scripts): https://app.theconstruct.ai