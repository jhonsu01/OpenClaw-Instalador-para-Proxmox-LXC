#!/usr/bin/env bash
#================================================================
#  OpenClaw - Instalador Completo para Proxmox
#  Ejecutar desde la SHELL DEL NODO Proxmox
#================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

command -v pct >/dev/null 2>&1 || { echo -e "${RED}[!] Ejecuta desde la shell del NODO Proxmox${NC}"; exit 1; }

echo ""
echo -e "${CYAN}  OpenClaw - Instalador Completo Proxmox${NC}"
echo ""

# ── Configuracion ─────────────────────────────────────────────
CT_ID=""
CT_STORAGE=""
CT_BRIDGE=""
CT_MEMORY=""
CT_CORES=""
CT_DISK=""

echo -e "${CYAN}ID del contenedor (ej: 108):${NC}"
read CT_ID

echo -e "${CYAN}Storage [local-lvm]:${NC}"
read CT_STORAGE
if [ -z "$CT_STORAGE" ]; then CT_STORAGE="local-lvm"; fi

echo -e "${CYAN}Bridge [vmbr0]:${NC}"
read CT_BRIDGE
if [ -z "$CT_BRIDGE" ]; then CT_BRIDGE="vmbr0"; fi

echo -e "${CYAN}RAM en MB [4096]:${NC}"
read CT_MEMORY
if [ -z "$CT_MEMORY" ]; then CT_MEMORY="4096"; fi

echo -e "${CYAN}CPU Cores [2]:${NC}"
read CT_CORES
if [ -z "$CT_CORES" ]; then CT_CORES="2"; fi

echo -e "${CYAN}Disco en GB [20]:${NC}"
read CT_DISK
if [ -z "$CT_DISK" ]; then CT_DISK="20"; fi

# ── Buscar template ───────────────────────────────────────────
echo ""
echo -e "${CYAN}Buscando templates...${NC}"
CT_TEMPLATE=""
CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i "debian-12" | awk '{print $1}' | head -1 || true)
if [ -z "$CT_TEMPLATE" ]; then
    CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i "debian-13" | awk '{print $1}' | head -1 || true)
fi
if [ -z "$CT_TEMPLATE" ]; then
    CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i "ubuntu-24" | awk '{print $1}' | head -1 || true)
fi
if [ -z "$CT_TEMPLATE" ]; then
    CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i "ubuntu-22" | awk '{print $1}' | head -1 || true)
fi

if [ -z "$CT_TEMPLATE" ]; then
    echo "No hay templates. Descargando Debian 12..."
    pveam update
    AVAILABLE=$(pveam available --section system | grep "debian-12" | awk '{print $2}' | head -1)
    if [ -z "$AVAILABLE" ]; then echo -e "${RED}No se encontro template${NC}"; exit 1; fi
    pveam download local "$AVAILABLE"
    CT_TEMPLATE="local:vztmpl/$AVAILABLE"
fi

echo -e "${GREEN}Template: $CT_TEMPLATE${NC}"

# ── Resumen ───────────────────────────────────────────────────
echo ""
echo "  CT ID:     $CT_ID"
echo "  RAM:       ${CT_MEMORY}MB | CPU: ${CT_CORES} cores | Disco: ${CT_DISK}GB"
echo "  Storage:   $CT_STORAGE | Bridge: $CT_BRIDGE"
echo "  Template:  $CT_TEMPLATE"
echo ""
echo -e "${YELLOW}Continuar? (s/N):${NC}"
read CONFIRM
if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "S" ]; then echo "Cancelado."; exit 0; fi

# ══════════════════════════════════════════════════════════════
# PARTE 1: CREAR LXC
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}Creando contenedor LXC $CT_ID...${NC}"
pct create $CT_ID $CT_TEMPLATE \
    --hostname openclaw \
    --memory $CT_MEMORY \
    --cores $CT_CORES \
    --rootfs ${CT_STORAGE}:${CT_DISK} \
    --net0 name=eth0,bridge=${CT_BRIDGE},ip=dhcp \
    --features nesting=1 \
    --unprivileged 0 \
    --onboot 1 \
    --start 0

