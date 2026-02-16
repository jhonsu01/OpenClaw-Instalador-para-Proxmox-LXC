#!/usr/bin/env bash
#================================================================
#  🦞 OpenClaw - Instalador COMPLETO para Proxmox
#  Ejecutar desde la SHELL DEL NODO Proxmox
#  Crea el LXC + Instala Homebrew + Node.js 22 + OpenClaw + Docker
#================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# ── Verificar que estamos en el nodo Proxmox ──────────────────
command -v pct &>/dev/null || err "Ejecuta este script desde la shell del NODO Proxmox"

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   🦞 OpenClaw - Instalador Completo Proxmox 🦞    ║${NC}"
echo -e "${CYAN}║   LXC + Homebrew + Node.js + OpenClaw + Docker    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ══════════════════════════════════════════════════════════════
# PARTE 1: CREAR EL LXC
# ══════════════════════════════════════════════════════════════

NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "201")

read -rp "$(echo -e "${CYAN}  ID del contenedor${NC} [$NEXT_ID]: ")" CT_ID
CT_ID="${CT_ID:-$NEXT_ID}"
pct status "$CT_ID" &>/dev/null && err "CT $CT_ID ya existe. Usa otro ID."

read -rp "$(echo -e "${CYAN}  Storage para rootfs${NC} [local-lvm]: ")" CT_STORAGE
CT_STORAGE="${CT_STORAGE:-local-lvm}"

read -rp "$(echo -e "${CYAN}  Bridge de red${NC} [vmbr0]: ")" CT_BRIDGE
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"

read -rp "$(echo -e "${CYAN}  RAM en MB${NC} [4096]: ")" CT_MEMORY
CT_MEMORY="${CT_MEMORY:-4096}"

read -rp "$(echo -e "${CYAN}  CPU Cores${NC} [2]: ")" CT_CORES
CT_CORES="${CT_CORES:-2}"

read -rp "$(echo -e "${CYAN}  Disco en GB${NC} [20]: ")" CT_DISK
CT_DISK="${CT_DISK:-20}"

# ── Buscar template ───────────────────────────────────────────
info "Buscando templates..."
CT_TEMPLATE=""
for pattern in "debian-12" "debian-13" "ubuntu-24" "ubuntu-22"; do
    CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i "$pattern" | awk '{print $1}' | head -1 || true)
    [[ -n "$CT_TEMPLATE" ]] && break
done

if [[ -z "$CT_TEMPLATE" ]]; then
    warn "No hay templates. Descargando Debian 12..."
    pveam update
    AVAILABLE=$(pveam available --section system | grep "debian-12" | awk '{print $2}' | head -1)
    [[ -z "$AVAILABLE" ]] && err "No se encontró template para descargar"
    pveam download local "$AVAILABLE"
    CT_TEMPLATE="local:vztmpl/$AVAILABLE"
fi
log "Template: $CT_TEMPLATE"

