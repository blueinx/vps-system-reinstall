# Changelog

## 2026.06.28-refactor

- Added Bash 4+ runtime check.
- Refused container/OpenVZ-style environments before disk or GRUB work.
- Tightened target disk path validation and refused removable disks.
- Added installer kernel/initrd minimum-size checks before SHA256 validation.
- Added more Debian Installer preseed answers for firmware, security/updates, GRUB installation, root password confirmation, and reboot completion.
- Backed up existing non-managed GRUB snippet before overwriting.
- Verified final `grub.cfg` contains the generated reinstall menu entry.
- Failed explicitly when `--password-file` or `--password-stdin` returns an empty password.
- Added Chinese and English README files for GitHub raw usage.
- Updated unattended examples so the password is placed on its own line in the password-file heredoc.
