#!/usr/bin/env bash
#================================================================
#  OpenClaw - Instalador para Proxmox LXC
#  Solo Gateway (sin LLM local) - Conectar via API
#  Ejecutar desde la SHELL del nodo Proxmox
#================================================================

set -euo pipefail

# ── Colores ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# ── Verificar que estamos en el nodo Proxmox ──────────────────
if ! command -v pct &>/dev/null; then
    err "Este script debe ejecutarse desde la shell del NODO Proxmox"
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     🦞 OpenClaw - Instalador Proxmox LXC 🦞     ║${NC}"
echo -e "${CYAN}║        Solo Gateway - Sin LLM local              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ── Configuración ─────────────────────────────────────────────
CT_ID="${1:-}"
CT_STORAGE="${2:-local-lvm}"
CT_BRIDGE="${3:-vmbr0}"

CT_HOSTNAME="openclaw"
CT_MEMORY=4096
CT_CORES=2
CT_DISK=20
CT_TEMPLATE=""

# Pedir CT_ID si no se pasó como argumento
if [[ -z "$CT_ID" ]]; then
    NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "201")
    read -rp "$(echo -e "${CYAN}[→]${NC} ID del contenedor [$NEXT_ID]: ")" CT_ID
    CT_ID="${CT_ID:-$NEXT_ID}"
fi

# Validar que el ID no exista
if pct status "$CT_ID" &>/dev/null; then
    err "El contenedor CT $CT_ID ya existe. Usa otro ID."
fi

info "Storage para rootfs [$CT_STORAGE]: "
read -rp "" input_storage
CT_STORAGE="${input_storage:-$CT_STORAGE}"

info "Bridge de red [$CT_BRIDGE]: "
read -rp "" input_bridge
CT_BRIDGE="${input_bridge:-$CT_BRIDGE}"

# ── Buscar template disponible ────────────────────────────────
info "Buscando templates disponibles..."

# Preferencia: Debian 13 > Debian 12 > Ubuntu 24.04 > Ubuntu 22.04
for pattern in "debian-13" "debian-12" "ubuntu-24" "ubuntu-22"; do
    CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i "$pattern" | awk '{print $1}' | head -1 || true)
    [[ -n "$CT_TEMPLATE" ]] && break
done

if [[ -z "$CT_TEMPLATE" ]]; then
    warn "No hay templates descargados. Descargando Debian 12..."
    pveam update
    # Buscar la versión exacta disponible
    AVAILABLE=$(pveam available --section system | grep "debian-12" | awk '{print $2}' | head -1)
    if [[ -n "$AVAILABLE" ]]; then
        pveam download local "$AVAILABLE"
        CT_TEMPLATE="local:vztmpl/$AVAILABLE"
    else
        err "No se pudo descargar ningún template. Descarga uno manualmente desde el GUI."
    fi
fi

log "Template: $CT_TEMPLATE"

# ── Resumen antes de crear ────────────────────────────────────
echo ""
echo -e "${CYAN}── Resumen de configuración ──${NC}"
echo "  CT ID:      $CT_ID"
echo "  Hostname:   $CT_HOSTNAME"
echo "  RAM:        ${CT_MEMORY}MB"
echo "  CPU Cores:  $CT_CORES"
echo "  Disco:      ${CT_DISK}GB"
echo "  Storage:    $CT_STORAGE"
echo "  Bridge:     $CT_BRIDGE"
echo "  Template:   $CT_TEMPLATE"
echo ""

