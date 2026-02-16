#!/usr/bin/env bash
#================================================================
#  OpenClaw - Setup interno (ejecutar como root dentro del LXC)
#  Instala: Homebrew → Node.js 22 → OpenClaw
#================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Verificar que estamos como root dentro del LXC
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✘] Ejecuta este script como root dentro del LXC${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  🦞 OpenClaw - Setup Interno del LXC${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

# ── Asignar contraseña al usuario openclaw ────────────────────
echo -e "${YELLOW}Asigna una contraseña para el usuario 'openclaw':${NC}"
passwd openclaw
echo ""
echo -e "${GREEN}[✔] Contraseña asignada${NC}"

# ── Instalar Homebrew ─────────────────────────────────────────
echo ""
echo -e "${CYAN}[1/4] Instalando Homebrew...${NC}"
su - openclaw -c '
    export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo "eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"" >> ~/.bashrc
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    echo "  → $(brew --version | head -1)"
'
echo -e "${GREEN}[✔] Homebrew instalado${NC}"

# ── Instalar Node.js 22 ──────────────────────────────────────
echo ""
echo -e "${CYAN}[2/4] Instalando Node.js 22...${NC}"
su - openclaw -c '
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    brew install node@22
    brew link node@22 --overwrite --force 2>/dev/null || true
    echo "  → Node: $(node --version)"
    echo "  → npm:  $(npm --version)"
'
echo -e "${GREEN}[✔] Node.js instalado${NC}"

# ── Instalar OpenClaw ─────────────────────────────────────────
echo ""
echo -e "${CYAN}[3/4] Instalando OpenClaw...${NC}"
su - openclaw -c '
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    npm install -g openclaw@latest
    echo "  → OpenClaw $(openclaw --version 2>/dev/null || echo "instalado")"
'
echo -e "${GREEN}[✔] OpenClaw instalado${NC}"

# ── Instalar Docker (opcional, para sandbox) ──────────────────
echo ""
echo -e "${CYAN}[4/4] Instalando Docker (para sandboxing)...${NC}"
curl -fsSL https://get.docker.com | sh 2>/dev/null || apt-get install -y docker.io 2>/dev/null || true
usermod -aG docker openclaw 2>/dev/null || true
echo -e "${GREEN}[✔] Docker listo${NC}"

# ── Resumen final ─────────────────────────────────────────────
CT_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  🦞 Todo instalado correctamente${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "  IP del contenedor: ${CYAN}${CT_IP}${NC}"
echo ""
echo -e "${YELLOW}  Ahora ejecuta:${NC}"
echo ""
echo -e "    ${CYAN}su - openclaw${NC}"
echo -e "    ${CYAN}openclaw onboard --install-daemon${NC}"
echo ""
echo -e "  En el wizard selecciona tu API (Anthropic/OpenAI)"
echo -e "  y el canal de mensajería (Telegram/WhatsApp/etc)."
echo ""
echo -e "${RED}  ⚠ NO expongas puerto 18789 a internet${NC}"
echo ""
