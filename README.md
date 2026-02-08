# VPS Debian Reinstall Script (Debian 12 / Debian 13)

Main script:
- `vps-dd-debian.sh`

This script creates a GRUB boot entry and reboots into Debian Installer for unattended VPS reinstall.

## Important Warning

- The target disk will be erased.
- Keep provider console/VNC access available.
- Create a snapshot/backup before running.

## Features

- Supports Debian 12 (`bookworm`) and Debian 13 (`trixie`)
- Uses official Debian mirror only: `https://deb.debian.org/debian`
- Downloads installer `linux` and `initrd.gz` and verifies them with `SHA256SUMS`
- Detects IPv4 network settings (interface/IP/netmask/gateway/DNS)
- Injects generated `preseed.cfg` into installer `initrd.gz`
- Writes GRUB entry and sets next boot to installer

## Requirements

- Root privileges
- Linux VPS with GRUB
- Network access to `https://deb.debian.org`

## Usage

1. Make script executable:

```bash
chmod +x vps-dd-debian.sh
```

2. Interactive install (default Debian 12):

```bash
sudo ./vps-dd-debian.sh
```

3. Install Debian 13:

```bash
sudo ./vps-dd-debian.sh --debian-version 13
```

4. Non-interactive example:

```bash
sudo ./vps-dd-debian.sh \
  --debian-version 13 \
  --yes \
  --password-file /root/dd-root-pass.txt \
  --disk /dev/vda \
  --reboot
```

## Options

- `--debian-version <12|13>` target Debian version
- `--yes` skip confirmation prompt
- `--reboot` reboot automatically when ready
- `--password <pass>` set root password (less secure in shell history)
- `--password-file <file>` read root password from file first line
- `--disk <device>` set target disk manually (example: `/dev/vda`)
- `--hostname <name>` hostname after install (default: `debian12` / `debian13`)
- `--timezone <tz>` timezone after install (default: `UTC`)
- `--self-test` run built-in checks and exit

## GitHub Raw Usage

Repository:
- `https://github.com/blueinx/vps-system-reinstall`

Download and run with `curl`:

```bash
curl -fL -o vps-dd-debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian.sh
chmod +x vps-dd-debian.sh
sudo ./vps-dd-debian.sh --debian-version 13
```

Download and run with `wget`:

```bash
wget -O vps-dd-debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian.sh
chmod +x vps-dd-debian.sh
sudo ./vps-dd-debian.sh --debian-version 12
```

Full non-interactive GitHub Raw example:

```bash
cat >/tmp/dd-root-pass.txt <<'EOF'
YourStrongPassword
EOF

curl -fL -o /tmp/vps-dd-debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian.sh
chmod +x /tmp/vps-dd-debian.sh
sudo bash /tmp/vps-dd-debian.sh \
  --debian-version 13 \
  --yes \
  --password-file /tmp/dd-root-pass.txt \
  --disk /dev/vda \
  --reboot
```

## Notes

- On KVM VPS, system disk is often `/dev/vda`; pass `--disk` explicitly when possible.
- `/32` network point-to-point is handled automatically.
- After reinstall, rotate credentials and harden SSH policy.

## Troubleshooting

- Installer did not start after reboot:
- Check GRUB menu entry `Debian 12 Reinstall (VPS)` or `Debian 13 Reinstall (VPS)`.
- Check file `/etc/grub.d/09_dd_debian`.
- Re-run script and inspect GRUB update output.

- Network not working after reinstall:
- Verify IP/gateway/DNS from provider console/VNC.
- Confirm routing and interface naming on the new system.