read -rp "$(echo -e "${YELLOW}¿Continuar? (s/N): ${NC}")" confirm
[[ "$confirm" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# ── Crear LXC ─────────────────────────────────────────────────
info "Creando contenedor LXC $CT_ID..."

pct create "$CT_ID" "$CT_TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --memory "$CT_MEMORY" \
    --cores "$CT_CORES" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
    --features nesting=1 \
    --unprivileged 0 \
    --onboot 1 \
    --start 0

log "Contenedor $CT_ID creado"

# ── Iniciar contenedor ────────────────────────────────────────
info "Iniciando contenedor..."
pct start "$CT_ID"
sleep 5

# Esperar a que tenga red
info "Esperando conectividad de red..."
for i in $(seq 1 30); do
    if pct exec "$CT_ID" -- ping -c1 -W2 debian.org &>/dev/null 2>&1 || \
       pct exec "$CT_ID" -- ping -c1 -W2 google.com &>/dev/null 2>&1; then
        log "Red disponible"
        break
    fi
    [[ $i -eq 30 ]] && warn "Timeout esperando red, continuando de todas formas..."
    sleep 2
done

# ── Instalar todo DENTRO del LXC ─────────────────────────────
info "Instalando dependencias y OpenClaw dentro del LXC..."

pct exec "$CT_ID" -- bash -c 'cat > /tmp/setup-openclaw.sh << '\''INNERSCRIPT'\''
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Actualizando sistema..."
apt-get update -qq
apt-get upgrade -y -qq

echo "[2/8] Instalando dependencias base..."
apt-get install -y -qq \
    build-essential curl file git sudo ca-certificates \
    jq dbus-user-session procps locales wget gnupg2 \
    unzip lsof net-tools 2>/dev/null

# Configurar locale
sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
export LANG=en_US.UTF-8

echo "[3/8] Creando usuario openclaw..."
if ! id openclaw &>/dev/null; then
    useradd -m -s /bin/bash openclaw
    echo "openclaw ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw
fi

# Crear directorio para linuxbrew
mkdir -p /home/linuxbrew/.linuxbrew
chown -R openclaw:openclaw /home/linuxbrew

# Habilitar lingering para servicios de usuario
loginctl enable-linger openclaw 2>/dev/null || true

# Asegurar que systemd user funcione
systemctl start "user@$(id -u openclaw).service" 2>/dev/null || true

echo "[4/8] Instalando Homebrew como usuario openclaw..."
su - openclaw -c '
    export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Configurar PATH
    echo "eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"" >> ~/.bashrc
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    
    echo "  → Brew instalado: $(brew --version | head -1)"
'

echo "[5/8] Instalando Node.js 22 via Homebrew..."
su - openclaw -c '
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    brew install node@22 2>/dev/null
    
    # Asegurar que node esté en el PATH
    brew link node@22 --overwrite --force 2>/dev/null || true
    
    echo "  → Node: $(node --version)"
    echo "  → npm:  $(npm --version)"
'

echo "[6/8] Instalando OpenClaw..."
su - openclaw -c '
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    npm install -g openclaw@latest 2>&1 | tail -3
    
    # Verificar instalación
    if command -v openclaw &>/dev/null; then
        echo "  → OpenClaw $(openclaw --version 2>/dev/null || echo "instalado")"
    else
        # Reintentar con path explícito
        export PATH="$HOME/.npm-global/bin:$(npm config get prefix)/bin:$PATH"
        echo "  → OpenClaw instalado (verificar con: openclaw --version)"
    fi
'

echo "[7/8] Configurando servicio systemd..."
su - openclaw -c '
    mkdir -p ~/.config/systemd/user

    cat > ~/.config/systemd/user/openclaw.service << EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.npm-global/bin/openclaw gateway 2>/dev/null || /home/linuxbrew/.linuxbrew/bin/openclaw gateway
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

echo "[8/8] Instalando Docker (para sandboxing de skills)..."
# Instalar Docker para que OpenClaw pueda usar sandbox
curl -fsSL https://get.docker.com | sh -s -- 2>/dev/null || apt-get install -y docker.io 2>/dev/null || true
usermod -aG docker openclaw 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════"
echo "  🦞 OpenClaw instalado correctamente"
echo "═══════════════════════════════════════════════"

INNERSCRIPT
chmod +x /tmp/setup-openclaw.sh
/tmp/setup-openclaw.sh'

# ── Obtener IP del contenedor ─────────────────────────────────
sleep 2
CT_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "???")

# ── Mensaje final ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         🦞 OpenClaw Instalado Exitosamente 🦞            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Contenedor:${NC}  CT $CT_ID"
echo -e "  ${CYAN}IP:${NC}          $CT_IP"
echo -e "  ${CYAN}Dashboard:${NC}   http://${CT_IP}:18789"
echo ""
echo -e "${YELLOW}── Siguientes pasos ──${NC}"
echo ""
echo "  1. Entrar al contenedor:"
echo -e "     ${CYAN}pct exec $CT_ID -- su - openclaw${NC}"
echo ""
echo "  2. Ejecutar el wizard de configuración:"
echo -e "     ${CYAN}openclaw onboard --install-daemon${NC}"
echo ""
echo "     → Seleccionar proveedor API (Anthropic/OpenAI)"
echo "     → Ingresar tu API key"
echo "     → Elegir canal (Telegram/WhatsApp/etc)"
echo ""
echo "  3. Verificar estado:"
echo -e "     ${CYAN}openclaw status${NC}"
echo -e "     ${CYAN}openclaw doctor${NC}"
echo ""
echo "  4. Si quieres conectar Ollama remoto después:"
echo -e "     Editar ${CYAN}~/.openclaw/openclaw.json${NC}"
echo '     "providers": { "ollama": { "baseUrl": "http://IP:11434/v1" } }'
echo ""
echo -e "${RED}⚠  SEGURIDAD: NO expongas puerto 18789 a internet${NC}"
echo -e "${RED}   Usa Tailscale o SSH tunnel para acceso remoto${NC}"
echo ""
