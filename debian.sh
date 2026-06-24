#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="2026.06.12"

ENTRY_BASENAME="debian-dd-reinstall"
WORKDIR_BASE="/boot/dd-debian"
GRUB_SNIPPET="/etc/grub.d/09_dd_debian"
OLD_GRUB_SNIPPETS=("/etc/grub.d/09_dd_debian12")

DEBIAN_VERSION="${DEBIAN_VERSION:-12}"
DEBIAN_SUITE=""
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
INSTALLER_MIRROR_PROTOCOL="${INSTALLER_MIRROR_PROTOCOL:-http}"
VERIFY_GPG="${VERIFY_GPG:-auto}"

HOSTNAME_NEW="${HOSTNAME_NEW:-}"
TIMEZONE="${TIMEZONE:-UTC}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ROOT_PASSWORD_FILE="${ROOT_PASSWORD_FILE:-}"
FORCE_DISK="${FORCE_DISK:-}"
INPUT_IFACE="${INTERFACE:-}"
INPUT_IP_CIDR="${STATIC_IP_CIDR:-}"
INPUT_GATEWAY="${STATIC_GATEWAY:-}"
INPUT_DNS="${STATIC_DNS:-}"

AUTO_YES=0
AUTO_REBOOT=0
SELF_TEST=0
DRY_RUN=0
PASSWORD_STDIN=0

ARCH=""
WORKDIR=""
ENTRY_ID=""
ENTRY_TITLE=""
BOOT_FIRMWARE="bios"
BOOT_MODE=""

DETECTED_IF=""
PRESEED_IF="auto"
IP_ADDR=""
CIDR=""
NETMASK=""
GATEWAY=""
DNS=""
POINTTOPOINT=""
INSTALL_DISK=""
ROOT_PASSWORD_HASH=""
PRESEED_FILE=""
MIRROR_HOST=""
MIRROR_DIR=""
GRUB_CFG=""
KERNEL_GRUB_PATH=""
INITRD_GRUB_PATH=""
GPG_VERIFIED=0

TMP_DIRS=()

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

