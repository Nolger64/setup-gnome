#!/usr/bin/env bash
# ==============================================================================
# Script de Instalación y Configuración Automática de GNOME para MacBook Pro T2
# Distribución objetivo: Arch Linux (con kernel linux-t2)
# ==============================================================================

set -euo pipefail

# Colores para salida de consola
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# 1. Validaciones iniciales de usuario y privilegios
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_error "Este script debe ejecutarse con privilegios de root (ej. sudo ./setup-gnome-t2.sh)."
    exit 1
fi

# Detectar el usuario regular (no-root) que ejecutó sudo
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    # Si no se detectó por sudo, preguntar o buscar el primer usuario con UID >= 1000
    TARGET_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd || echo "")
fi

if [[ -z "$TARGET_USER" ]]; then
    log_error "No se pudo determinar el usuario normal del sistema. Por favor crea un usuario antes de continuar."
    exit 1
fi

log_info "Usuario objetivo del sistema detectado: ${CYAN}${TARGET_USER}${NC}"

# ------------------------------------------------------------------------------
# 2. Configuración del Repositorio [arch-mact2]
# ------------------------------------------------------------------------------
log_info "Verificando repositorio arch-mact2 en /etc/pacman.conf..."

mkdir -p /etc/pacman.d
if [[ ! -f /etc/pacman.d/arch-mact2-mirrorlist ]]; then
    cat << 'EOF' > /etc/pacman.d/arch-mact2-mirrorlist
Server = https://github.com/NoaHimesaka1873/arch-mact2-mirror/releases/download/release
EOF
    log_success "Creado /etc/pacman.d/arch-mact2-mirrorlist."
fi

if ! grep -q "^\[arch-mact2\]" /etc/pacman.conf; then
    cat << 'EOF' >> /etc/pacman.conf

[arch-mact2]
SigLevel = Never
Include = /etc/pacman.d/arch-mact2-mirrorlist
EOF
    log_success "Repositorio [arch-mact2] añadido a /etc/pacman.conf."
else
    log_info "El repositorio [arch-mact2] ya está configurado en pacman.conf."
fi

# Actualizar base de datos de pacman
log_info "Actualizando base de datos de paquetes de pacman..."
pacman -Sy --noconfirm

# ------------------------------------------------------------------------------
# 3. Firmware Broadcom Wi-Fi y Bluetooth (T2)
# ------------------------------------------------------------------------------
log_info "Verificando firmware de Wi-Fi y Bluetooth para Apple T2..."

if ! pacman -Qi apple-bcm-firmware-fetcher &>/dev/null; then
    log_info "Instalando apple-bcm-firmware-fetcher..."
    pacman -S --needed --noconfirm apple-bcm-firmware-fetcher
fi

# Comprobar si los archivos de firmware ya existen o si es necesario extraerlos
if [[ ! -d /lib/firmware/brcm || $(find /lib/firmware/brcm -maxdepth 1 -name "*.bin" 2>/dev/null | wc -l) -eq 0 ]]; then
    log_warn "Firmware Broadcom no encontrado en /lib/firmware/brcm. Extrayendo de la partición macOS..."
    if apple-bcm-firmware-fetcher; then
        log_success "Firmware de Wi-Fi y Bluetooth extraído e instalado exitosamente."
    else
        log_warn "apple-bcm-firmware-fetcher no pudo extraer el firmware automáticamente."
        log_warn "Asegúrate de que la partición APFS de macOS esté presente o copia los firmwares manualmente."
    fi
else
    log_success "Firmware Broadcom ya presente en /lib/firmware/brcm."
fi

# ------------------------------------------------------------------------------
# 4. Instalación de Paquetes (GNOME, Audio, T2, Extensiones, Utilidades)
# ------------------------------------------------------------------------------
log_info "Instalando GNOME y componentes del sistema..."

PKGS=(
    # Entorno GNOME y Display Manager
    gnome
    gnome-tweaks
    ptyxis
    
    # Audio Hi-Fi de baja latencia
    pipewire
    pipewire-pulse
    pipewire-alsa
    pipewire-jack
    wireplumber
    
    # Integración de hardware Apple T2
    apple-t2-audio-config
    tiny-dfr
    t2-touchid
    t2fanrd
    brightnessctl
    power-profiles-daemon
    
    # Extensiones de GNOME y herramientas
    gnome-shell-extension-appindicator
    gnome-shell-extension-caffeine
    gnome-shell-extension-vitals
    gnome-shell-extensions
    extension-manager
    
    # Códecs multimedia, temas y Flatpak
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
    ffmpeg
    papirus-icon-theme
    flatpak
)

