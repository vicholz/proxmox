# Proxmox Sunshine + NVIDIA GPU Setup

Interactive script to set up NVIDIA GPU passthrough and Sunshine game streaming in a Proxmox LXC container.

## What it does

1. **Install NVIDIA drivers on the Proxmox host** — lists the 5 latest versions and lets you pick one
2. **Select or create an LXC container** — scans existing CTs or creates a new one from a template
3. **Pass NVIDIA devices into the CT** — `/dev/nvidia*`, `/dev/dri/renderD128`, `/dev/uinput`
4. **Install NVIDIA userspace in the CT** — same driver version, `--no-kernel-module`
5. **Create `steamuser`** — non-root user with GPU group permissions
6. **Install Sunshine** — latest release from GitHub, with `csrf_allowed_origins = *`
7. **Configure virtual display** — choose 1080p, 1440p, or 4K via Xvfb
8. **Create systemd service** — Sunshine starts automatically as `steamuser` with the virtual display

## Usage

On the Proxmox host:

```bash
# Clone or copy the script
chmod +x setup.sh
./setup.sh
```

The script is interactive. Follow the prompts.

## After setup

1. Find the CT IP: `pct exec <CTID> -- ip -4 addr show eth0`
2. Open `https://<ct-ip>:47990` in a browser
3. Log in (credentials set during first Sunshine run, or use `sunshine --creds`)
4. Pair with Moonlight
5. Add Steam as an application (install Steam inside the CT first if needed)

## Notes

- Run as root on the Proxmox host
- The host NVIDIA driver must be loaded before the CT can use the GPU
- Steam must run as `steamuser`, not root
- Change the default `steamuser` password after setup

## Requirements

- Proxmox VE host with NVIDIA GPU
- Internet access for downloading drivers and Sunshine
- An Ubuntu-based LXC template (or existing Ubuntu CT)
