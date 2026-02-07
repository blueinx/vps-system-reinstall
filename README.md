# VPS Debian 12 Reinstall Script

Recommended script filename:
- `vps-dd-debian12.sh`

This script prepares a one-time GRUB boot entry, then boots into Debian Installer (Bookworm) for unattended reinstall on a generic VPS.

## Important Warning

- This process erases data on the target disk.
- Keep provider console/VNC access ready before reboot.
- Create a snapshot or backup first.

## Features

- Targets Debian 12 (`bookworm`)
- Downloads installer kernel/initrd from official Debian mirror
- Verifies installer files with `SHA256SUMS`
- Detects current IPv4 settings (interface/IP/netmask/gateway/DNS)
- Builds and injects `preseed.cfg` into installer `initrd.gz`
- Adds a GRUB menu entry and sets next boot into installer

## Requirements

- Root privileges
- Linux VPS with GRUB
- Network access to `https://deb.debian.org`

## Usage

1. Grant execute permission:

```bash
chmod +x vps-dd-debian12.sh
```

2. Interactive mode (recommended):

```bash
./vps-dd-debian12.sh
```

3. Non-interactive example:

```bash
./vps-dd-debian12.sh --yes --password 'YourStrongPassword' --disk /dev/vda --reboot
```

## Options

- `--yes` skip confirmation prompt
- `--reboot` reboot automatically when ready
- `--password <pass>` set Debian root password
- `--disk <device>` force target disk (example: `/dev/vda`)
- `--hostname <name>` hostname after install (default: `debian12`)
- `--timezone <tz>` timezone after install (default: `UTC`)

## GitHub Raw Usage

Repository:
- `https://github.com/blueinx/vps-system-reinstall`

Download and run in two steps:

```bash
curl -fL -o vps-dd-debian12.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian12.sh
chmod +x vps-dd-debian12.sh
sudo ./vps-dd-debian12.sh
```

`wget` alternative:

```bash
wget -O vps-dd-debian12.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian12.sh
chmod +x vps-dd-debian12.sh
sudo ./vps-dd-debian12.sh
```

Complete non-interactive GitHub Raw example (download + execute):

```bash
curl -fL -o /tmp/vps-dd-debian12.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian12.sh
chmod +x /tmp/vps-dd-debian12.sh
sudo /tmp/vps-dd-debian12.sh \
  --yes --password 'YourStrongPassword' --disk /dev/vda --reboot
```

## Provider Notes

- Typical KVM system disk is `/dev/vda`; set `--disk` explicitly when possible.
- For `/32` networking, the script writes `pointopoint` automatically.
- After installation, rotate root password and harden SSH.

## Troubleshooting

- If installer does not start after reboot:
- Check GRUB menu for `Debian 12 Reinstall (VPS)`.
- Verify `/etc/grub.d/09_dd_debian12` exists.
- Re-run the script and check GRUB update output.

- If network fails after reinstall:
- Open provider console/VNC and verify network config/routes.
- Confirm IP/gateway/DNS match your VPS provider assignment.