log(){ printf '%s[INFO]%s %s\n' "${GREEN}" "${NC}" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "${YELLOW}" "${NC}" "$*" >&2; }
die(){ printf '%s[ERROR]%s %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

on_error(){
  local line="$1"
  local code="$2"
  printf '%s[ERROR]%s Failed at line %s (exit %s)\n' "${RED}" "${NC}" "${line}" "${code}" >&2
  exit "${code}"
}

cleanup_tmp(){
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "${d}" && "${d}" == /tmp/* && -d "${d}" ]] && rm -rf -- "${d}"
  done
}

trap 'on_error "${LINENO}" "$?"' ERR
trap cleanup_tmp EXIT

usage(){
cat <<EOF
Usage:
  bash ${SCRIPT_NAME} [options]

Options:
  --debian-version <12|13>        Target Debian major version (default: 12)
  --yes                           Skip destructive confirmation
  --reboot                        Reboot automatically when ready
  --password <pass>               Set root password (unsafe in shell history)
  --password-file <file>          Read root password from file first line
  --password-stdin                Read root password from stdin first line
  --disk <device>                 Target disk, e.g. /dev/vda
  --hostname <name>               Hostname after install
  --timezone <tz>                 Timezone after install (default: UTC)
  --interface <name|auto>         Installer network interface (default: auto)
  --ip-cidr <addr/prefix>         Static IPv4 CIDR override, e.g. 203.0.113.10/24
  --gateway <addr|none>           Static gateway override
  --dns <addr[,addr]...>          DNS override, e.g. 1.1.1.1,8.8.8.8
  --mirror <https-url>            Debian mirror used to fetch installer
  --installer-mirror-protocol <http|https>
                                  Protocol used by Debian Installer packages
  --gpg-verify <auto|required|off>
                                  Verify InRelease when Debian keyring is available
  --dry-run                       Detect and print plan without writing changes
  --self-test                     Run built-in checks and exit
  -h, --help                      Show this help

Environment variables:
  DEBIAN_VERSION, DEBIAN_MIRROR, INSTALLER_MIRROR_PROTOCOL, VERIFY_GPG
  HOSTNAME_NEW, TIMEZONE, ROOT_PASSWORD, ROOT_PASSWORD_FILE, FORCE_DISK
  INTERFACE, STATIC_IP_CIDR, STATIC_GATEWAY, STATIC_DNS
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
      --password-stdin) PASSWORD_STDIN=1 ;;
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
      --interface)
        [[ $# -ge 2 ]] || die "--interface requires a value"
        INPUT_IFACE="$2"; shift
        ;;
      --ip-cidr)
        [[ $# -ge 2 ]] || die "--ip-cidr requires a value"
        INPUT_IP_CIDR="$2"; shift
        ;;
      --gateway)
        [[ $# -ge 2 ]] || die "--gateway requires a value"
        INPUT_GATEWAY="$2"; shift
        ;;
      --dns)
        [[ $# -ge 2 ]] || die "--dns requires a value"
        INPUT_DNS="$2"; shift
        ;;
      --mirror)
        [[ $# -ge 2 ]] || die "--mirror requires a value"
        DEBIAN_MIRROR="$2"; shift
        ;;
      --installer-mirror-protocol)
        [[ $# -ge 2 ]] || die "--installer-mirror-protocol requires a value"
        INSTALLER_MIRROR_PROTOCOL="$2"; shift
        ;;
      --gpg-verify)
        [[ $# -ge 2 ]] || die "--gpg-verify requires a value"
        VERIFY_GPG="$2"; shift
        ;;
      --dry-run) DRY_RUN=1 ;;
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

  [[ -n "${HOSTNAME_NEW}" ]] || HOSTNAME_NEW="debian${DEBIAN_VERSION}"

  WORKDIR="${WORKDIR_BASE}-${DEBIAN_VERSION}"
  ENTRY_ID="${ENTRY_BASENAME}-${DEBIAN_VERSION}"
  ENTRY_TITLE="Debian ${DEBIAN_VERSION} Reinstall (VPS)"
}

require_root(){
  [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

validate_hostname(){
  local hn="$1"
  local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  [[ "${#hn}" -le 253 ]] || die "Hostname too long (max 253 chars)"
  [[ "${hn}" =~ ^${label}(\.${label})*$ ]] || die "Invalid hostname: ${hn}"
}

validate_timezone(){
  [[ "${TIMEZONE}" =~ ^[A-Za-z0-9._/+-]+$ ]] || die "Invalid timezone: ${TIMEZONE}"
  if [[ -d /usr/share/zoneinfo && ! -e "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    die "Timezone not found in /usr/share/zoneinfo: ${TIMEZONE}"
  fi
}

valid_ipv4(){
  local ip="$1" o
  [[ "${ip}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS='.' read -r -a o <<< "${ip}"
  [[ "${#o[@]}" -eq 4 ]] || return 1
  local n value
  for n in "${o[@]}"; do
    [[ "${n}" =~ ^[0-9]+$ ]] || return 1
    (( ${#n} <= 3 )) || return 1
    value=$((10#${n}))
    (( value >= 0 && value <= 255 )) || return 1
  done
}

valid_cidr(){
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]] || return 1
  local value=$((10#${p}))
  (( value >= 1 && value <= 32 ))
}

validate_iface(){
  local iface="$1"
  [[ "${iface}" == "auto" || "${iface}" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Invalid interface: ${iface}"
}

normalize_dns(){
  local raw="$1" ns out=()
  raw="${raw//,/ }"
  for ns in ${raw}; do
    valid_ipv4 "${ns}" || die "Invalid DNS IPv4 address: ${ns}"
    out+=("${ns}")
  done
  (( ${#out[@]} > 0 )) || die "DNS list cannot be empty"
  DNS="${out[*]}"
}

parse_ip_cidr(){
  local value="$1"
  [[ "${value}" == */* ]] || die "Invalid CIDR, expected addr/prefix: ${value}"
  IP_ADDR="${value%/*}"
  CIDR="${value#*/}"
  valid_ipv4 "${IP_ADDR}" || die "Invalid IPv4 address: ${IP_ADDR}"
  valid_cidr "${CIDR}" || die "Invalid CIDR prefix: ${CIDR}"
  CIDR="$((10#${CIDR}))"
  NETMASK="$(cidr_to_mask "${CIDR}")"
}

validate_mirror(){
  local mirror_re='^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/%+-]*)?$'
  case "${DEBIAN_MIRROR}" in
    https://*) ;;
    *) die "Mirror must use https:// for installer download: ${DEBIAN_MIRROR}" ;;
  esac
  [[ "${DEBIAN_MIRROR}" =~ ${mirror_re} ]] || die "Invalid mirror URL: ${DEBIAN_MIRROR}"
  DEBIAN_MIRROR="${DEBIAN_MIRROR%/}"
}