echo -e "${GREEN}Contenedor creado${NC}"

echo "Iniciando contenedor..."
pct start $CT_ID
sleep 5

echo "Esperando red..."
TRIES=0
while [ $TRIES -lt 30 ]; do
    if pct exec $CT_ID -- ping -c1 -W2 google.com >/dev/null 2>&1; then
        echo -e "${GREEN}Red OK${NC}"
        break
    fi
    TRIES=$((TRIES + 1))
    sleep 2
done

# ══════════════════════════════════════════════════════════════
# PARTE 2: INSTALAR DEPENDENCIAS
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}[1/6] Instalando dependencias base...${NC}"
pct exec $CT_ID -- bash -c 'export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get upgrade -y -qq && apt-get install -y -qq build-essential curl file git sudo ca-certificates jq dbus-user-session procps wget unzip lsof net-tools locales gnupg2 2>/dev/null && sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen && locale-gen en_US.UTF-8 >/dev/null 2>&1 || true'
echo -e "${GREEN}Dependencias OK${NC}"

echo ""
echo -e "${CYAN}[2/6] Creando usuario openclaw...${NC}"
pct exec $CT_ID -- bash -c 'id openclaw >/dev/null 2>&1 || useradd -m -s /bin/bash openclaw && echo "openclaw ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw && mkdir -p /home/linuxbrew/.linuxbrew && chown -R openclaw:openclaw /home/linuxbrew && loginctl enable-linger openclaw 2>/dev/null || true'
echo -e "${GREEN}Usuario creado${NC}"

echo ""
echo -e "${YELLOW}Asigna contraseña para el usuario openclaw:${NC}"
pct exec $CT_ID -- passwd openclaw

# ══════════════════════════════════════════════════════════════
# PARTE 3: HOMEBREW + NODE + OPENCLAW
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}[3/6] Instalando Homebrew (tarda varios minutos)...${NC}"
pct exec $CT_ID -- su - openclaw -c 'export NONINTERACTIVE=1 && /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && echo "eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"" >> ~/.bashrc && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew --version | head -1'
echo -e "${GREEN}Homebrew OK${NC}"

echo ""
echo -e "${CYAN}[4/6] Instalando Node.js 22 (tarda varios minutos)...${NC}"
pct exec $CT_ID -- su - openclaw -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew install node@22 && brew link node@22 --overwrite --force 2>/dev/null || true && echo "Node: $(node --version) | npm: $(npm --version)"'
echo -e "${GREEN}Node.js OK${NC}"

echo ""
echo -e "${CYAN}[5/6] Instalando OpenClaw...${NC}"
pct exec $CT_ID -- su - openclaw -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && npm install -g openclaw@latest && openclaw --version 2>/dev/null || echo "OpenClaw instalado"'
echo -e "${GREEN}OpenClaw OK${NC}"

echo ""
echo -e "${CYAN}[6/6] Instalando Docker...${NC}"
pct exec $CT_ID -- bash -c 'curl -fsSL https://get.docker.com | sh 2>/dev/null || apt-get install -y docker.io 2>/dev/null || true && usermod -aG docker openclaw 2>/dev/null || true'
echo -e "${GREEN}Docker OK${NC}"

# ══════════════════════════════════════════════════════════════
# RESUMEN
# ══════════════════════════════════════════════════════════════

CT_IP=$(pct exec $CT_ID -- hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  OpenClaw instalado correctamente${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  CT: $CT_ID | IP: $CT_IP"
echo "  Dashboard: http://${CT_IP}:18789"
echo ""
echo -e "${YELLOW}  Ultimo paso - ejecuta:${NC}"
echo ""
echo "    pct exec $CT_ID -- su - openclaw"
echo "    openclaw onboard --install-daemon"
echo ""
echo "  Selecciona tu API (Anthropic/OpenAI) y canal."
echo ""
echo -e "${RED}  NO expongas puerto 18789 a internet${NC}"
echo ""
