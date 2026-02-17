OpenClaw - Instalador para Proxmox LXC
Solo Gateway (sin LLM local) - Conectar via API

Configuracion de la maquina, crear un fork si requiere modificarlos

CT_ID="${1:-}"
CT_STORAGE="${2:-local-lvm}"
CT_BRIDGE="${3:-vmbr0}"
CT_HOSTNAME="openclaw"
CT_MEMORY=4096
CT_CORES=2
CT_DISK=20

 Ejecutar desde la SHELL del nodo Proxmox  👇🏼

```bash
curl -fsSL https://raw.githubusercontent.com/jhonsu01/OpenClaw-Instalador-para-Proxmox-LXC/refs/heads/main/install-openclaw-lxc-v2.sh | bash
```
Lo primero que te pedirá es la contraseña para el usuario openclaw, y después instala todo automático
Homebrew → Node.js 22 → OpenClaw → Docker.


🦞🍺
🚀 You’ve been invited to join the GLM Coding Plan! Enjoy full support for Claude Code, Cline, and 20+ top coding tools — starting at just $10/month. Subscribe now and grab the limited-time deal! Link：[https://z.ai/subscribe?ic=G5QLAPYLLJ](https://z.ai/subscribe?ic=G5QLAPYLLJ)
