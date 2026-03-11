#!/usr/bin/env python3
"""
Camera Broadcaster - Transmite camaras del laboratorio sin navegador.

Uso:
    python camera-broadcaster.py                # todos los labs desde API (default)
    python camera-broadcaster.py --list         # listar camaras disponibles

Requisitos:
    pip install aiortc opencv-python python-socketio[asyncio_client] aiohttp requests

El script consulta la API para obtener los labs activos con camaras asignadas
y lanza un broadcaster por cada uno. Camaras con el mismo nombre se comparten
(se abren una sola vez). Si una camara falla, se salta y las demas continuan.
"""

import asyncio
import argparse
import fractions
import sys
import time
import cv2
import numpy as np
import socketio
import requests
from aiortc import RTCPeerConnection, RTCSessionDescription, MediaStreamTrack, RTCConfiguration, RTCIceServer
from aiortc.sdp import candidate_from_sdp
from av import VideoFrame

VIDEO_CLOCK_RATE = 90000
VIDEO_TIME_BASE = fractions.Fraction(1, VIDEO_CLOCK_RATE)

SFU_URL = 'https://kalmanrobotics.io'

# ── Colores para log ──
class C:
    OK = '\033[92m'
    WARN = '\033[93m'
    ERR = '\033[91m'
    INFO = '\033[94m'
    DIM = '\033[90m'
    RESET = '\033[0m'

def log(msg, level='info'):
    t = time.strftime('%H:%M:%S')
    colors = {'ok': C.OK, 'warn': C.WARN, 'err': C.ERR, 'info': C.INFO}
    c = colors.get(level, C.INFO)
    print(f'{C.DIM}[{t}]{C.RESET} {c}{msg}{C.RESET}', flush=True)


# ── Lector compartido de camara ──
class SharedCamera:
    """Abre una camara fisica una sola vez y comparte frames entre multiples tracks."""

    def __init__(self, device_index, width=1280, height=720, fps=30):
        self.device_index = device_index
        self.cap = cv2.VideoCapture(device_index)
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.cap.set(cv2.CAP_PROP_FPS, fps)
        self.fps = fps
        self._latest_frame = None
        self._running = False

        if not self.cap.isOpened():
            raise RuntimeError(f"No se pudo abrir camara {device_index}")

        ret, frame = self.cap.read()
        if not ret:
            raise RuntimeError(f"Camara {device_index} no devuelve frames")
        self._latest_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        h, w = frame.shape[:2]
        log(f"Camara {device_index} abierta: {w}x{h}", 'ok')

    async def run(self):
        """Loop que lee frames en background."""
        self._running = True
        loop = asyncio.get_event_loop()
        interval = 1.0 / self.fps
        while self._running:
            t0 = time.time()
            ret, frame = await loop.run_in_executor(None, self.cap.read)
            if ret:
                self._latest_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            wait = interval - (time.time() - t0)
            if wait > 0:
                await asyncio.sleep(wait)

    def stop(self):
        self._running = False
        if self.cap and self.cap.isOpened():
            self.cap.release()
            log(f"Camara {self.device_index} cerrada", 'info')

    def create_track(self):
        """Crea un track independiente que lee del frame compartido."""
        return SharedCameraTrack(self)


class SharedCameraTrack(MediaStreamTrack):
    """Track que sirve frames del SharedCamera. Cada Broadcaster tiene su propia instancia."""
    kind = "video"

    def __init__(self, shared_camera):
        super().__init__()
        self._cam = shared_camera
        self._start = None
        self._frame_count = 0

    async def recv(self):
        if self._start is None:
            self._start = time.time()

        self._frame_count += 1
        target_time = self._start + self._frame_count / self._cam.fps
        wait = target_time - time.time()
        if wait > 0:
            await asyncio.sleep(wait)

        frame = self._cam._latest_frame
        if frame is None:
            frame = np.zeros((480, 640, 3), dtype=np.uint8)

        vf = VideoFrame.from_ndarray(frame, format="rgb24")
        vf.pts = int((time.time() - self._start) * VIDEO_CLOCK_RATE)
        vf.time_base = VIDEO_TIME_BASE
        return vf