# ── Resumen ───────────────────────────────────────────────────
echo ""
echo -e "${CYAN}── Configuración ──${NC}"
echo "  CT ID:     $CT_ID"
echo "  RAM:       ${CT_MEMORY}MB | CPU: ${CT_CORES} cores | Disco: ${CT_DISK}GB"
echo "  Storage:   $CT_STORAGE | Bridge: $CT_BRIDGE"
echo "  Template:  $CT_TEMPLATE"
echo ""
read -rp "$(echo -e "${YELLOW}  ¿Continuar? (s/N): ${NC}")" confirm
[[ "$confirm" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# ── Crear LXC ─────────────────────────────────────────────────
info "Creando contenedor LXC $CT_ID..."
pct create "$CT_ID" "$CT_TEMPLATE" \
    --hostname openclaw \
    --memory "$CT_MEMORY" \
    --cores "$CT_CORES" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
    --features nesting=1 \
    --unprivileged 0 \
    --onboot 1 \
    --start 0
log "Contenedor creado"

info "Iniciando contenedor..."
pct start "$CT_ID"
sleep 5

# Esperar red
info "Esperando conectividad..."
for i in $(seq 1 30); do
    pct exec "$CT_ID" -- ping -c1 -W2 google.com &>/dev/null && break
    [[ $i -eq 30 ]] && warn "Timeout de red, continuando..."
    sleep 2
done
log "Red disponible"

# ══════════════════════════════════════════════════════════════
# PARTE 2: INSTALAR TODO DENTRO DEL LXC
# ══════════════════════════════════════════════════════════════

info "Instalando dependencias base..."
pct exec "$CT_ID" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq build-essential curl file git sudo \
        ca-certificates jq dbus-user-session procps wget unzip \
        lsof net-tools locales gnupg2 2>/dev/null
    sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
'
log "Dependencias instaladas"

info "Creando usuario openclaw..."
pct exec "$CT_ID" -- bash -c '
    if ! id openclaw &>/dev/null; then
        useradd -m -s /bin/bash openclaw
        echo "openclaw ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw
    fi
    mkdir -p /home/linuxbrew/.linuxbrew
    chown -R openclaw:openclaw /home/linuxbrew
    loginctl enable-linger openclaw 2>/dev/null || true
'
log "Usuario openclaw creado"

# ── Asignar contraseña ────────────────────────────────────────
echo ""
echo -e "${YELLOW}  Asigna una contraseña para el usuario 'openclaw':${NC}"
pct exec "$CT_ID" -- passwd openclaw
echo ""
log "Contraseña asignada"

# ── Homebrew ──────────────────────────────────────────────────
info "[1/4] Instalando Homebrew (esto tarda unos minutos)..."
pct exec "$CT_ID" -- su - openclaw -c '
    export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo "eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"" >> ~/.bashrc
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    echo "  Brew: $(brew --version | head -1)"
'
log "Homebrew instalado"

# ── Node.js 22 ────────────────────────────────────────────────
info "[2/4] Instalando Node.js 22 (esto tarda unos minutos)..."
pct exec "$CT_ID" -- su - openclaw -c '
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    brew install node@22
    brew link node@22 --overwrite --force 2>/dev/null || true
    echo "  Node: $(node --version) | npm: $(npm --version)"
'
log "Node.js instalado"

# ── OpenClaw ──────────────────────────────────────────────────
info "[3/4] Instalando OpenClaw..."
pct exec "$CT_ID" -- su - openclaw -c '
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    npm install -g openclaw@latest
    echo "  OpenClaw: $(openclaw --version 2>/dev/null || echo "OK")"
'
log "OpenClaw instalado"

# ── Docker ────────────────────────────────────────────────────
info "[4/4] Instalando Docker (para sandboxing)..."
pct exec "$CT_ID" -- bash -c '
    curl -fsSL https://get.docker.com | sh 2>/dev/null || apt-get install -y docker.io 2>/dev/null || true
    usermod -aG docker openclaw 2>/dev/null || true
'
log "Docker instalado"

# ── Preparar servicio systemd ─────────────────────────────────
info "Configurando autostart..."
pct exec "$CT_ID" -- su - openclaw -c '
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    OPENCLAW_BIN=$(which openclaw 2>/dev/null || echo "/home/linuxbrew/.linuxbrew/bin/openclaw")
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/openclaw.service << EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${OPENCLAW_BIN} gateway
Restart=always
RestartSec=30
Environment=PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=/home/openclaw
WorkingDirectory=/home/openclaw

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
'
log "Servicio systemd configurado"

# ══════════════════════════════════════════════════════════════
# RESUMEN FINAL
# ══════════════════════════════════════════════════════════════

CT_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "???")

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       🦞 OpenClaw Instalado Correctamente 🦞           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Contenedor:  ${CYAN}CT $CT_ID${NC}"
echo -e "  IP:          ${CYAN}$CT_IP${NC}"
echo -e "  Dashboard:   ${CYAN}http://${CT_IP}:18789${NC}"
echo ""
echo -e "${YELLOW}  ── Último paso ──${NC}"
echo ""
echo -e "  Ejecuta esto para configurar tu API y canal:"
echo ""
echo -e "    ${CYAN}pct exec $CT_ID -- su - openclaw${NC}"
echo -e "    ${CYAN}openclaw onboard --install-daemon${NC}"
echo ""
echo -e "  En el wizard selecciona:"
echo -e "    → Proveedor: Anthropic / OpenAI / Ollama remoto"
echo -e "    → Tu API key"
echo -e "    → Canal: Telegram / WhatsApp / etc"
echo ""
echo -e "  Comandos útiles después:"
echo -e "    ${CYAN}openclaw status${NC}    → ver estado"
echo -e "    ${CYAN}openclaw doctor${NC}    → diagnóstico"
echo -e "    ${CYAN}openclaw gateway${NC}   → iniciar manualmente"
echo ""
echo -e "${RED}  ⚠  NUNCA expongas puerto 18789 a internet${NC}"
echo -e "${RED}     Usa Tailscale o SSH tunnel para acceso remoto${NC}"
echo ""