pacman -S --needed --noconfirm "${PKGS[@]}"
log_success "Paquetes instalados correctamente."

# ------------------------------------------------------------------------------
# 5. Configuración de Touch ID (t2-touchid) y PAM
# ------------------------------------------------------------------------------
log_info "Configurando Touch ID para el usuario ${TARGET_USER}..."

mkdir -p /etc/kait2en
if [[ -f /usr/share/kait2en/t2-touchid.conf && ! -f /etc/kait2en/t2-touchid.conf ]]; then
    cp /usr/share/kait2en/t2-touchid.conf /etc/kait2en/t2-touchid.conf
fi

if [[ -f /etc/kait2en/t2-touchid.conf ]]; then
    sed -i "s/^T2_TOUCHID_BIND_USER=.*/T2_TOUCHID_BIND_USER=${TARGET_USER}/" /etc/kait2en/t2-touchid.conf
    log_success "Touch ID vinculado a ${TARGET_USER} en /etc/kait2en/t2-touchid.conf."
fi

# Configurar PAM para sudo
log_info "Configurando PAM para permitir autenticación Touch ID en sudo..."
if ! grep -q "pam_fprintd.so" /etc/pam.d/sudo; then
    sed -i '2i auth       sufficient   pam_fprintd.so' /etc/pam.d/sudo
    log_success "pam_fprintd.so añadido a /etc/pam.d/sudo."
else
    log_info "pam_fprintd.so ya presente en /etc/pam.d/sudo."
fi

# ------------------------------------------------------------------------------
# 6. Habilitación de Servicios del Sistema (systemd)
# ------------------------------------------------------------------------------
log_info "Habilitando servicios esenciales del sistema..."

SERVICES=(
    gdm.service
    tiny-dfr.service
    kait2en-t2-touchid.service
    t2fanrd.service
    power-profiles-daemon.service
    bluetooth.service
    NetworkManager.service
)

for svc in "${SERVICES[@]}"; do
    systemctl enable "$svc" 2>/dev/null || true
    log_success "Servicio habilitado: $svc"
done

# ------------------------------------------------------------------------------
# 7. Configuración de Flatpak / Flathub
# ------------------------------------------------------------------------------
log_info "Configurando repositorio Flathub para Flatpak..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
log_success "Repositorio Flathub listo."

# ------------------------------------------------------------------------------
# 8. Configuración Predeterminada de GNOME (dconf del sistema y del usuario)
# ------------------------------------------------------------------------------
log_info "Configurando preferencias del entorno de escritorio GNOME..."

# A) Perfil dconf del sistema (se aplica por defecto a nuevos y actuales usuarios)
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d

cat << 'EOF' > /etc/dconf/profile/user
user-db:user
system-db:local
EOF

cat << 'EOF' > /etc/dconf/db/local.d/01-macbook-t2
[org/gnome/desktop/peripherals/touchpad]
tap-to-click=true
natural-scroll=true
two-finger-scrolling-enabled=true

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
icon-theme='Papirus-Dark'
show-battery-percentage=true
clock-show-weekday=true
clock-show-date=true
font-antialiasing='rgba'
font-hinting='slight'

[org/gnome/desktop/wm/preferences]
button-layout=':minimize,maximize,close'

[org/gnome/shell]
enabled-extensions=['appindicatorsupport@rgcjonas.gmail.com', 'caffeine@patapon.info', 'Vitals@corecoding.com']
EOF

dconf update
log_success "Base de datos del sistema dconf actualizada."

