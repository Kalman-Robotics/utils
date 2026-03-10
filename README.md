# Kalman Robotics — Utils

Scripts de configuración para la plataforma de laboratorios remotos.

---

## Student Setup

Ejecutar al inicio de cada sesión de laboratorio:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Kalman-Robotics/utils/master/student-setup.sh) SESSION_TOKEN
```

**Modo dev** (sin backend):
```bash
bash <(curl -sSL https://raw.githubusercontent.com/Kalman-Robotics/utils/master/student-setup.sh) --dev --claim-code alaurao@uni.pe/XXXX
```

---

## Robot Setup

Ejecutar **una sola vez** durante la configuración inicial del robot:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Kalman-Robotics/utils/master/robot-setup.sh) alaurao@uni.pe/XXXX
```

Al finalizar, guarda el `fc94:` que muestra en el backend como dispositivo permanente.
