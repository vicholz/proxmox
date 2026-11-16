#!/usr/bin/env bash
# Proxmox Sunshine + NVIDIA GPU Setup Script
# Run on the Proxmox host. Interactive setup for NVIDIA drivers, LXC CT, and Sunshine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/sunshine-setup-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
prompt() { echo -e "${BLUE}[?]${NC} $*"; }

# Latest NVIDIA driver versions (update periodically)
declare -A NVIDIA_DRIVERS=(
    ["1"]="620.70.06"
    ["2"]="595.112.07"
    ["3"]="580.196.07"
    ["4"]="615.71.10"
    ["5"]="615.78.08"
)

declare -A RESOLUTIONS=(
    ["1"]="1920x1080"
    ["2"]="2560x1440"
    ["3"]="3840x2160"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root on the Proxmox host."
}

select_from_list() {
    local -n arr=$1
    local title=$2
    echo ""
    prompt "$title"
    for key in $(echo "${!arr[@]}" | tr ' ' '\n' | sort -n); do
        echo "  $key) ${arr[$key]}"
    done
    local choice
    read -rp "Select (number): " choice
    [[ -n "${arr[$choice]:-}" ]] || error "Invalid selection."
    echo "${arr[$choice]}"
}

confirm() {
    local msg=$1
    read -rp "$msg [y/N]: " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# 1. Install NVIDIA drivers on host
# ---------------------------------------------------------------------------
install_host_drivers() {
    log "=== Step 1: Install NVIDIA drivers on host ==="
    local version
    version=$(select_from_list NVIDIA_DRIVERS "Select NVIDIA driver version for the host:")
    log "Selected driver: $version"

    local url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
    local dest="/tmp/NVIDIA-Linux-x86_64-${version}.run"

    log "Downloading $url ..."
    wget -q --show-progress -O "$dest" "$url" || error "Download failed. Check the version or network."
    chmod +x "$dest"

    log "Installing build dependencies..."
    apt-get update -qq
    apt-get install -y build-essential "pve-headers-$(uname -r)" dkms 2>/dev/null || \
        apt-get install -y build-essential dkms

    # Blacklist nouveau
    if [[ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
        echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf
        update-initramfs -u
    fi

    log "Running NVIDIA installer (no X config)..."
    "$dest" --dkms --no-x-check --no-nouveau-check --silent || warn "Installer returned non-zero; check output."

    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi
        log "Host NVIDIA driver installed successfully."
    else
        warn "nvidia-smi not found. A reboot may be required."
    fi
}

# ---------------------------------------------------------------------------
# 2. Select or create CT
# ---------------------------------------------------------------------------
select_or_create_ct() {
    log "=== Step 2: Select or create LXC container ==="
    local configs
    mapfile -t configs < <(ls /etc/pve/lxc/*.conf 2>/dev/null | xargs -I{} basename {} .conf)

    if [[ ${#configs[@]} -eq 0 ]]; then
        log "No existing containers found."
        create_new_ct
        return
    fi

    echo ""
    prompt "Existing containers:"
    local i=1
    declare -A ct_map
    for ctid in "${configs[@]}"; do
        local name
        name=$(grep -E '^hostname:' "/etc/pve/lxc/${ctid}.conf" 2>/dev/null | awk '{print $2}' || echo "unknown")
        echo "  $i) CT $ctid ($name)"
        ct_map[$i]=$ctid
        ((i++))
    done
    echo "  $i) Create new container"

    local choice
    read -rp "Select: " choice
    if [[ "$choice" == "$i" ]]; then
        create_new_ct
    else
        CTID="${ct_map[$choice]}"
        [[ -n "$CTID" ]] || error "Invalid selection."
        log "Selected existing CT: $CTID"
        if ! confirm "Apply NVIDIA passthrough to CT $CTID?"; then
            error "Aborted."
        fi
    fi
}

create_new_ct() {
    log "Creating new LXC container..."
    # List available templates
    local templates
    mapfile -t templates < <(pveam list local 2>/dev/null | awk 'NR>1 {print $1}' | head -20)
    if [[ ${#templates[@]} -eq 0 ]]; then
        warn "No templates found. Download one with: pveam download local ubuntu-24.04-standard_*.tar.zst"
        read -rp "Enter template name (e.g. ubuntu-24.04-standard_24.04-2_amd64.tar.zst): " tmpl
    else
        echo "Available templates:"
        local j=1
        for t in "${templates[@]}"; do
            echo "  $j) $t"
            ((j++))
        done
        read -rp "Select template number: " tchoice
        tmpl="${templates[$((tchoice-1))]}"
    fi

    read -rp "CT ID (e.g. 100): " CTID
    read -rp "Hostname: " hostname
    read -rp "Root password: " -s rootpass
    echo
    read -rp "Memory (MB, default 4096): " mem
    mem=${mem:-4096}
    read -rp "Disk (GB, default 32): " disk
    disk=${disk:-32}

    pct create "$CTID" "local:vztmpl/${tmpl}" \
        --hostname "$hostname" \
        --password "$rootpass" \
        --memory "$mem" \
        --rootfs "local-lvm:${disk}" \
        --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
        --features "nesting=1,keyctl=1" \
        --unprivileged 1 \
        --ostype ubuntu

    log "Container $CTID created."
}

# ---------------------------------------------------------------------------
# 3. Apply NVIDIA device passthrough
# ---------------------------------------------------------------------------
apply_nvidia_passthrough() {
    log "=== Step 3: Apply NVIDIA device passthrough to CT $CTID ==="

    # Ensure devices exist
    nvidia-modprobe -c 0 -m 2>/dev/null || true
    modprobe nvidia-drm modeset=1 2>/dev/null || true

    # Clear old device entries
    sed -i '/^dev[0-9]:/d' "/etc/pve/lxc/${CTID}.conf" 2>/dev/null || true

    local dev_idx=0
    for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset /dev/uinput; do
        if [[ -e "$dev" ]]; then
            pct set "$CTID" --dev${dev_idx} "${dev},mode=0666"
            ((dev_idx++))
        fi
    done

    # DRI render node if present
    if [[ -e /dev/dri/renderD128 ]]; then
        pct set "$CTID" --dev${dev_idx} "/dev/dri/renderD128,mode=0666"
    fi

    # Add cgroup allows
    local conf="/etc/pve/lxc/${CTID}.conf"
    grep -q "lxc.cgroup2.devices.allow: c 195:\*" "$conf" || \
        echo "lxc.cgroup2.devices.allow: c 195:* rwm" >> "$conf"
    grep -q "lxc.cgroup2.devices.allow: c 507:\*" "$conf" || \
        echo "lxc.cgroup2.devices.allow: c 507:* rwm" >> "$conf"
    grep -q "lxc.cgroup2.devices.allow: c 510:\*" "$conf" || \
        echo "lxc.cgroup2.devices.allow: c 510:* rwm" >> "$conf"
    grep -q "lxc.cgroup2.devices.allow: c 13:\*" "$conf" || \
        echo "lxc.cgroup2.devices.allow: c 13:* rwm" >> "$conf"

    log "NVIDIA devices passed through. Restarting CT..."
    pct stop "$CTID" 2>/dev/null || true
    pct start "$CTID"
    sleep 3
}

# ---------------------------------------------------------------------------
# 4. Install NVIDIA userspace in CT (no kernel module)
# ---------------------------------------------------------------------------
install_ct_nvidia_userspace() {
    log "=== Step 4: Install NVIDIA userspace in CT (no kernel module) ==="
    local version
    version=$(select_from_list NVIDIA_DRIVERS "Select NVIDIA driver version for the CT (should match host):")

    local url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
    local dest="/tmp/NVIDIA-Linux-x86_64-${version}.run"

    # Download on host and push to CT
    if [[ ! -f "$dest" ]]; then
        wget -q --show-progress -O "$dest" "$url" || error "Download failed."
        chmod +x "$dest"
    fi

    pct push "$CTID" "$dest" /tmp/nvidia-driver.run
    pct exec "$CTID" -- bash -c '
        apt-get update -qq
        apt-get install -y wget
        /tmp/nvidia-driver.run --no-kernel-module --no-dkms --silent || true
        nvidia-smi || echo "nvidia-smi not available yet"
    '
    log "NVIDIA userspace installed in CT."
}

# ---------------------------------------------------------------------------
# 5. Create steamuser
# ---------------------------------------------------------------------------
create_steamuser() {
    log "=== Step 5: Create steamuser ==="
    pct exec "$CTID" -- bash -c '
        if ! id steamuser &>/dev/null; then
            adduser --disabled-password --gecos "" steamuser
            echo "steamuser:steamuser" | chpasswd
        fi
        usermod -aG video,render,input,audio steamuser 2>/dev/null || true
        # Allow steamuser to use GPU and input devices
        chmod 666 /dev/nvidia* /dev/dri/renderD* /dev/uinput 2>/dev/null || true
        # Ensure runtime dir exists
        mkdir -p /run/user/1000
        chown steamuser:steamuser /run/user/1000
    '
    log "steamuser created (password: steamuser — change it!)."
}

# ---------------------------------------------------------------------------
# 6. Install Sunshine
# ---------------------------------------------------------------------------
install_sunshine() {
    log "=== Step 6: Install Sunshine ==="
    pct exec "$CTID" -- bash -c '
        apt-get update -qq
        apt-get install -y wget curl xvfb

        # Download latest Sunshine .deb for Ubuntu
        SUNSHINE_URL=$(curl -sL https://api.github.com/repos/LizardByte/Sunshine/releases/latest | \
            grep -oP "browser_download_url.*ubuntu.*amd64\.deb" | head -1 | cut -d\" -f4)
        if [[ -z "$SUNSHINE_URL" ]]; then
            # Fallback
            SUNSHINE_URL="https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-ubuntu-24.04-amd64.deb"
        fi
        wget -q -O /tmp/sunshine.deb "$SUNSHINE_URL"
        apt-get install -y /tmp/sunshine.deb || dpkg -i /tmp/sunshine.deb || true
        apt-get -f install -y

        # Configure CSRF
        mkdir -p /home/steamuser/.config/sunshine
        cat > /home/steamuser/.config/sunshine/sunshine.conf << EOF
csrf_allowed_origins = *
EOF
        chown -R steamuser:steamuser /home/steamuser/.config
    '
    log "Sunshine installed."
}

# ---------------------------------------------------------------------------
# 7. Configure resolution / virtual display
# ---------------------------------------------------------------------------
configure_display() {
    log "=== Step 7: Configure virtual display resolution ==="
    local res
    res=$(select_from_list RESOLUTIONS "Select virtual display resolution:")
    log "Selected resolution: $res"
    RESOLUTION="$res"
    log "Virtual display will be $res."
}

# ---------------------------------------------------------------------------
# 8. Create Sunshine + Xvfb systemd services
# ---------------------------------------------------------------------------
setup_sunshine_service() {
    log "=== Step 8: Create Sunshine and Xvfb systemd services ==="
    local res="${RESOLUTION:-1920x1080}"

    pct exec "$CTID" -- bash -c "
        # Xvfb service
        cat > /etc/systemd/system/xvfb.service << EOF
[Unit]
Description=X Virtual Framebuffer
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 ${res}x24
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

        # Sunshine service
        cat > /etc/systemd/system/sunshine.service << EOF
[Unit]
Description=Sunshine Game Streaming Host
After=xvfb.service network.target
Requires=xvfb.service

[Service]
Type=simple
User=steamuser
Environment=DISPLAY=:99
Environment=HOME=/home/steamuser
ExecStart=/usr/bin/sunshine
Restart=on-failure
RestartSec=5
WorkingDirectory=/home/steamuser

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable xvfb sunshine
        systemctl start xvfb
        sleep 2
        systemctl start sunshine || true
        systemctl status sunshine --no-pager || true
    "
    log "Sunshine and Xvfb services created and enabled."
}

# ---------------------------------------------------------------------------
# 9. Install Steam 32-bit dependencies (optional)
# ---------------------------------------------------------------------------
install_steam_deps() {
    if confirm "Install Steam 32-bit dependencies in the CT?"; then
        log "=== Installing Steam 32-bit dependencies ==="
        pct exec "$CTID" -- bash -c '
            dpkg --add-architecture i386
            apt-get update -qq
            apt-get install -y \
                libegl1:i386 \
                libgbm1:i386 \
                libgl1-mesa-dri:i386 \
                libgl1:i386 \
                steam-installer \
                steam-libs-i386:i386 \
                xdg-desktop-portal \
                xdg-desktop-portal-gtk \
                || true
            apt-get -f install -y || true
        '
        log "Steam dependencies installed. Run Steam as steamuser with DISPLAY=:99."
    fi
}

# ---------------------------------------------------------------------------
# 10. Setup PulseAudio for streaming audio
# ---------------------------------------------------------------------------
setup_pulseaudio() {
    log "=== Step 10: Setup PulseAudio ==="
    pct exec "$CTID" -- bash -c '
        apt-get install -y pulseaudio
        # Run PulseAudio in system mode so Sunshine can access it
        pulseaudio --system --daemonize || true
        # Persist across reboots
        cat > /etc/systemd/system/pulseaudio-system.service << EOF
[Unit]
Description=PulseAudio System Mode
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/pulseaudio --system --daemonize
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable pulseaudio-system || true
    '
    log "PulseAudio configured."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_root
    log "Proxmox Sunshine Setup starting. Log: $LOG_FILE"

    install_host_drivers
    select_or_create_ct
    apply_nvidia_passthrough
    install_ct_nvidia_userspace
    create_steamuser
    install_sunshine
    configure_display
    setup_sunshine_service
    install_steam_deps
    setup_pulseaudio

    log ""
    log "=========================================="
    log "Setup complete!"
    log "CT ID: $CTID"
    log "Sunshine web UI: https://<ct-ip>:47990"
    log "Login as steamuser (password: steamuser)"
    log "Change the password and pair with Moonlight."
    log "To launch Steam: su - steamuser -c 'DISPLAY=:99 steam'"
    log "If keyboard input fails, disable Steam Input for the game."
    log "=========================================="
}

main "$@"
