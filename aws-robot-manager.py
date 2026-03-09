#!/usr/bin/env python3
"""
Kalman Robotics - AWS Robot Manager
Corre en AWS EC2. Gestiona las conexiones WebSocket de los robots
y expone una API HTTP interna para que el backend envíe comandos.

Puertos:
  8765 — WebSocket para robots (robot-agent.py)
  8766 — HTTP interno para el backend (enviar join/leave/status)

Uso:
  pip install websockets fastapi uvicorn
  python3 aws-robot-manager.py
"""

import asyncio
import json
import logging
import os
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
import websockets
from websockets.server import WebSocketServerProtocol

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
WS_HOST           = os.environ.get("WS_HOST", "0.0.0.0")
WS_PORT           = int(os.environ.get("WS_PORT", "8765"))
API_HOST          = os.environ.get("API_HOST", "127.0.0.1")  # solo interno
API_PORT          = int(os.environ.get("API_PORT", "8766"))
ROBOT_TOKEN       = os.environ.get("ROBOT_TOKEN", "")        # token compartido para robots
INTERNAL_SECRET   = os.environ.get("INTERNAL_SECRET", "")    # secreto para API interna

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("robot-manager")


# ─────────────────────────────────────────────
# Registry de robots conectados
# robot_id → { ws, state, last_heartbeat }
# ─────────────────────────────────────────────
connected_robots: dict[str, dict] = {}


# ─────────────────────────────────────────────
# WebSocket server — lado robot
# ─────────────────────────────────────────────
async def handle_robot(ws: WebSocketServerProtocol):
    robot_id = None
    try:
        # Autenticación via primer mensaje "hello"
        raw = await asyncio.wait_for(ws.recv(), timeout=10)
        data = json.loads(raw)

        if data.get("type") != "hello":
            await ws.close(1008, "Se esperaba mensaje hello")
            return

        robot_id = data.get("robot_id", "")
        if not robot_id:
            await ws.close(1008, "robot_id requerido")
            return

        # Registrar robot
        connected_robots[robot_id] = {
            "ws": ws,
            "state": data.get("state", "IDLE"),
            "last_heartbeat": asyncio.get_event_loop().time(),
        }
        log.info(f"Robot conectado: {robot_id} — estado: {data.get('state')}")

        # Escuchar mensajes del robot
        async for message in ws:
            try:
                msg = json.loads(message)
                msg_type = msg.get("type")

                if msg_type == "heartbeat":
                    connected_robots[robot_id]["last_heartbeat"] = asyncio.get_event_loop().time()
                    connected_robots[robot_id]["state"] = msg.get("state", "UNKNOWN")
                    log.debug(f"Heartbeat de {robot_id}: {msg.get('state')}")

                elif msg_type == "status":
                    if robot_id in connected_robots:
                        connected_robots[robot_id]["state"] = msg.get("state", "UNKNOWN")
                    log.info(f"Estado de {robot_id}: {msg.get('state')}")

                elif msg_type == "error":
                    log.warning(f"Error de {robot_id}: {msg.get('msg')}")

            except json.JSONDecodeError:
                log.warning(f"Mensaje no JSON de {robot_id}: {message}")

    except asyncio.TimeoutError:
        log.warning("Robot no envió hello a tiempo.")
    except websockets.exceptions.ConnectionClosed:
        log.info(f"Robot desconectado: {robot_id}")
    except Exception as e:
        log.error(f"Error con robot {robot_id}: {e}")
    finally:
        if robot_id and robot_id in connected_robots:
            del connected_robots[robot_id]
            log.info(f"Robot eliminado del registry: {robot_id}")


async def ws_server():
    log.info(f"WebSocket server escuchando en ws://{WS_HOST}:{WS_PORT}")
    async with websockets.serve(handle_robot, WS_HOST, WS_PORT):
        await asyncio.Future()  # corre para siempre


# ─────────────────────────────────────────────
# HTTP API interna — lado backend
# ─────────────────────────────────────────────
app = FastAPI(title="Kalman Robot Manager API")


def verify_secret(x_internal_secret: str = Header(...)):
    if not INTERNAL_SECRET or x_internal_secret != INTERNAL_SECRET:
        raise HTTPException(status_code=403, detail="Secreto interno inválido")


class CommandRequest(BaseModel):
    robot_id: str
    join_code: Optional[str] = None


@app.get("/robots")
async def list_robots(x_internal_secret: str = Header(...)):
    verify_secret(x_internal_secret)
    return {
        rid: {"state": info["state"], "connected": True}
        for rid, info in connected_robots.items()
    }


@app.get("/robots/{robot_id}")
async def get_robot(robot_id: str, x_internal_secret: str = Header(...)):
    verify_secret(x_internal_secret)
    if robot_id not in connected_robots:
        raise HTTPException(status_code=404, detail=f"Robot {robot_id} no conectado")
    info = connected_robots[robot_id]
    return {"robot_id": robot_id, "state": info["state"]}


@app.post("/robots/{robot_id}/join")
async def cmd_join(robot_id: str, body: CommandRequest, x_internal_secret: str = Header(...)):
    verify_secret(x_internal_secret)
    if robot_id not in connected_robots:
        raise HTTPException(status_code=404, detail=f"Robot {robot_id} no conectado")
    if not body.join_code:
        raise HTTPException(status_code=400, detail="join_code requerido")

    ws = connected_robots[robot_id]["ws"]
    await ws.send(json.dumps({"cmd": "join", "join_code": body.join_code}))
    log.info(f"Comando join enviado a {robot_id}")
    return {"ok": True}


@app.post("/robots/{robot_id}/leave")
async def cmd_leave(robot_id: str, x_internal_secret: str = Header(...)):
    verify_secret(x_internal_secret)
    if robot_id not in connected_robots:
        raise HTTPException(status_code=404, detail=f"Robot {robot_id} no conectado")

    ws = connected_robots[robot_id]["ws"]
    await ws.send(json.dumps({"cmd": "leave"}))
    log.info(f"Comando leave enviado a {robot_id}")
    return {"ok": True}


@app.post("/robots/{robot_id}/status")
async def cmd_status(robot_id: str, x_internal_secret: str = Header(...)):
    verify_secret(x_internal_secret)
    if robot_id not in connected_robots:
        raise HTTPException(status_code=404, detail=f"Robot {robot_id} no conectado")

    ws = connected_robots[robot_id]["ws"]
    await ws.send(json.dumps({"cmd": "status"}))
    return {"ok": True}


# ─────────────────────────────────────────────
# Entry point — corre WebSocket + HTTP en paralelo
# ─────────────────────────────────────────────
async def main():
    if not INTERNAL_SECRET:
        log.warning("INTERNAL_SECRET no configurado — API interna desprotegida")

    config = uvicorn.Config(app, host=API_HOST, port=API_PORT, log_level="warning")
    server = uvicorn.Server(config)

    log.info(f"HTTP API interna escuchando en http://{API_HOST}:{API_PORT}")
    await asyncio.gather(
        ws_server(),
        server.serve(),
    )


if __name__ == "__main__":
    asyncio.run(main())
