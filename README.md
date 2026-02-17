OpenClaw - Instalador para Proxmox LXC
Solo Gateway (sin LLM local) - Conectar via API

 Ejecutar desde la SHELL del nodo Proxmox  👇🏼

```bash
curl -fsSL https://raw.githubusercontent.com/jhonsu01/OpenClaw-Instalador-para-Proxmox-LXC/refs/heads/main/install-openclaw-lxc-v2.sh | bash
```
Lo primero que te pedirá sera configuracion maquina y cuando termine asignar una contraseña para el usuario openclaw, y después instala todo automático
Homebrew → Node.js 22 → OpenClaw → Docker.

```bash
pct exec $CT_ID -- su - openclaw
```
```bash
openclaw onboard --install-daemon
```

Telegram Recomendado (opcional)
```bash
openclaw pairing approve telegram ABC123
```

🦞🍺
🚀 You’ve been invited to join the GLM Coding Plan! Enjoy full support for Claude Code, Cline, and 20+ top coding tools — starting at just $10/month. Subscribe now and grab the limited-time deal! Link：[https://z.ai/subscribe?ic=G5QLAPYLLJ](https://z.ai/subscribe?ic=G5QLAPYLLJ)
