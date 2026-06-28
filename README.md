# VPS Debian Reinstall Script Refactor

This is a refactored single-file GRUB-based Debian reinstall helper. It downloads the official Debian netboot installer, injects an unattended preseed file, creates a GRUB entry, and boots into Debian Installer on the next reboot.

GitHub Raw target:

```text
https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/debian.sh
```

## Critical Warning

This script erases the selected disk. Before running it, make sure provider console/VNC access is available and a snapshot or backup exists.

## Supported Scope

- Debian 12 `bookworm`
- Debian 13 `trixie`
- `amd64` and `arm64`
- GRUB-based BIOS or UEFI VPS instances
- Static IPv4, or a current system where IPv4/gateway/DNS can be detected reliably

Not supported: IPv6-only hosts, OpenVZ/LXC/Docker containers, non-GRUB bootloaders, and provider images requiring custom network agents during installation.

## Quick Start

```bash
curl -fL -o /tmp/debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/debian.sh
chmod +x /tmp/debian.sh

sudo /tmp/debian.sh --dry-run
```

If the detected plan is correct:

```bash
sudo /tmp/debian.sh
```

## Recommended Unattended Run

```bash
install -m 600 /dev/null /root/dd-root-pass.txt
cat >/root/dd-root-pass.txt <<'EOF'
ReplaceWithAStrongPassword
EOF

curl -fL -o /tmp/debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/debian.sh
chmod +x /tmp/debian.sh

sudo /tmp/debian.sh \
  --debian-version 13 \
  --yes \
  --password-file /root/dd-root-pass.txt \
  --disk /dev/vda \
  --gpg-verify auto \
  --reboot
```

## Explicit Network Example

```bash
sudo /tmp/debian.sh \
  --debian-version 12 \
  --yes \
  --password-file /root/dd-root-pass.txt \
  --disk /dev/vda \
  --interface auto \
  --ip-cidr 203.0.113.10/24 \
  --gateway 203.0.113.1 \
  --dns 1.1.1.1,8.8.8.8 \
  --reboot
```

## Options

| Option | Description |
| --- | --- |
| `--debian-version <12|13>` | Target Debian version. Default: `12`. |
| `--yes` | Skip destructive confirmation. Required for unattended runs. |
| `--reboot` | Reboot automatically when ready. |
| `--password-file <file>` | Read root password from the first line of a file. Recommended. |
| `--password-stdin` | Read root password from stdin. |
| `--password <pass>` | Direct password argument. Not recommended. |
| `--disk <device>` | Target disk, for example `/dev/vda`. |
| `--hostname <name>` | Hostname after install. |
| `--timezone <tz>` | Timezone after install. Default: `UTC`. |
| `--interface <name|auto>` | Debian Installer network interface. Default: `auto`. |
| `--ip-cidr <addr/prefix>` | Static IPv4 override. |
| `--gateway <addr|none>` | Gateway override. |
| `--dns <addr[,addr]...>` | DNS override. |
| `--mirror <https-url>` | Debian mirror used to fetch installer files. |
| `--installer-mirror-protocol <http|https>` | Protocol used by Debian Installer. Default: `http`. |
| `--gpg-verify <auto|required|off>` | Debian `InRelease` signature policy. Default: `auto`. |
| `--dry-run` | Print detected plan without writing system changes. |
| `--self-test` | Run built-in logic checks and exit. |

## Hardening Changes

- Checks Bash version and refuses container/OpenVZ-style environments.
- Refuses removable disks and unsafe `/dev` paths.
- Verifies installer file size before SHA256 checks.
- Optionally verifies Debian `InRelease` signatures.
- Verifies that the generated GRUB config contains the target menu entry.
- Backs up an existing non-managed GRUB snippet before overwriting.
- Fails clearly when an explicit password source returns an empty password.

## After Install

Immediately rotate the root password, move to SSH key authentication, harden SSH, update the system, and inspect `/var/log/installer/`.