# ── Detectar camaras fisicas reales ──
import os
import platform


def get_v4l2_name(index):
    """Lee el nombre del dispositivo V4L2 en Linux (/sys/class/video4linux/videoN/name)."""
    path = f"/sys/class/video4linux/video{index}/name"
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except:
        return None


def detect_physical_cameras():
    """
    Detecta camaras fisicas reales con su nombre V4L2.
    En Linux cada USB cam crea 2 /dev/video (captura + metadata).
    Retorna: [(index, v4l2_name, width, height), ...]  solo las de captura real.
    """
    is_linux = platform.system() == 'Linux'
    working = []
    seen_names = set()

    for i in range(20):
        # En Linux, leer nombre V4L2 para identificar la camara
        v4l2_name = get_v4l2_name(i) if is_linux else f"camera_{i}"

        # Si ya vimos esta camara (mismo nombre = es el stream de metadata), saltar
        if v4l2_name and v4l2_name in seen_names:
            continue

        cap = cv2.VideoCapture(i)
        if cap.isOpened():
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
            ret, frame = cap.read()
            if ret:
                h, w = frame.shape[:2]
                working.append((i, v4l2_name or f"camera_{i}", w, h))
                if v4l2_name:
                    seen_names.add(v4l2_name)
            cap.release()
        else:
            cap.release()

    return working


def match_camera_by_label(label, cameras):
    """
    Busca en la lista de camaras fisicas cual matchea con el label de la API.
    El label viene del browser (ej: "MX Brio", "Integrated Webcam (0bda:567e)").
    El v4l2_name es algo como "MX Brio" o "Integrated Webcam".
    Match por substring case-insensitive.
    """
    if not label:
        return None

    label_lower = label.lower()
    for idx, v4l2_name, w, h in cameras:
        name_lower = v4l2_name.lower()
        # Match si uno contiene al otro
        if name_lower in label_lower or label_lower in name_lower:
            return idx
        # Match parcial: primera palabra significativa
        label_words = [w for w in label_lower.replace('_', ' ').split() if len(w) > 2]
        name_words = [w for w in name_lower.replace('_', ' ').split() if len(w) > 2]
        for lw in label_words:
            for nw in name_words:
                if lw in nw or nw in lw:
                    return idx
    return None


def list_cameras():
    print("\nCamaras fisicas detectadas:")
    print("-" * 60)
    cams = detect_physical_cameras()
    if not cams:
        print("  No se encontraron camaras.")
        print()
        return
    for idx, name, w, h in cams:
        print(f"  /dev/video{idx}  [{idx}]  {name}  ({w}x{h})")
    print()