parse_mirror_for_preseed(){
  local u="${DEBIAN_MIRROR#https://}"
  MIRROR_HOST="${u%%/*}"
  if [[ "${u}" == */* ]]; then
    MIRROR_DIR="/${u#*/}"
  else
    MIRROR_DIR="/debian"
  fi
  [[ "${MIRROR_HOST}" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid mirror host: ${MIRROR_HOST}"
  [[ "${MIRROR_DIR}" =~ ^/[A-Za-z0-9._~/%+-]*$ ]] || die "Invalid mirror directory: ${MIRROR_DIR}"
}

validate_inputs(){
  validate_hostname "${HOSTNAME_NEW}"
  validate_timezone
  validate_mirror
  parse_mirror_for_preseed

  case "${INSTALLER_MIRROR_PROTOCOL}" in
    http|https) ;;
    *) die "--installer-mirror-protocol must be http or https" ;;
  esac
  case "${VERIFY_GPG}" in
    auto|required|off) ;;
    *) die "--gpg-verify must be auto, required, or off" ;;
  esac
  [[ -z "${INPUT_IFACE}" ]] || validate_iface "${INPUT_IFACE}"
  [[ -z "${INPUT_DNS}" ]] || normalize_dns "${INPUT_DNS}"

  local sources=0
  [[ -n "${ROOT_PASSWORD}" ]] && sources=$((sources + 1))
  [[ -n "${ROOT_PASSWORD_FILE}" ]] && sources=$((sources + 1))
  [[ "${PASSWORD_STDIN}" -eq 1 ]] && sources=$((sources + 1))
  (( sources <= 1 )) || die "Use only one password source"
}

detect_arch(){
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  log "Architecture: ${ARCH}"
}

detect_boot_firmware(){
  if [[ -d /sys/firmware/efi ]]; then
    BOOT_FIRMWARE="uefi"
  else
    BOOT_FIRMWARE="bios"
  fi
  log "Firmware: ${BOOT_FIRMWARE}"
}

