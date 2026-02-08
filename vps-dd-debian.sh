#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_NAME="${0##*/}"
ENTRY_BASENAME="debian-dd-reinstall"
WORKDIR_BASE="/boot/dd-debian"
GRUB_SNIPPET="/etc/grub.d/09_dd_debian"
OLD_GRUB_SNIPPET="/etc/grub.d/09_dd_debian12"
DEBIAN_MIRROR="https://deb.debian.org/debian"

DEBIAN_VERSION="${DEBIAN_VERSION:-12}"
DEBIAN_SUITE=""
ENTRY_ID=""
ENTRY_TITLE=""
WORKDIR=""
ARCH=""

HOSTNAME_NEW="${HOSTNAME_NEW:-}"
TIMEZONE="${TIMEZONE:-UTC}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ROOT_PASSWORD_FILE="${ROOT_PASSWORD_FILE:-}"
FORCE_DISK="${FORCE_DISK:-}"

AUTO_YES=0
AUTO_REBOOT=0
SELF_TEST=0

DEFAULT_IF=""
IP_CIDR=""
IP_ADDR=""
CIDR=""
NETMASK=""
GATEWAY=""
DNS=""
POINTTOPOINT=""
INSTALL_DISK=""
ROOT_PASSWORD_HASH=""
PRESEED_FILE=""
BOOT_MODE=""

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
  --debian-version <12|13>  Target Debian major version (default: 12)
  --yes                     Skip interactive confirmation
  --reboot                  Reboot automatically when ready
  --password <pass>         Set Debian root password (unsafe in shell history)
  --password-file <file>    Read Debian root password from file (first line)
  --disk <device>           Target disk, e.g. /dev/vda
  --hostname <name>         Hostname after install (default: debian12/debian13)
  --timezone <tz>           Timezone (default: UTC)
  --self-test               Run built-in checks and exit
  -h, --help                Show this help
EOF
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debian-version)
        [[ $# -ge 2 ]] || die "--debian-version requires a value"
        DEBIAN_VERSION="$2"; shift
        ;;
      --yes) AUTO_YES=1 ;;
      --reboot) AUTO_REBOOT=1 ;;
      --password)
        [[ $# -ge 2 ]] || die "--password requires a value"
        ROOT_PASSWORD="$2"; shift
        ;;
      --password-file)
        [[ $# -ge 2 ]] || die "--password-file requires a value"
        ROOT_PASSWORD_FILE="$2"; shift
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
      --self-test) SELF_TEST=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown arg: $1" ;;
    esac
    shift
  done
}

configure_release(){
  case "${DEBIAN_VERSION}" in
    12) DEBIAN_SUITE="bookworm" ;;
    13) DEBIAN_SUITE="trixie" ;;
    *) die "Unsupported --debian-version: ${DEBIAN_VERSION} (use 12 or 13)" ;;
  esac

  if [[ -z "${HOSTNAME_NEW}" ]]; then
    HOSTNAME_NEW="debian${DEBIAN_VERSION}"
  fi

  WORKDIR="${WORKDIR_BASE}${DEBIAN_VERSION}"
  ENTRY_ID="${ENTRY_BASENAME}${DEBIAN_VERSION}"
  ENTRY_TITLE="Debian ${DEBIAN_VERSION} Reinstall (VPS)"
}