# ── Broadcaster principal ──
class Broadcaster:
    def __init__(self, lab_id, lab_name, cam1_track, cam2_track=None):
        self.lab_id = lab_id
        self.lab_name = lab_name or lab_id[:12]
        self.cam1 = cam1_track
        self.cam2 = cam2_track
        self.sio = socketio.AsyncClient(
            reconnection=True,
            reconnection_attempts=0,  # infinito
            reconnection_delay=2,
        )
        self.peers = {}  # clientId -> RTCPeerConnection
        self._setup_events()

    def _setup_events(self):
        sio = self.sio
        tag = self.lab_name

        @sio.event
        async def connect():
            log(f"[{tag}] Socket.IO conectado", 'ok')
            await sio.emit('robot-register', {
                'robotId': self.lab_id,
                'hostname': 'broadcaster-headless'
            })
            log(f"[{tag}] Registrado con robotId={self.lab_id}", 'ok')

        @sio.event
        async def connect_error(data):
            log(f"[{tag}] Socket.IO connect_error: {data}", 'err')

        @sio.event
        async def disconnect():
            log(f"[{tag}] Socket.IO desconectado", 'warn')
            for cid, pc in list(self.peers.items()):
                try:
                    await pc.close()
                except:
                    pass
            self.peers.clear()

        @sio.on('client-joined')
        async def on_client_joined(data):
            client_id = data.get('clientId')
            log(f"[{tag}] Viewer conectado: {client_id}", 'info')
            try:
                await self._create_offer(client_id)
            except Exception as e:
                log(f"[{tag}] Error creando offer para {client_id}: {type(e).__name__}: {e}", 'err')
                import traceback
                traceback.print_exc()

        @sio.on('client-left')
        async def on_client_left(data):
            client_id = data.get('clientId')
            pc = self.peers.pop(client_id, None)
            if pc:
                await pc.close()
                log(f"[{tag}] Viewer desconectado: {client_id}", 'info')

        @sio.on('answer')
        async def on_answer(data):
            from_id = data.get('fromId')
            pc = self.peers.get(from_id)
            if pc:
                try:
                    answer = RTCSessionDescription(sdp=data['answer']['sdp'], type=data['answer']['type'])
                    await pc.setRemoteDescription(answer)
                    log(f"[{tag}] Answer recibido de {from_id[:8]}...", 'ok')
                except Exception as e:
                    log(f"[{tag}] Error setRemoteDescription: {type(e).__name__}: {e}", 'err')
            else:
                log(f"[{tag}] Answer de {from_id[:8]} pero no hay PeerConnection", 'warn')

        @sio.on('ice-candidate')
        async def on_ice(data):
            from_id = data.get('fromId')
            pc = self.peers.get(from_id)
            candidate_data = data.get('candidate')
            if pc and candidate_data and candidate_data.get('candidate'):
                try:
                    sdp_str = candidate_data['candidate']
                    if sdp_str.startswith('candidate:'):
                        sdp_str = sdp_str[10:]
                    candidate = candidate_from_sdp(sdp_str)
                    candidate.sdpMid = candidate_data.get('sdpMid', '0')
                    candidate.sdpMLineIndex = candidate_data.get('sdpMLineIndex', 0)
                    await pc.addIceCandidate(candidate)
                except Exception as e:
                    log(f"[{tag}] Error ICE candidate: {type(e).__name__}: {e}", 'warn')

    async def _create_offer(self, client_id):
        tag = self.lab_name
        log(f"[{tag}] Creando PeerConnection para {client_id[:8]}...", 'info')
        config = RTCConfiguration(iceServers=[
            RTCIceServer(urls=['stun:stun.l.google.com:19302']),
            RTCIceServer(urls=['stun:stun1.l.google.com:19302']),
            RTCIceServer(
                urls=['turn:44.200.186.26:3478'],
                username='kalman',
                credential='robotics2024'
            ),
        ])
        pc = RTCPeerConnection(configuration=config)
        self.peers[client_id] = pc

        # Agregar tracks
        tracks_added = 0
        if self.cam1:
            pc.addTrack(self.cam1)
            tracks_added += 1
        if self.cam2 and self.cam2 is not self.cam1:
            pc.addTrack(self.cam2)
            tracks_added += 1
        log(f"[{tag}] {tracks_added} track(s) agregado(s)", 'info')

        @pc.on('iceconnectionstatechange')
        async def on_state():
            state = pc.iceConnectionState
            if state == 'connected':
                log(f"[{tag}] CONECTADO con viewer {client_id[:8]}", 'ok')
            elif state == 'failed':
                log(f"[{tag}] ICE FAILED con viewer {client_id[:8]}", 'err')
                self.peers.pop(client_id, None)
                await pc.close()
            elif state in ('disconnected', 'closed'):
                log(f"[{tag}] ICE {state} con viewer {client_id[:8]}", 'info')
                self.peers.pop(client_id, None)
                await pc.close()
            else:
                log(f"[{tag}] ICE {client_id[:8]}: {state}", 'info')

        offer = await pc.createOffer()
        await pc.setLocalDescription(offer)
        log(f"[{tag}] Offer enviado a {client_id[:8]} ({len(pc.localDescription.sdp)} bytes)", 'ok')

        await self.sio.emit('offer', {
            'targetId': client_id,
            'offer': {
                'sdp': pc.localDescription.sdp,
                'type': pc.localDescription.type,
            }
        })

    async def start(self):
        await self.sio.connect(SFU_URL, transports=['polling', 'websocket'])
        cams = "cam1"
        if self.cam2 and self.cam2 is not self.cam1:
            cams += " + cam2"
        log(f"[{self.lab_name}] Transmitiendo ({cams}). Ctrl+C para detener.", 'ok')

        try:
            while True:
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            pass

    async def stop(self):
        for pc in self.peers.values():
            try:
                await pc.close()
            except:
                pass
        self.peers.clear()
        if self.cam1:
            self.cam1.stop()
        if self.cam2 and self.cam2 is not self.cam1:
            self.cam2.stop()
        if self.sio.connected:
            await self.sio.disconnect()


