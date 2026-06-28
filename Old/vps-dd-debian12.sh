#!/usr/bin/env bash
set -Eeuo pipefail

ENTRY_ID="debian12-dd-reinstall"
ENTRY_TITLE="Debian 12 Reinstall (VPS)"
WORKDIR="/boot/dd-debian12"
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="https://deb.debian.org/debian"
SCRIPT_NAME="${0##*/}"

HOSTNAME_NEW="${HOSTNAME_NEW:-debian12}"
TIMEZONE="${TIMEZONE:-UTC}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
FORCE_DISK="${FORCE_DISK:-}"
AUTO_YES=0
AUTO_REBOOT=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1; }

usage(){
cat <<EOF
Usage:
  bash ${SCRIPT_NAME} [options]

Options:
  --yes                 Skip interactive confirmation
  --reboot              Reboot automatically when ready
  --password <pass>     Set Debian root password
  --disk <device>       Target disk, e.g. /dev/vda
  --hostname <name>     Hostname after install (default: debian12)
  --timezone <tz>       Timezone (default: UTC)
EOF
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) AUTO_YES=1 ;;
      --reboot) AUTO_REBOOT=1 ;;
      --password)
        [[ $# -ge 2 ]] || die "--password requires a value"
        ROOT_PASSWORD="$2"; shift
        ;;
      --disk)
        [[ $# -ge 2 ]] || die "--disk requires a value"
        FORCE_DISK="$2"; shift
        ;;
      --hostname)
        [[ $# -ge 2 ]] || die "--hostname requires a value"
        HOSTNAME_NEW="$2"; shift
        ;;
      --timezone)
        [[ $# -ge 2 ]] || die "--timezone requires a value"
        TIMEZONE="$2"; shift
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown arg: $1" ;;
    esac
    shift
  done
}

require_root(){
  [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

detect_arch(){
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  log "Architecture: ${ARCH}"
}

install_dependencies(){
  local missing=()
  local c
  for c in ip awk sed grep sha256sum findmnt lsblk cpio gzip openssl; do
    need_cmd "$c" || missing+=("$c")
  done
  if ! need_cmd curl && ! need_cmd wget; then
    missing+=("curl/wget")
  fi

  if (( ${#missing[@]} == 0 )); then
    return
  fi

  log "Installing dependencies"
  if need_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates curl wget iproute2 gawk grep sed coreutils util-linux cpio openssl grub-common grub2-common
  elif need_cmd dnf; then
    dnf install -y ca-certificates curl wget iproute gawk grep sed coreutils util-linux cpio openssl grub2-tools
  elif need_cmd yum; then
    yum install -y ca-certificates curl wget iproute gawk grep sed coreutils util-linux cpio openssl grub2-tools
  else
    die "No supported package manager found"
  fi
}

fetch(){
  local url="$1"
  local out="$2"
  if need_cmd curl; then
    curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$out" "$url"
  else
    wget --tries=3 --timeout=20 -O "$out" "$url"
  fi
}

cidr_to_mask(){
  local cidr="$1"
  local i octet mask=""
  for ((i=0; i<4; i++)); do
    if (( cidr >= 8 )); then
      octet=255
      cidr=$((cidr-8))
    elif (( cidr > 0 )); then
      octet=$((256 - 2**(8-cidr)))
      cidr=0
    else
      octet=0
    fi
    mask+="${octet}"
    [[ $i -lt 3 ]] && mask+="."
  done
  printf '%s\n' "$mask"
}

detect_network(){
  DEFAULT_IF="$(ip -4 route show default | awk 'NR==1{print $5}')"
  if [[ -z "${DEFAULT_IF}" ]]; then
    DEFAULT_IF="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  fi
  [[ -n "${DEFAULT_IF}" ]] || die "Cannot detect default interface"

  IP_CIDR="$(ip -o -4 addr show dev "${DEFAULT_IF}" scope global | awk 'NR==1{print $4}')"
  [[ -n "${IP_CIDR}" ]] || die "Cannot detect IPv4 address"

  IP_ADDR="${IP_CIDR%/*}"
  CIDR="${IP_CIDR#*/}"
  NETMASK="$(cidr_to_mask "${CIDR}")"

  GATEWAY="$(ip -4 route show default | awk 'NR==1{print $3}')"
  if [[ -z "${GATEWAY}" ]]; then
    GATEWAY="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  fi
  [[ -n "${GATEWAY}" ]] || die "Cannot detect gateway"

  mapfile -t _dns < <(awk '/^nameserver[[:space:]]+/{print $2}' /etc/resolv.conf | awk '!seen[$0]++' | head -n 2)
  if (( ${#_dns[@]} == 0 )); then
    _dns=("1.1.1.1" "8.8.8.8")
  fi
  DNS="${_dns[*]}"

  POINTTOPOINT=""
  if [[ "${CIDR}" == "32" ]]; then
    POINTTOPOINT="${GATEWAY}"
  fi

  log "Network: IF=${DEFAULT_IF}, IP=${IP_ADDR}/${CIDR}, GW=${GATEWAY}, DNS=${DNS}"
}

detect_install_disk(){
  if [[ -n "${FORCE_DISK}" ]]; then
    [[ -b "${FORCE_DISK}" ]] || die "Disk not found: ${FORCE_DISK}"
    INSTALL_DISK="${FORCE_DISK}"
    return
  fi

  local src real typ pk
  src="$(findmnt -n -o SOURCE / || true)"
  [[ -n "${src}" ]] || die "Cannot detect root source"

  real="$(readlink -f "${src}" 2>/dev/null || printf '%s' "${src}")"
  while :; do
    typ="$(lsblk -ndo TYPE "${real}" 2>/dev/null | head -n1 || true)"
    if [[ "${typ}" == "disk" ]]; then
      INSTALL_DISK="${real}"
      break
    fi
    pk="$(lsblk -ndo PKNAME "${real}" 2>/dev/null | head -n1 || true)"
    [[ -n "${pk}" ]] || break
    real="/dev/${pk}"
  done

  if [[ -z "${INSTALL_DISK:-}" ]]; then
    INSTALL_DISK="$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')"
  fi

  [[ -n "${INSTALL_DISK:-}" && -b "${INSTALL_DISK}" ]] || die "Cannot detect install disk, use --disk"
}

prompt_password(){
  if [[ -n "${ROOT_PASSWORD}" ]]; then
    return
  fi

  if [[ "${AUTO_YES}" -eq 1 ]]; then
    die "Non-interactive mode requires --password or ROOT_PASSWORD"
  fi

  local p1 p2
  read -r -s -p "Enter Debian root password: " p1; echo
  read -r -s -p "Repeat root password: " p2; echo
  [[ -n "${p1}" ]] || die "Password cannot be empty"
  [[ "${p1}" == "${p2}" ]] || die "Passwords do not match"
  ROOT_PASSWORD="${p1}"
}

verify_sum(){
  local file="$1"
  local rel="$2"
  local expected actual

  expected="$(awk -v p="${rel}" '$2 ~ ("(^|\\./)" p "$") {print $1; exit}' "${WORKDIR}/SHA256SUMS")"
  [[ -n "${expected}" ]] || die "Missing checksum entry: ${rel}"

  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "Checksum mismatch: ${file}"
}

download_installer(){
  local base
  base="${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/main/installer-${ARCH}/current/images"

  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"

  log "Downloading Debian Installer from official mirror"
  fetch "${base}/netboot/debian-installer/${ARCH}/linux" "${WORKDIR}/vmlinuz"
  fetch "${base}/netboot/debian-installer/${ARCH}/initrd.gz" "${WORKDIR}/initrd.gz"
  fetch "${base}/SHA256SUMS" "${WORKDIR}/SHA256SUMS"

  verify_sum "${WORKDIR}/vmlinuz" "netboot/debian-installer/${ARCH}/linux"
  verify_sum "${WORKDIR}/initrd.gz" "netboot/debian-installer/${ARCH}/initrd.gz"
}

generate_preseed(){
  ROOT_PASSWORD_HASH="$(openssl passwd -6 "${ROOT_PASSWORD}")"
  PRESEED_FILE="${WORKDIR}/preseed.cfg"

  {
    echo "d-i debian-installer/locale string en_US.UTF-8"
    echo "d-i keyboard-configuration/xkb-keymap select us"
    echo "d-i netcfg/choose_interface select ${DEFAULT_IF}"
    echo "d-i netcfg/disable_autoconfig boolean true"
    echo "d-i netcfg/get_ipaddress string ${IP_ADDR}"
    echo "d-i netcfg/get_netmask string ${NETMASK}"
    echo "d-i netcfg/get_gateway string ${GATEWAY}"
    if [[ -n "${POINTTOPOINT}" ]]; then
      echo "d-i netcfg/get_pointopoint string ${POINTTOPOINT}"
    fi
    echo "d-i netcfg/get_nameservers string ${DNS}"
    echo "d-i netcfg/confirm_static boolean true"
    echo "d-i netcfg/get_hostname string ${HOSTNAME_NEW}"
    echo "d-i mirror/country string manual"
    echo "d-i mirror/http/hostname string deb.debian.org"
    echo "d-i mirror/http/directory string /debian"
    echo "d-i mirror/http/proxy string"
    echo "d-i mirror/suite string ${DEBIAN_SUITE}"
    echo "d-i mirror/udeb/suite string ${DEBIAN_SUITE}"
    echo "d-i passwd/root-login boolean true"
    echo "d-i passwd/make-user boolean false"
    echo "d-i passwd/root-password-crypted password ${ROOT_PASSWORD_HASH}"
    echo "d-i clock-setup/utc boolean true"
    echo "d-i time/zone string ${TIMEZONE}"
    echo "d-i partman-auto/disk string ${INSTALL_DISK}"
    echo "d-i partman-auto/method string regular"
    echo "d-i partman-auto/choose_recipe select atomic"
    echo "d-i partman/default_filesystem string ext4"
    echo "d-i partman-lvm/device_remove_lvm boolean true"
    echo "d-i partman-md/device_remove_md boolean true"
    echo "d-i partman-partitioning/confirm_write_new_label boolean true"
    echo "d-i partman/choose_partition select finish"
    echo "d-i partman/confirm boolean true"
    echo "d-i partman/confirm_nooverwrite boolean true"
    echo "d-i grub-installer/bootdev string ${INSTALL_DISK}"
    echo "d-i grub-installer/only_debian boolean true"
    echo "d-i grub-installer/with_other_os boolean true"
    echo "tasksel tasksel/first multiselect standard, ssh-server"
    echo "d-i pkgsel/include string openssh-server curl wget sudo ca-certificates"
    echo "d-i finish-install/reboot_in_progress note"
    echo "d-i preseed/late_command string in-target sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; in-target sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
  } > "${PRESEED_FILE}"
}

inject_preseed_into_initrd(){
  local tmpd archive
  tmpd="$(mktemp -d)"
  archive="${tmpd}/preseed.cpio.gz"

  cp "${PRESEED_FILE}" "${tmpd}/preseed.cfg"
  (
    cd "${tmpd}"
    printf '%s\n' preseed.cfg | cpio -o -H newc --quiet | gzip -9 > "${archive}"
  )
  cat "${archive}" >> "${WORKDIR}/initrd.gz"
  rm -rf "${tmpd}"
}

write_grub_entry(){
  cat > /etc/grub.d/09_dd_debian12 <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ENTRY_TITLE}' --id ${ENTRY_ID} {
    insmod gzio
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    insmod xfs
    insmod btrfs
    search --no-floppy --file --set=root ${WORKDIR}/vmlinuz
    linux ${WORKDIR}/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg ---
    initrd ${WORKDIR}/initrd.gz
}
EOF
  chmod 0755 /etc/grub.d/09_dd_debian12
}

find_grub_cfg(){
  GRUB_CFG=""
  shopt -s nullglob
  local cands=(/boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/efi/EFI/*/grub.cfg)
  shopt -u nullglob
  local f
  for f in "${cands[@]}"; do
    if [[ -f "${f}" ]]; then
      GRUB_CFG="${f}"
      break
    fi
  done
}

update_grub_config(){
  find_grub_cfg
  if need_cmd grub2-mkconfig; then
    [[ -n "${GRUB_CFG}" ]] || GRUB_CFG="/boot/grub2/grub.cfg"
    grub2-mkconfig -o "${GRUB_CFG}"
  elif need_cmd grub-mkconfig; then
    [[ -n "${GRUB_CFG}" ]] || GRUB_CFG="/boot/grub/grub.cfg"
    grub-mkconfig -o "${GRUB_CFG}"
  elif need_cmd update-grub; then
    update-grub
  else
    die "Cannot find grub update command"
  fi
}

set_next_boot(){
  if need_cmd grub-reboot; then
    grub-reboot "${ENTRY_ID}"
    BOOT_MODE="one-time"
    return
  fi

  if need_cmd grub2-reboot; then
    grub2-reboot "${ENTRY_ID}"
    BOOT_MODE="one-time"
    return
  fi

  warn "grub-reboot not found; falling back to GRUB_DEFAULT"
  if [[ -f /etc/default/grub ]]; then
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
      sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"${ENTRY_TITLE}\"/" /etc/default/grub
    else
      echo "GRUB_DEFAULT=\"${ENTRY_TITLE}\"" >> /etc/default/grub
    fi
    update_grub_config
    BOOT_MODE="persistent-default"
  else
    die "Cannot set boot entry"
  fi
}

confirm_action(){
  cat <<EOF
========================================
VPS Debian 12 reinstall script
Mirror: ${DEBIAN_MIRROR}
Suite: ${DEBIAN_SUITE}
Arch: ${ARCH}
Disk: ${INSTALL_DISK}
Network: ${IP_ADDR}/${CIDR}  gw ${GATEWAY}
DNS: ${DNS}
========================================
WARNING: Target disk data will be erased.
Make sure you have VPS VNC/console access.
EOF

  if [[ "${AUTO_YES}" -eq 1 ]]; then
    return
  fi

  local ans
  read -r -p "Type YES to continue: " ans
  [[ "${ans}" == "YES" ]] || die "Cancelled"
}

main(){
  parse_args "$@"
  require_root
  detect_arch
  install_dependencies
  detect_network
  detect_install_disk
  prompt_password
  confirm_action

  download_installer
  generate_preseed
  inject_preseed_into_initrd
  write_grub_entry
  update_grub_config
  set_next_boot

  log "Ready. Next boot enters Debian 12 installer (${BOOT_MODE})."

  if [[ "${AUTO_REBOOT}" -eq 1 ]]; then
    reboot
    exit 0
  fi

  local r
  read -r -p "Reboot now to start install? [y/N]: " r
  if [[ "${r}" =~ ^[Yy]$ ]]; then
    reboot
  fi
}

main "$@"