require_root(){
  [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

validate_hostname(){
  local hn="$1"
  local pat='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
  [[ "${#hn}" -le 253 ]] || die "Hostname too long (max 253 chars)"
  [[ "${hn}" =~ ${pat} ]] || die "Invalid hostname: ${hn}"
}

validate_timezone(){
  [[ "${TIMEZONE}" =~ ^[A-Za-z0-9._/+-]+$ ]] || die "Invalid timezone: ${TIMEZONE}"
  if [[ -d /usr/share/zoneinfo && ! -e "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    die "Timezone not found in /usr/share/zoneinfo: ${TIMEZONE}"
  fi
}

validate_inputs(){
  validate_hostname "${HOSTNAME_NEW}"
  validate_timezone

  if [[ -n "${ROOT_PASSWORD}" && -n "${ROOT_PASSWORD_FILE}" ]]; then
    die "Use either --password or --password-file, not both"
  fi
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
  for c in ip awk sed grep sha256sum findmnt lsblk cpio gzip openssl readlink mktemp; do
    need_cmd "$c" || missing+=("$c")
  done
  if ! need_cmd curl && ! need_cmd wget; then
    missing+=("curl/wget")
  fi
  if ! need_cmd grub-mkconfig && ! need_cmd grub2-mkconfig && ! need_cmd update-grub; then
    missing+=("grub-mkconfig/grub2-mkconfig/update-grub")
  fi

  if (( ${#missing[@]} == 0 )); then
    return
  fi

  log "Installing dependencies: ${missing[*]}"
  if need_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates curl wget iproute2 gawk grep sed coreutils util-linux cpio gzip openssl grub-common grub2-common
  elif need_cmd dnf; then
    dnf install -y \
      ca-certificates curl wget iproute gawk grep sed coreutils util-linux cpio gzip openssl grub2-tools
  elif need_cmd yum; then
    yum install -y \
      ca-certificates curl wget iproute gawk grep sed coreutils util-linux cpio gzip openssl grub2-tools
  else
    die "No supported package manager found"
  fi
}

fetch(){
  local url="$1"
  local out="$2"
  if need_cmd curl; then
    curl -fL --proto '=https' --tlsv1.2 --connect-timeout 15 --retry 5 --retry-delay 2 --retry-connrefused -o "$out" "$url"
  else
    wget --https-only --tries=5 --timeout=20 -O "$out" "$url"
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
  [[ "${CIDR}" =~ ^[0-9]+$ ]] || die "Invalid CIDR detected: ${CIDR}"
  (( CIDR >= 1 && CIDR <= 32 )) || die "Invalid CIDR detected: ${CIDR}"
  NETMASK="$(cidr_to_mask "${CIDR}")"

  GATEWAY="$(ip -4 route show default | awk 'NR==1{print $3}')"
  if [[ -z "${GATEWAY}" ]]; then
    GATEWAY="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  fi
  [[ -n "${GATEWAY}" ]] || die "Cannot detect gateway"

  mapfile -t _dns < <(awk '/^nameserver[[:space:]]+/{print $2}' /etc/resolv.conf | awk '!seen[$0]++' | head -n 3)
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

resolve_parent_disk(){
  local node="$1"
  local typ pk
  while [[ -n "${node}" ]]; do
    typ="$(lsblk -ndo TYPE "${node}" 2>/dev/null | head -n1 || true)"
    if [[ "${typ}" == "disk" ]]; then
      printf '%s\n' "${node}"
      return 0
    fi
    pk="$(lsblk -ndo PKNAME "${node}" 2>/dev/null | head -n1 || true)"
    [[ -n "${pk}" ]] || break
    node="/dev/${pk}"
  done
  return 1
}

validate_disk_device(){
  local disk="$1"
  [[ -b "${disk}" ]] || die "Disk not found: ${disk}"
  local typ
  typ="$(lsblk -ndo TYPE "${disk}" 2>/dev/null | head -n1 || true)"
  [[ "${typ}" == "disk" ]] || die "Not a raw disk device: ${disk}"
}

detect_install_disk(){
  if [[ -n "${FORCE_DISK}" ]]; then
    validate_disk_device "${FORCE_DISK}"
    INSTALL_DISK="${FORCE_DISK}"
    return
  fi

  local src real
  src="$(findmnt -n -o SOURCE / || true)"
  [[ -n "${src}" ]] || die "Cannot detect root source"
  real="$(readlink -f "${src}" 2>/dev/null || printf '%s' "${src}")"

  if ! INSTALL_DISK="$(resolve_parent_disk "${real}")"; then
    INSTALL_DISK="$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')"
  fi

  validate_disk_device "${INSTALL_DISK}"
}

load_password_from_file(){
  local path="$1"
  [[ -r "${path}" ]] || die "Cannot read password file: ${path}"
  IFS= read -r ROOT_PASSWORD < "${path}" || true
  ROOT_PASSWORD="${ROOT_PASSWORD%$'\r'}"
}

prompt_password(){
  if [[ -n "${ROOT_PASSWORD_FILE}" ]]; then
    load_password_from_file "${ROOT_PASSWORD_FILE}"
  fi

  if [[ -n "${ROOT_PASSWORD}" ]]; then
    if (( ${#ROOT_PASSWORD} < 8 )); then
      warn "Root password length is less than 8 characters"
    fi
    return
  fi

  if [[ "${AUTO_YES}" -eq 1 ]]; then
    die "Non-interactive mode requires --password, --password-file, ROOT_PASSWORD, or ROOT_PASSWORD_FILE"
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

  expected="$(awk -v p="${rel}" '{
    f=$2
    if (substr(f,1,1) == "*") f=substr(f,2)
    if (substr(f,1,2) == "./") f=substr(f,3)
    if (f == p) { print $1; exit }
  }' "${WORKDIR}/SHA256SUMS")"
  [[ -n "${expected}" ]] || die "Missing checksum entry: ${rel}"

  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "Checksum mismatch: ${file}"
}

download_installer(){
  local base linux_rel initrd_rel
  base="${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/main/installer-${ARCH}/current/images"
  linux_rel="netboot/debian-installer/${ARCH}/linux"
  initrd_rel="netboot/debian-installer/${ARCH}/initrd.gz"

  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"

  log "Downloading Debian ${DEBIAN_VERSION} installer from official mirror"
  fetch "${base}/${linux_rel}" "${WORKDIR}/vmlinuz"
  fetch "${base}/${initrd_rel}" "${WORKDIR}/initrd.gz"
  fetch "${base}/SHA256SUMS" "${WORKDIR}/SHA256SUMS"

  verify_sum "${WORKDIR}/vmlinuz" "${linux_rel}"
  verify_sum "${WORKDIR}/initrd.gz" "${initrd_rel}"
}

generate_preseed(){
  ROOT_PASSWORD_HASH="$(openssl passwd -6 "${ROOT_PASSWORD}")"
  PRESEED_FILE="${WORKDIR}/preseed.cfg"

  {
    cat <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select ${DEFAULT_IF}
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string ${IP_ADDR}
d-i netcfg/get_netmask string ${NETMASK}
d-i netcfg/get_gateway string ${GATEWAY}
EOF
    if [[ -n "${POINTTOPOINT}" ]]; then
      echo "d-i netcfg/get_pointopoint string ${POINTTOPOINT}"
    fi
    cat <<EOF
d-i netcfg/get_nameservers string ${DNS}
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string ${HOSTNAME_NEW}
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string ${DEBIAN_SUITE}
d-i mirror/udeb/suite string ${DEBIAN_SUITE}
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password ${ROOT_PASSWORD_HASH}
d-i clock-setup/utc boolean true
d-i time/zone string ${TIMEZONE}
d-i partman-auto/disk string ${INSTALL_DISK}
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman/default_filesystem string ext4
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i grub-installer/bootdev string ${INSTALL_DISK}
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string openssh-server curl wget sudo ca-certificates
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string in-target sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; in-target sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
EOF
  } > "${PRESEED_FILE}"

  chmod 0600 "${PRESEED_FILE}"
  ROOT_PASSWORD=""
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
  rm -f "${OLD_GRUB_SNIPPET}"
  cat > "${GRUB_SNIPPET}" <<EOF
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
  chmod 0755 "${GRUB_SNIPPET}"
}

find_grub_cfg(){
  GRUB_CFG=""
  shopt -s nullglob
  local cands=(/boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg)
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

  warn "grub-reboot/grub2-reboot not found; falling back to persistent default"
  if need_cmd grub-set-default; then
    grub-set-default "${ENTRY_ID}"
    BOOT_MODE="persistent-default"
    return
  fi

  if need_cmd grub2-set-default; then
    grub2-set-default "${ENTRY_ID}"
    BOOT_MODE="persistent-default"
    return
  fi

  if [[ -f /etc/default/grub ]]; then
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
      sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"${ENTRY_TITLE}\"/" /etc/default/grub
    else
      echo "GRUB_DEFAULT=\"${ENTRY_TITLE}\"" >> /etc/default/grub
    fi
    update_grub_config
    BOOT_MODE="persistent-default"
    return
  fi

  die "Cannot set next boot entry"
}

confirm_action(){
  cat <<EOF
========================================
VPS Debian reinstall script
Target Debian: ${DEBIAN_VERSION} (${DEBIAN_SUITE})
Mirror: ${DEBIAN_MIRROR}
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

self_test(){
  local old_version old_hostname old_timezone
  old_version="${DEBIAN_VERSION}"
  old_hostname="${HOSTNAME_NEW}"
  old_timezone="${TIMEZONE}"

  DEBIAN_VERSION=12
  HOSTNAME_NEW=""
  configure_release
  [[ "${DEBIAN_SUITE}" == "bookworm" ]] || die "self-test: Debian 12 mapping failed"
  [[ "${HOSTNAME_NEW}" == "debian12" ]] || die "self-test: hostname default for Debian 12 failed"
  [[ "$(cidr_to_mask 24)" == "255.255.255.0" ]] || die "self-test: cidr_to_mask /24 failed"
  [[ "$(cidr_to_mask 32)" == "255.255.255.255" ]] || die "self-test: cidr_to_mask /32 failed"
  validate_hostname "debian-test"
  TIMEZONE="UTC"
  validate_timezone

  DEBIAN_VERSION=13
  HOSTNAME_NEW=""
  configure_release
  [[ "${DEBIAN_SUITE}" == "trixie" ]] || die "self-test: Debian 13 mapping failed"
  [[ "${HOSTNAME_NEW}" == "debian13" ]] || die "self-test: hostname default for Debian 13 failed"

  DEBIAN_VERSION="${old_version}"
  HOSTNAME_NEW="${old_hostname}"
  TIMEZONE="${old_timezone}"
  log "Self-test passed"
}

main(){
  parse_args "$@"

  if [[ "${SELF_TEST}" -eq 1 ]]; then
    self_test
    exit 0
  fi

  configure_release
  validate_inputs
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

  log "Ready. Next boot enters Debian ${DEBIAN_VERSION} installer (${BOOT_MODE})."

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