# ── Ejecutar un broadcaster para un lab ──
async def run_single(lab_id, lab_name, cam1_track, cam2_track):
    broadcaster = Broadcaster(lab_id, lab_name, cam1_track, cam2_track)
    try:
        await broadcaster.start()
    except Exception as e:
        log(f"[{lab_name}] Error fatal: {type(e).__name__}: {e}", 'err')
        import traceback
        traceback.print_exc()
        await broadcaster.stop()


# ── Main ──
async def main():
    parser = argparse.ArgumentParser(
        description='Camera Broadcaster - Transmite camaras de todos los laboratorios',
    )
    parser.add_argument('--list', action='store_true', help='Listar camaras disponibles')
    parser.add_argument('--width', type=int, default=1280, help='Ancho de video (default: 1280)')
    parser.add_argument('--height', type=int, default=720, help='Alto de video (default: 720)')
    parser.add_argument('--fps', type=int, default=30, help='FPS (default: 30)')
    args = parser.parse_args()

    if args.list:
        list_cameras()
        return

    # Siempre traer todos los labs desde la API
    api_url = f"{SFU_URL}/api/broadcast/labs"
    log(f"Consultando {api_url} ...", 'info')
    try:
        resp = requests.get(api_url, timeout=10)
        resp.raise_for_status()
        server_labs = resp.json()
        log(f"API: {len(server_labs)} lab(s) con camaras", 'ok')
    except Exception as e:
        log(f"Error consultando API: {type(e).__name__}: {e}", 'err')
        sys.exit(1)

    if not server_labs:
        log("No hay labs con camaras configuradas.", 'warn')
        sys.exit(0)

    # Detectar camaras fisicas reales conectadas
    log("Detectando camaras fisicas...", 'info')
    physical_cams = detect_physical_cameras()
    if not physical_cams:
        log("No se detectaron camaras conectadas.", 'err')
        log("Usa --list para diagnosticar.", 'err')
        sys.exit(1)

    log(f"Camaras fisicas detectadas: {len(physical_cams)}", 'ok')
    for idx, name, w, h in physical_cams:
        log(f"  /dev/video{idx} = {name} ({w}x{h})", 'ok')

    # Matchear camaras de la API con dispositivos fisicos por label
    cam_name_to_dev = {}  # cam_name (de la API) -> device index
    labs = []

    for sl in server_labs:
        lab_name = sl['name']
        log(f"  Lab: {lab_name} (id={sl['lab_id'][:12]}...)", 'info')

        # cam1
        cam1_name = sl.get('cam1_name')
        cam1_label = sl.get('cam1_label', '')
        if not cam1_name:
            log(f"    [!] Sin camara principal, saltando lab", 'warn')
            continue

        if cam1_name in cam_name_to_dev:
            c1 = cam_name_to_dev[cam1_name]
            log(f"    cam1 = /dev/video{c1} ({cam1_name}) [reutilizada]", 'info')
        else:
            c1 = match_camera_by_label(cam1_label, physical_cams)
            if c1 is not None:
                cam_name_to_dev[cam1_name] = c1
                v4l2 = next((n for i, n, w, h in physical_cams if i == c1), '?')
                log(f"    cam1 = /dev/video{c1} '{v4l2}' ← matched '{cam1_label}'", 'ok')
            else:
                log(f"    [!] No se encontro camara para '{cam1_name}' (label='{cam1_label}')", 'warn')
                log(f"        Camaras disponibles: {[n for _, n, _, _ in physical_cams]}", 'warn')
                continue

        entry = {'lab_id': sl['lab_id'], 'name': lab_name, 'cam1': c1}

        # cam2
        cam2_name = sl.get('cam2_name')
        cam2_label = sl.get('cam2_label', '')
        if cam2_name and cam2_name != cam1_name:
            if cam2_name in cam_name_to_dev:
                c2 = cam_name_to_dev[cam2_name]
                log(f"    cam2 = /dev/video{c2} ({cam2_name}) [reutilizada]", 'info')
                entry['cam2'] = c2
            else:
                c2 = match_camera_by_label(cam2_label, physical_cams)
                if c2 is not None:
                    cam_name_to_dev[cam2_name] = c2
                    v4l2 = next((n for i, n, w, h in physical_cams if i == c2), '?')
                    log(f"    cam2 = /dev/video{c2} '{v4l2}' ← matched '{cam2_label}'", 'ok')
                    entry['cam2'] = c2
                else:
                    log(f"    [!] No se encontro camara para '{cam2_name}' (label='{cam2_label}'), cam2 = cam1", 'warn')
        else:
            log(f"    cam2 = misma que cam1", 'info')

        labs.append(entry)

    if not labs:
        log("Ningun lab tiene camaras validas.", 'err')
        sys.exit(1)

    # Resumen
    print()
    print("=" * 55)
    print(f"  Camera Broadcaster  -  {len(labs)} lab{'s' if len(labs) > 1 else ''}")
    print("-" * 55)
    for lab in labs:
        name = lab['name']
        c2 = lab.get('cam2')
        print(f"  {name}:  cam1=/dev/video{lab['cam1']}  cam2={'/dev/video' + str(c2) if c2 is not None else '='}")
    print(f"  Resolucion: {args.width}x{args.height} @ {args.fps}fps")
    print(f"  Camaras fisicas usadas: {len(cam_name_to_dev)}")
    print("=" * 55)
    print()

    # Abrir cada camara fisica (si una falla, continuar con las demas)
    shared_cams = {}  # device_index -> SharedCamera
    for cam_name, dev_idx in cam_name_to_dev.items():
        if dev_idx in shared_cams:
            continue
        w, h = args.width, args.height
        log(f"Abriendo camara /dev/video{dev_idx} '{cam_name}' ({w}x{h}@{args.fps}fps)...", 'info')
        try:
            shared_cams[dev_idx] = SharedCamera(dev_idx, w, h, args.fps)
        except RuntimeError as e:
            log(f"ERROR camara /dev/video{dev_idx} '{cam_name}': {e}", 'err')
            log(f"  Los labs que usen esta camara transmitiran sin ella.", 'warn')

    if not shared_cams:
        log("No se pudo abrir ninguna camara. Abortando.", 'err')
        log("Usa --list para ver camaras disponibles.", 'err')
        sys.exit(1)

    # Iniciar lectores de camara en background
    bg_tasks = []
    for cam in shared_cams.values():
        bg_tasks.append(asyncio.create_task(cam.run()))

    # Lanzar un broadcaster por lab (cada uno con sus propios tracks)
    tasks = []
    for lab in labs:
        cam1_shared = shared_cams.get(lab['cam1'])
        cam2_shared = shared_cams.get(lab.get('cam2'))

        if not cam1_shared:
            log(f"[{lab['name']}] Camara principal no disponible, saltando lab", 'err')
            continue

        cam1_track = cam1_shared.create_track()
        cam2_track = None
        if cam2_shared and cam2_shared is not cam1_shared:
            cam2_track = cam2_shared.create_track()

        log(f"[{lab['name']}] Iniciando broadcaster...", 'info')
        t = asyncio.create_task(run_single(
            lab['lab_id'],
            lab['name'],
            cam1_track,
            cam2_track,
        ))
        tasks.append(t)

    if not tasks:
        log("No se pudo iniciar ningun broadcaster.", 'err')
        sys.exit(1)

    log(f"{len(tasks)} broadcaster(s) activo(s). Ctrl+C para detener.", 'ok')

    try:
        await asyncio.gather(*tasks)
    except KeyboardInterrupt:
        for t in tasks:
            t.cancel()
        log("Todos los broadcasters detenidos.", 'info')


if __name__ == '__main__':
    asyncio.run(main())