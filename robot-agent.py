#!/usr/bin/env python3
"""
Kalman Robotics - Robot Agent
Corre 24/7 en cada robot como servicio systemd.
Se conecta al backend via WebSocket y espera comandos de sesión.

Cada robot tiene su propio ROBOT_ID y ROBOT_TOKEN configurados
en el archivo .service correspondiente.

Instalación:
  sudo cp kalman-agent-robot.py /usr/local/bin/kalman-agent-robot.py
  sudo cp kalman-agent-robot.service /etc/systemd/system/
  sudo systemctl enable kalman-agent-robot
  sudo systemctl start kalman-agent-robot
"""

import asyncio
import json
import logging
import os
import subprocess
import websockets
from enum import Enum

# ─────────────────────────────────────────────
# Config (desde variables de entorno del .service)
# ─────────────────────────────────────────────
BACKEND_WS_URL     = os.environ.get("BACKEND_WS_URL", "wss://kalmanrobotics.io/ws/robot")
ROBOT_TOKEN        = os.environ.get("ROBOT_TOKEN", "")
ROBOT_ID           = os.environ.get("ROBOT_ID", "")        # ej: "raspberry-RRBOT"
HEARTBEAT_INTERVAL = int(os.environ.get("HEARTBEAT_INTERVAL", "30"))
RECONNECT_DELAY    = int(os.environ.get("RECONNECT_DELAY", "5"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(robot)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

class RobotLogAdapter(logging.LoggerAdapter):
    def process(self, msg, kwargs):
        return msg, {**kwargs, "extra": {"robot": self.extra.get("robot", "unknown")}}

_base_log = logging.getLogger("kalman-agent-robot")
logging.basicConfig()

# Formato con robot ID
handler = logging.StreamHandler()
handler.setFormatter(logging.Formatter(
    f"%(asctime)s [%(levelname)s] [{ROBOT_ID or 'unknown'}] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
))
_base_log.handlers = [handler]
_base_log.propagate = False
_base_log.setLevel(logging.INFO)
log = _base_log


# ─────────────────────────────────────────────
# Estados del robot
# ─────────────────────────────────────────────
class State(Enum):
    IDLE      = "IDLE"
    JOINING   = "JOINING"
    CONNECTED = "CONNECTED"
    LEAVING   = "LEAVING"


state = State.IDLE


# ─────────────────────────────────────────────
# Husarnet CLI
# ─────────────────────────────────────────────
def husarnet_join(join_code: str) -> bool:
    log.info(f"Ejecutando husarnet join...")
    try:
        result = subprocess.run(
            ["husarnet", "join", join_code, ROBOT_ID],
            timeout=60,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            log.info("husarnet join exitoso.")
            return True
        log.error(f"husarnet join falló: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        log.error("husarnet join: timeout de 60s alcanzado.")
    except FileNotFoundError:
        log.error("husarnet no encontrado. ¿Está instalado?")
    return False


def husarnet_leave() -> bool:
    log.info("Ejecutando husarnet leave...")
    try:
        result = subprocess.run(
            ["husarnet", "leave"],
            timeout=30,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            log.info("husarnet leave exitoso.")
            return True
        log.error(f"husarnet leave falló: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        log.error("husarnet leave: timeout de 30s alcanzado.")
    except FileNotFoundError:
        log.error("husarnet no encontrado.")
    return False


# ─────────────────────────────────────────────
# Handlers de comandos
# ─────────────────────────────────────────────
async def handle_join(ws, data: dict):
    global state
    join_code = data.get("join_code", "")
    if not join_code:
        log.error("Comando join recibido sin join_code.")
        await ws.send(json.dumps({"type": "error", "msg": "join_code requerido"}))
        return

    state = State.JOINING
    await ws.send(json.dumps({"type": "status", "state": state.value, "robot_id": ROBOT_ID}))

    success = husarnet_join(join_code)
    if success:
        state = State.CONNECTED
    else:
        state = State.IDLE

    await ws.send(json.dumps({"type": "status", "state": state.value, "robot_id": ROBOT_ID}))


async def handle_leave(ws):
    global state
    state = State.LEAVING
    await ws.send(json.dumps({"type": "status", "state": state.value, "robot_id": ROBOT_ID}))

    husarnet_leave()
    state = State.IDLE
    await ws.send(json.dumps({"type": "status", "state": state.value, "robot_id": ROBOT_ID}))


# ─────────────────────────────────────────────
# Heartbeat
# ─────────────────────────────────────────────
async def heartbeat_loop(ws):
    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL)
        try:
            await ws.send(json.dumps({
                "type": "heartbeat",
                "state": state.value,
                "robot_id": ROBOT_ID,
            }))
            log.debug(f"Heartbeat enviado. Estado: {state.value}")
        except Exception:
            break


# ─────────────────────────────────────────────
# Bucle principal de conexión
# ─────────────────────────────────────────────
async def agent_loop():
    url = f"{BACKEND_WS_URL}/{ROBOT_ID}"
    headers = {"Authorization": f"Bearer {ROBOT_TOKEN}"}

    while True:
        try:
            log.info(f"Conectando a {url}...")
            async with websockets.connect(url, extra_headers=headers) as ws:
                log.info("Conexión WebSocket establecida.")
                await ws.send(json.dumps({
                    "type": "hello",
                    "robot_id": ROBOT_ID,
                    "state": state.value,
                }))

                hb_task = asyncio.create_task(heartbeat_loop(ws))

                async for message in ws:
                    try:
                        data = json.loads(message)
                        cmd = data.get("cmd")
                        log.info(f"Comando recibido: {cmd}")

                        if cmd == "join":
                            await handle_join(ws, data)
                        elif cmd == "leave":
                            await handle_leave(ws)
                        elif cmd == "status":
                            await ws.send(json.dumps({
                                "type": "status",
                                "state": state.value,
                                "robot_id": ROBOT_ID,
                            }))
                        else:
                            log.warning(f"Comando desconocido: {cmd}")

                    except json.JSONDecodeError:
                        log.warning(f"Mensaje no JSON recibido: {message}")

                hb_task.cancel()

        except (websockets.exceptions.ConnectionClosed,
                websockets.exceptions.WebSocketException,
                OSError) as e:
            log.warning(f"Conexión perdida: {e}. Reconectando en {RECONNECT_DELAY}s...")
        except Exception as e:
            log.error(f"Error inesperado: {e}. Reconectando en {RECONNECT_DELAY}s...")

        await asyncio.sleep(RECONNECT_DELAY)


# ─────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────
if __name__ == "__main__":
    if not ROBOT_TOKEN:
        log.error("ROBOT_TOKEN no configurado. Saliendo.")
        exit(1)
    if not ROBOT_ID:
        log.error("ROBOT_ID no configurado. Saliendo.")
        exit(1)
    log.info(f"Kalman Agent iniciando. Robot ID: {ROBOT_ID}")
    asyncio.run(agent_loop())