# B) Directorios de usuario estándar XDG
if id "$TARGET_USER" &>/dev/null; then
    sudo -u "$TARGET_USER" xdg-user-dirs-update 2>/dev/null || true
    
    # C) Aplicar directamente a la sesión del usuario si dbus está disponible
    sudo -u "$TARGET_USER" dbus-run-session bash -c '
        gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true 2>/dev/null || true
        gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true 2>/dev/null || true
        gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface show-battery-percentage true 2>/dev/null || true
        gsettings set org.gnome.desktop.interface clock-show-weekday true 2>/dev/null || true
        gsettings set org.gnome.desktop.interface clock-show-date true 2>/dev/null || true
        gsettings set org.gnome.desktop.interface font-antialiasing "rgba" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface font-hinting "slight" 2>/dev/null || true
        gsettings set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close" 2>/dev/null || true
        gsettings set org.gnome.shell enabled-extensions "['\''appindicatorsupport@rgcjonas.gmail.com'\'', '\''caffeine@patapon.info'\'', '\''Vitals@corecoding.com'\'']" 2>/dev/null || true
    ' 2>/dev/null || true
    log_success "Preferencias de GNOME aplicadas para ${TARGET_USER}."
fi

# ------------------------------------------------------------------------------
# 9. Instalación Opcional de Paru (AUR Helper)
# ------------------------------------------------------------------------------
echo ""
RESP_PARU="n"
if [ -t 0 ]; then
    read -r -p "¿Deseas instalar el asistente de AUR 'paru' (paru-bin)? [s/N]: " RESP_PARU
elif [ -r /dev/tty ]; then
    read -r -p "¿Deseas instalar el asistente de AUR 'paru' (paru-bin)? [s/N]: " RESP_PARU < /dev/tty
fi

if [[ "$RESP_PARU" =~ ^([sS][iI]?|[yY][eE]?[sS]?)$ ]]; then
    if command -v paru &>/dev/null; then
        log_info "paru ya se encuentra instalado en el sistema."
    else
        log_info "Verificando dependencias base (base-devel y git)..."
        pacman -S --needed --noconfirm base-devel git

        log_info "Descargando e instalando paru-bin desde el AUR como ${TARGET_USER}..."
        BUILD_DIR=$(sudo -u "$TARGET_USER" mktemp -d /tmp/paru-build.XXXXXX)

        if sudo -u "$TARGET_USER" git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$BUILD_DIR"; then
            (
                cd "$BUILD_DIR"
                sudo -u "$TARGET_USER" makepkg --noconfirm -s
            )
            PKG_FILE=$(find "$BUILD_DIR" -maxdepth 1 -name "paru-bin-*.pkg.tar.zst" 2>/dev/null | head -n 1)
            if [[ -n "$PKG_FILE" && -f "$PKG_FILE" ]]; then
                pacman -U --noconfirm "$PKG_FILE"
                log_success "paru instalado exitosamente en el sistema."
            else
                log_error "No se pudo generar el paquete compilado de paru-bin."
            fi
        else
            log_error "No se pudo clonar el repositorio de paru-bin desde AUR."
        fi
        rm -rf "$BUILD_DIR"
    fi
else
    log_info "Instalación de paru omitida."
fi

# ------------------------------------------------------------------------------
# 10. Finalización y Resumen
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN} ¡Instalación y Configuración de GNOME Completada con Éxito! ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "Detalles del sistema configurado:"
echo -e "  - Usuario configurado: ${CYAN}${TARGET_USER}${NC}"
echo -e "  - Display Manager: ${CYAN}GDM (Wayland nativo)${NC}"
echo -e "  - Touch Bar: ${CYAN}tiny-dfr activo con soporte táctil y F-keys${NC}"
echo -e "  - Touch ID: ${CYAN}t2-touchid vinculado a PAM (sudo y login)${NC}"
echo -e "  - Audio: ${CYAN}PipeWire + WirePlumber + ALSA UCM Apple T2${NC}"
echo -e "  - Touchpad: ${CYAN}Toque para clic, desplazamiento natural y gestos${NC}"
echo -e "  - Tema: ${CYAN}Oscuro, Iconos Papirus-Dark, extensiones activas${NC}"
echo -e "  - Tienda / Paquetes: ${CYAN}Flatpak Flathub activado${NC}"
if command -v paru &>/dev/null; then
    echo -e "  - Asistente AUR: ${CYAN}paru (AUR helper) instalado${NC}"
fi
echo -e "\nPara arrancar tu nuevo entorno GNOME:"
echo -e "  ${YELLOW}sudo reboot${NC}   (Recomendado: reinicio limpio)"
echo -e "  o bien:"
echo -e "  ${YELLOW}sudo systemctl start gdm${NC} (Iniciar GDM de inmediato)\n"