install_dependencies(){
  local missing=()
  local c
  for c in ip awk sed grep sha256sum findmnt lsblk cpio gzip openssl readlink mktemp chmod cp rm mkdir uname; do
    need_cmd "${c}" || missing+=("${c}")
  done
  if ! need_cmd curl && ! need_cmd wget; then
    missing+=("curl/wget")
  fi
  if ! need_cmd grub-mkconfig && ! need_cmd grub2-mkconfig && ! need_cmd update-grub; then
    missing+=("grub-mkconfig/grub2-mkconfig/update-grub")
  fi
  if ! need_cmd grub-reboot && ! need_cmd grub2-reboot && ! need_cmd grub-set-default && ! need_cmd grub2-set-default; then
    missing+=("grub-reboot/grub-set-default")
  fi

  if (( ${#missing[@]} == 0 )); then
    return
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    die "Missing dependencies for --dry-run: ${missing[*]}"
  fi

  log "Installing missing dependencies: ${missing[*]}"
  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates curl wget iproute2 gawk grep sed coreutils util-linux \
      cpio gzip openssl grub-common grub2-common
    if [[ "${VERIFY_GPG}" != "off" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y gpgv debian-archive-keyring || \
        warn "Could not install Debian archive keyring; GPG verification may be unavailable"
    fi
  elif need_cmd dnf; then
    dnf install -y \
      ca-certificates curl wget iproute gawk grep sed coreutils util-linux \
      cpio gzip openssl grub2-tools gnupg2
  elif need_cmd yum; then
    yum install -y \
      ca-certificates curl wget iproute gawk grep sed coreutils util-linux \
      cpio gzip openssl grub2-tools gnupg2
  else
    die "No supported package manager found to install dependencies"
  fi
}

check_runtime_capabilities(){
  if ! printf '%s' "test" | openssl passwd -6 -stdin >/dev/null 2>&1; then
    die "openssl passwd -6 -stdin is not supported by this OpenSSL build"
  fi
}

fetch(){
  local url="$1"
  local out="$2"
  if need_cmd curl; then
    curl -fL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
      --retry 5 --retry-delay 2 --retry-connrefused \
      --speed-limit 1024 --speed-time 30 -o "${out}" "${url}"
  else
    wget --https-only --tries=5 --timeout=30 --read-timeout=60 -O "${out}" "${url}"
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
    [[ "${i}" -lt 3 ]] && mask+="."
  done
  printf '%s\n' "${mask}"
}

detect_default_iface(){
  local route
  route="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)"
  DETECTED_IF="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "${route}")"
  if [[ -z "${DETECTED_IF}" ]]; then
    DETECTED_IF="$(ip -4 route show default | awk 'NR==1{print $5}')"
  fi
  [[ -n "${DETECTED_IF}" ]] || die "Cannot detect default network interface"
}

detect_network(){
  local route src ip_cidr gw dns_lines=()

  if [[ -n "${INPUT_IFACE}" && "${INPUT_IFACE}" != "auto" ]]; then
    DETECTED_IF="${INPUT_IFACE}"
  else
    detect_default_iface
  fi
  validate_iface "${DETECTED_IF}"
  PRESEED_IF="${INPUT_IFACE:-auto}"
  validate_iface "${PRESEED_IF}"

  route="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)"
  src="$(awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' <<< "${route}")"

  if [[ -n "${INPUT_IP_CIDR}" ]]; then
    parse_ip_cidr "${INPUT_IP_CIDR}"
  else
    ip_cidr=""
    if [[ -n "${src}" ]]; then
      ip_cidr="$(ip -o -4 addr show dev "${DETECTED_IF}" scope global | awk -v ip="${src}" '{split($4,a,"/"); if(a[1] == ip){print $4; exit}}')"
    fi
    [[ -n "${ip_cidr}" ]] || ip_cidr="$(ip -o -4 addr show dev "${DETECTED_IF}" scope global | awk 'NR==1{print $4}')"
    [[ -n "${ip_cidr}" ]] || die "Cannot detect IPv4 address on ${DETECTED_IF}"
    parse_ip_cidr "${ip_cidr}"
  fi

  if [[ -n "${INPUT_GATEWAY}" ]]; then
    GATEWAY="${INPUT_GATEWAY}"
  else
    gw="$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<< "${route}")"
    [[ -n "${gw}" ]] || gw="$(ip -4 route show default dev "${DETECTED_IF}" 2>/dev/null | awk 'NR==1{print $3}')"
    GATEWAY="${gw}"
  fi

  if [[ "${GATEWAY}" == "none" ]]; then
    :
  else
    [[ -n "${GATEWAY}" ]] || die "Cannot detect gateway; pass --gateway <addr> or --gateway none"
    valid_ipv4 "${GATEWAY}" || die "Invalid gateway IPv4 address: ${GATEWAY}"
  fi

  if [[ -z "${INPUT_DNS}" ]]; then
    mapfile -t dns_lines < <(awk '/^nameserver[[:space:]]+[0-9.]+$/{print $2}' /etc/resolv.conf | awk '!seen[$0]++' | head -n 3)
    if (( ${#dns_lines[@]} == 0 )); then
      dns_lines=("1.1.1.1" "8.8.8.8")
    fi
    DNS="${dns_lines[*]}"
    normalize_dns "${DNS}"
  fi

  POINTTOPOINT=""
  if [[ "${CIDR}" == "32" && "${GATEWAY}" != "none" ]]; then
    POINTTOPOINT="${GATEWAY}"
  fi

  log "Network: detected_if=${DETECTED_IF}, installer_if=${PRESEED_IF}, ip=${IP_ADDR}/${CIDR}, gateway=${GATEWAY}, dns=${DNS}"
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
  [[ "${disk}" == /dev/* ]] || die "Disk must be under /dev: ${disk}"
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
  local disk_count
  src="$(findmnt -n -o SOURCE / || true)"
  [[ -n "${src}" ]] || die "Cannot detect root filesystem source"
  real="$(readlink -f "${src}" 2>/dev/null || printf '%s' "${src}")"

  if ! INSTALL_DISK="$(resolve_parent_disk "${real}")"; then
    INSTALL_DISK="$(lsblk -ndo NAME,TYPE,RM | awk '$2=="disk" && $3==0 {print "/dev/"$1; exit}')"
  fi

  validate_disk_device "${INSTALL_DISK}"
  disk_count="$(lsblk -ndo TYPE,RM | awk '$1=="disk" && $2==0 {c++} END{print c+0}')"
  if [[ "${AUTO_YES}" -eq 1 && "${disk_count}" -gt 1 ]]; then
    die "Multiple disks detected; non-interactive mode requires --disk <device>"
  fi
  log "Install disk: ${INSTALL_DISK}"
}

load_password_from_file(){
  local path="$1"
  [[ -r "${path}" ]] || die "Cannot read password file: ${path}"
  IFS= read -r ROOT_PASSWORD < "${path}" || true
  ROOT_PASSWORD="${ROOT_PASSWORD%$'\r'}"
}

read_password_from_stdin(){
  IFS= read -r ROOT_PASSWORD || true
  ROOT_PASSWORD="${ROOT_PASSWORD%$'\r'}"
}

prompt_password(){
  if [[ -n "${ROOT_PASSWORD_FILE}" ]]; then
    load_password_from_file "${ROOT_PASSWORD_FILE}"
  elif [[ "${PASSWORD_STDIN}" -eq 1 ]]; then
    read_password_from_stdin
  fi

  if [[ -n "${ROOT_PASSWORD}" ]]; then
    if (( ${#ROOT_PASSWORD} < 8 )); then
      warn "Root password length is less than 8 characters"
    fi
    return
  fi

  if [[ "${AUTO_YES}" -eq 1 ]]; then
    die "Non-interactive mode requires --password-file, --password-stdin, --password, ROOT_PASSWORD, or ROOT_PASSWORD_FILE"
  fi

  local p1 p2
  read -r -s -p "Enter Debian root password: " p1; printf '\n'
  read -r -s -p "Repeat root password: " p2; printf '\n'
  [[ -n "${p1}" ]] || die "Password cannot be empty"
  [[ "${p1}" == "${p2}" ]] || die "Passwords do not match"
  ROOT_PASSWORD="${p1}"
}

prepare_workdir(){
  [[ -n "${WORKDIR}" && "${WORKDIR}" == "${WORKDIR_BASE}-"* ]] || die "Unsafe workdir: ${WORKDIR}"
  rm -rf -- "${WORKDIR}"
  mkdir -p -- "${WORKDIR}"
  chmod 0700 "${WORKDIR}"
}

find_debian_keyrings(){
  local f seen=" "
  DEBIAN_KEYRINGS=()
  local candidates=(
    /usr/share/keyrings/debian-archive-keyring.gpg
    /etc/apt/trusted.gpg
  )
  shopt -s nullglob
  candidates+=(/usr/share/keyrings/debian-archive-*.gpg /etc/apt/trusted.gpg.d/debian-archive-*.gpg)
  shopt -u nullglob
  for f in "${candidates[@]}"; do
    if [[ -r "${f}" && "${seen}" != *" ${f} "* ]]; then
      DEBIAN_KEYRINGS+=("${f}")
      seen+=" ${f} "
    fi
  done
}

verify_inrelease(){
  [[ "${VERIFY_GPG}" != "off" ]] || return 0
  if ! need_cmd gpgv; then
    if [[ "${VERIFY_GPG}" == "required" ]]; then
      die "gpgv is required but not available"
    fi
    warn "gpgv not available; using HTTPS plus SHA256SUMS only"
    return 0
  fi

  local DEBIAN_KEYRINGS=()
  find_debian_keyrings
  if (( ${#DEBIAN_KEYRINGS[@]} == 0 )); then
    if [[ "${VERIFY_GPG}" == "required" ]]; then
      die "Debian archive keyring not found"
    fi
    warn "Debian archive keyring not found; using HTTPS plus SHA256SUMS only"
    return 0
  fi

  local args=()
  local keyring
  for keyring in "${DEBIAN_KEYRINGS[@]}"; do
    args+=(--keyring "${keyring}")
  done

  if gpgv "${args[@]}" "${WORKDIR}/InRelease" >/dev/null 2>&1; then
    GPG_VERIFIED=1
    log "Verified Debian InRelease signature"
  else
    if [[ "${VERIFY_GPG}" == "required" ]]; then
      die "Debian InRelease signature verification failed"
    fi
    warn "Debian InRelease signature verification failed; using HTTPS plus SHA256SUMS only"
  fi
}

verify_file_against_inrelease(){
  local file="$1"
  local rel="$2"
  [[ "${GPG_VERIFIED}" -eq 1 ]] || return 0

  local expected actual
  expected="$(awk -v p="${rel}" '
    /^SHA256:/ { in_sha=1; next }
    /^[A-Za-z0-9-]+:/ { in_sha=0 }
    in_sha && NF >= 3 && $3 == p { print $1; exit }
  ' "${WORKDIR}/InRelease")"
  [[ -n "${expected}" ]] || die "Missing InRelease SHA256 entry: ${rel}"

  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "InRelease checksum mismatch: ${rel}"
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
  [[ -n "${expected}" ]] || die "Missing SHA256SUMS entry: ${rel}"

  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "Checksum mismatch: ${file}"
}

download_installer(){
  local image_rel image_base linux_rel initrd_rel sums_rel
  image_rel="main/installer-${ARCH}/current/images"
  image_base="${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/${image_rel}"
  linux_rel="netboot/debian-installer/${ARCH}/linux"
  initrd_rel="netboot/debian-installer/${ARCH}/initrd.gz"
  sums_rel="${image_rel}/SHA256SUMS"

  prepare_workdir

  log "Downloading Debian ${DEBIAN_VERSION} installer metadata"
  fetch "${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/InRelease" "${WORKDIR}/InRelease"
  fetch "${image_base}/SHA256SUMS" "${WORKDIR}/SHA256SUMS"
  verify_inrelease
  verify_file_against_inrelease "${WORKDIR}/SHA256SUMS" "${sums_rel}"

  log "Downloading Debian ${DEBIAN_VERSION} installer kernel and initrd"
  fetch "${image_base}/${linux_rel}" "${WORKDIR}/vmlinuz"
  fetch "${image_base}/${initrd_rel}" "${WORKDIR}/initrd.gz"

  verify_sum "${WORKDIR}/vmlinuz" "${linux_rel}"
  verify_sum "${WORKDIR}/initrd.gz" "${initrd_rel}"
}

make_password_hash(){
  ROOT_PASSWORD_HASH="$(printf '%s' "${ROOT_PASSWORD}" | openssl passwd -6 -stdin)"
  ROOT_PASSWORD=""
  unset ROOT_PASSWORD
}

generate_preseed(){
  make_password_hash
  PRESEED_FILE="${WORKDIR}/preseed.cfg"

  {
    cat <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select ${PRESEED_IF}
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string ${IP_ADDR}
d-i netcfg/get_netmask string ${NETMASK}
d-i netcfg/get_gateway string ${GATEWAY}
EOF
    if [[ -n "${POINTTOPOINT}" ]]; then
      printf 'd-i netcfg/get_pointopoint string %s\n' "${POINTTOPOINT}"
    fi
    cat <<EOF
d-i netcfg/get_nameservers string ${DNS}
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string ${HOSTNAME_NEW}
d-i mirror/country string manual
d-i mirror/protocol string ${INSTALLER_MIRROR_PROTOCOL}
d-i mirror/http/hostname string ${MIRROR_HOST}
d-i mirror/http/directory string ${MIRROR_DIR}
d-i mirror/http/proxy string
d-i mirror/suite string ${DEBIAN_SUITE}
d-i mirror/udeb/suite string ${DEBIAN_SUITE}
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password ${ROOT_PASSWORD_HASH}
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true
d-i time/zone string ${TIMEZONE}
d-i partman-auto/disk string ${INSTALL_DISK}
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman/default_filesystem string ext4
d-i partman/mount_style select uuid
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-md/confirm boolean true
d-i partman-md/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
EOF
    if [[ "${BOOT_FIRMWARE}" == "uefi" ]]; then
      cat <<EOF
d-i partman-efi/non_efi_system boolean true
d-i partman-partitioning/default_label string gpt
d-i partman-partitioning/choose_label select gpt
d-i grub-installer/force-efi-extra-removable boolean true
EOF
    fi
    cat <<EOF
d-i grub-installer/bootdev string ${INSTALL_DISK}
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string openssh-server curl wget sudo ca-certificates
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string in-target /bin/sh -c "mkdir -p /etc/ssh/sshd_config.d; printf '%s\\n' 'PermitRootLogin yes' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/99-dd-root-login.conf"; in-target /bin/sh -c "systemctl enable ssh >/dev/null 2>&1 || true"
EOF
  } > "${PRESEED_FILE}"

  chmod 0600 "${PRESEED_FILE}"
  ROOT_PASSWORD_HASH=""
}

inject_preseed_into_initrd(){
  local tmpd archive
  tmpd="$(mktemp -d)"
  TMP_DIRS+=("${tmpd}")
  archive="${tmpd}/preseed.cpio.gz"

  cp "${PRESEED_FILE}" "${tmpd}/preseed.cfg"
  (
    cd "${tmpd}"
    printf '%s\n' preseed.cfg | cpio -o -H newc --quiet | gzip -n -9 > "${archive}"
  )
  cat "${archive}" >> "${WORKDIR}/initrd.gz"
  rm -f -- "${PRESEED_FILE}"
}

grub_relpath(){
  local path="$1"
  if need_cmd grub-mkrelpath; then
    grub-mkrelpath "${path}"
  elif need_cmd grub2-mkrelpath; then
    grub2-mkrelpath "${path}"
  elif findmnt -n /boot >/dev/null 2>&1 && [[ "${path}" == /boot/* ]]; then
    printf '/%s\n' "${path#/boot/}"
  else
    printf '%s\n' "${path}"
  fi
}

write_grub_entry(){
  local old
  for old in "${OLD_GRUB_SNIPPETS[@]}"; do
    [[ -e "${old}" ]] && rm -f -- "${old}"
  done

  KERNEL_GRUB_PATH="$(grub_relpath "${WORKDIR}/vmlinuz")"
  INITRD_GRUB_PATH="$(grub_relpath "${WORKDIR}/initrd.gz")"

  cat > "${GRUB_SNIPPET}" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ENTRY_TITLE}' --id '${ENTRY_ID}' {
    insmod gzio
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    insmod xfs
    insmod btrfs
    search --no-floppy --file --set=root ${KERNEL_GRUB_PATH}
    linux ${KERNEL_GRUB_PATH} auto=true priority=critical interface=${PRESEED_IF} preseed/file=/preseed.cfg ---
    initrd ${INITRD_GRUB_PATH}
}
EOF
  chmod 0755 "${GRUB_SNIPPET}"
}

find_grub_cfg(){
  GRUB_CFG=""
  if [[ -f /boot/grub2/grub.cfg ]]; then
    GRUB_CFG="/boot/grub2/grub.cfg"
  elif [[ -f /boot/grub/grub.cfg ]]; then
    GRUB_CFG="/boot/grub/grub.cfg"
  else
    shopt -s nullglob
    local cands=(/boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg)
    shopt -u nullglob
    local f
    for f in "${cands[@]}"; do
      [[ -f "${f}" ]] || continue
      GRUB_CFG="${f}"
      break
    done
  fi
}

backup_grub_default(){
  [[ -f /etc/default/grub ]] || return 0
  local backup="/etc/default/grub.dd-debian.bak.$(date +%Y%m%d%H%M%S)"
  cp -p /etc/default/grub "${backup}"
  log "Backed up /etc/default/grub to ${backup}"
}

set_grub_default_line(){
  local key="$1"
  local value="$2"
  local file="/etc/default/grub"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

ensure_grub_saved_default(){
  [[ -f /etc/default/grub ]] || return 0
  backup_grub_default
  set_grub_default_line "GRUB_DEFAULT" "saved"
  set_grub_default_line "GRUB_SAVEDEFAULT" "false"
}

update_grub_config(){
  find_grub_cfg
  if need_cmd update-grub; then
    update-grub
  elif need_cmd grub2-mkconfig; then
    [[ -n "${GRUB_CFG}" ]] || GRUB_CFG="/boot/grub2/grub.cfg"
    grub2-mkconfig -o "${GRUB_CFG}"
  elif need_cmd grub-mkconfig; then
    [[ -n "${GRUB_CFG}" ]] || GRUB_CFG="/boot/grub/grub.cfg"
    grub-mkconfig -o "${GRUB_CFG}"
  else
    die "Cannot find GRUB update command"
  fi
}

set_next_boot(){
  if need_cmd grub-reboot && grub-reboot "${ENTRY_ID}"; then
    BOOT_MODE="one-time"
    return
  fi
  if need_cmd grub2-reboot && grub2-reboot "${ENTRY_ID}"; then
    BOOT_MODE="one-time"
    return
  fi

  warn "grub-reboot unavailable or failed; falling back to saved default"
  if need_cmd grub-set-default && grub-set-default "${ENTRY_ID}"; then
    BOOT_MODE="saved-default"
    return
  fi
  if need_cmd grub2-set-default && grub2-set-default "${ENTRY_ID}"; then
    BOOT_MODE="saved-default"
    return
  fi

  warn "grub-set-default unavailable or failed; falling back to persistent GRUB_DEFAULT title"
  if [[ -f /etc/default/grub ]]; then
    set_grub_default_line "GRUB_DEFAULT" "\"${ENTRY_TITLE}\""
    update_grub_config
    BOOT_MODE="persistent-title"
    return
  fi

  die "Cannot set next boot entry"
}

print_plan(){
  cat <<EOF
========================================
VPS Debian reinstall plan
Script: ${SCRIPT_NAME} ${SCRIPT_VERSION}
Target Debian: ${DEBIAN_VERSION} (${DEBIAN_SUITE})
Installer download mirror: ${DEBIAN_MIRROR}
Installer package protocol: ${INSTALLER_MIRROR_PROTOCOL}
Arch: ${ARCH}
Firmware: ${BOOT_FIRMWARE}
Disk to erase: ${INSTALL_DISK}
Network: ${IP_ADDR}/${CIDR} netmask ${NETMASK}
Gateway: ${GATEWAY}
DNS: ${DNS}
Detected interface: ${DETECTED_IF}
Installer interface: ${PRESEED_IF}
Hostname: ${HOSTNAME_NEW}
Timezone: ${TIMEZONE}
========================================
EOF
}

confirm_action(){
  print_plan
  cat <<EOF
WARNING: All data on ${INSTALL_DISK} will be erased.
Make sure provider console/VNC access is available before rebooting.
EOF

  if [[ "${AUTO_YES}" -eq 1 ]]; then
    return
  fi

  local ans
  read -r -p "Type YES to continue: " ans
  [[ "${ans}" == "YES" ]] || die "Cancelled"
}

run_self_test(){
  local old_version old_hostname old_timezone old_dns
  old_version="${DEBIAN_VERSION}"
  old_hostname="${HOSTNAME_NEW}"
  old_timezone="${TIMEZONE}"
  old_dns="${DNS}"

  DEBIAN_VERSION=12
  HOSTNAME_NEW=""
  configure_release
  [[ "${DEBIAN_SUITE}" == "bookworm" ]] || die "self-test: Debian 12 suite mapping failed"
  [[ "${HOSTNAME_NEW}" == "debian12" ]] || die "self-test: Debian 12 default hostname failed"
  [[ "$(cidr_to_mask 24)" == "255.255.255.0" ]] || die "self-test: /24 netmask failed"
  [[ "$(cidr_to_mask 32)" == "255.255.255.255" ]] || die "self-test: /32 netmask failed"
  valid_ipv4 "203.0.113.10" || die "self-test: valid IPv4 rejected"
  ! valid_ipv4 "999.0.0.1" || die "self-test: invalid IPv4 accepted"
  validate_hostname "debian-test"
  TIMEZONE="UTC"
  validate_timezone
  normalize_dns "1.1.1.1,8.8.8.8"
  [[ "${DNS}" == "1.1.1.1 8.8.8.8" ]] || die "self-test: DNS normalization failed"

  DEBIAN_VERSION=13
  HOSTNAME_NEW=""
  configure_release
  [[ "${DEBIAN_SUITE}" == "trixie" ]] || die "self-test: Debian 13 suite mapping failed"
  [[ "${HOSTNAME_NEW}" == "debian13" ]] || die "self-test: Debian 13 default hostname failed"

  DEBIAN_VERSION="${old_version}"
  HOSTNAME_NEW="${old_hostname}"
  TIMEZONE="${old_timezone}"
  DNS="${old_dns}"
  log "Self-test passed"
}

reboot_now(){
  sync
  if need_cmd systemctl && systemctl reboot; then
    return
  fi
  reboot
}

main(){
  parse_args "$@"

  if [[ "${SELF_TEST}" -eq 1 ]]; then
    run_self_test
    exit 0
  fi

  configure_release
  log "Script version: ${SCRIPT_VERSION}"
  validate_inputs
  require_root
  detect_arch
  detect_boot_firmware
  install_dependencies
  check_runtime_capabilities
  detect_network
  detect_install_disk

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    print_plan
    exit 0
  fi

  prompt_password
  confirm_action

  download_installer
  generate_preseed
  inject_preseed_into_initrd
  write_grub_entry
  ensure_grub_saved_default
  update_grub_config
  set_next_boot

  log "Ready. Next boot enters Debian ${DEBIAN_VERSION} installer (${BOOT_MODE})."

  if [[ "${AUTO_REBOOT}" -eq 1 ]]; then
    reboot_now
    exit 0
  fi

  local r
  read -r -p "Reboot now to start install? [y/N]: " r
  if [[ "${r}" =~ ^[Yy]$ ]]; then
    reboot_now
  fi
}

main "$@"
