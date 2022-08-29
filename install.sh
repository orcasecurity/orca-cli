#!/bin/sh

# When this option is on, when any command fails (for any of the reasons listed in Consequences of Shell Errors or by
# returning an exit status greater than zero), the shell immediately shall exit,
# as if by executing the exit special built-in utility with no arguments
set -e

# Prefix used for logging
log_prefix() {
	echo "$PREFIX"
}

execute() {
  tmpdir=$(mktmpdir)
  log_debug "downloading files into ${tmpdir}"
  http_download "${tmpdir}/${TARBALL}" "${TARBALL_URL}"
  http_download "${tmpdir}/${CHECKSUM}" "${CHECKSUM_URL}"
  hash_sha256_verify "${tmpdir}/${TARBALL}" "${tmpdir}/${CHECKSUM}"
  srcdir="${tmpdir}"
  (cd "${tmpdir}" && untar "${TARBALL}")
  test ! -d "${BINDIR}" && install -d "${BINDIR}"
  binexe="orca-cli"
  if [ "$OS" = "windows" ]; then
    binexe="${binexe}.exe"
  fi
  install "${srcdir}/${binexe}" "${BINDIR}/" 2> /dev/null || sudo install "${srcdir}/${binexe}" "${BINDIR}/"
  log_info "Installed ${BINDIR}/${binexe}"
  if [ "$ORIG_PLATFORM" = "darwin/arm64" ]; then
    log_info "M1 CPU requires Rosseta 2, make sure you have, or install it by running: '/usr/sbin/softwareupdate --install-rosetta'"
  fi

}


#------------------------------------------------------------------------------

is_command() {
  # look for a builtin command
  command -v "$1" >/dev/null
}

untar() {
  tarball=$1
  case "${tarball}" in
    *.tar.gz | *.tgz) tar -xzf "${tarball}" ;;
    *.tar) tar -xf "${tarball}" ;;
    *.zip) unzip "${tarball}" ;;
    *)
      log_err "untar unknown archive format for ${tarball}"
      return 1
      ;;
  esac
}

hash_sha256() {
  TARGET=${1:-/dev/stdin}
  if is_command gsha256sum; then
    hash=$(gsha256sum "$TARGET") || return 1
    echo "$hash" | cut -d ' ' -f 1
  elif is_command sha256sum; then
    hash=$(sha256sum "$TARGET") || return 1
    echo "$hash" | cut -d ' ' -f 1
  elif is_command shasum; then
    hash=$(shasum -a 256 "$TARGET" 2>/dev/null) || return 1
    echo "$hash" | cut -d ' ' -f 1
  elif is_command openssl; then
    hash=$(openssl -dst openssl dgst -sha256 "$TARGET") || return 1
    echo "$hash" | cut -d ' ' -f a
  else
    log_crit "hash_sha256 unable to find command to compute sha-256 hash"
    return 1
  fi
}
hash_sha256_verify() {
  TARGET=$1
  checksums=$2
  if [ -z "$checksums" ]; then
    log_err "hash_sha256_verify: checksum file not specified"
    return 1
  fi
  BASENAME=${TARGET##*/}

  want=$(grep "${BASENAME}" "${checksums}" 2>/dev/null | tr '\t' ' ' | cut -d ' ' -f 1)
  if [ -z "$want" ]; then
    log_err "hash_sha256_verify: unable to find checksum for '${TARGET}' in '${checksums}'"
    return 1
  fi
  got=$(hash_sha256 "$TARGET")
  if [ "$want" != "$got" ]; then
    log_err "hash_sha256_verify: checksum for '$TARGET' did not verify ${want} vs $got"
    return 1
  fi
}

#-----------------------TAG to version------------------------------------------
mktmpdir() {
  test -z "$TMPDIR" && TMPDIR="$(mktemp -d)"
  mkdir -p "${TMPDIR}"
  echo "${TMPDIR}"
}

http_download_curl() {
  local_file=$1
  source_url=$2
  header=$3
  if [ -z "$header" ]; then
    code=$(curl -w '%{http_code}' -sL -o "$local_file" "$source_url")
  else
    code=$(curl -w '%{http_code}' -sL -H "$header" -o "$local_file" "$source_url")
  fi
  if [ "$code" != "200" ]; then
    log_debug "http_download_curl received HTTP status $code"
    return 1
  fi
  return 0
}

http_download_wget() {
  local_file=$1
  source_url=$2
  header=$3
  if [ -z "$header" ]; then
    wget -q -O "$local_file" "$source_url"
  else
    wget -q --header "$header" -O "$local_file" "$source_url"
  fi
}

http_download() {
  #  $1 = local_file
  #  $2 = source_url
  #  $3 = header
  log_debug "http_download URL: $2"
  if is_command curl; then
    http_download_curl "$@"
    return
  elif is_command wget; then
    http_download_wget "$@"
    return
  fi
  log_crit "Failed to find either wget or curl."
  return 1
}

http_copy() {
  # $1 = URL
  # $2 = HTTP headers
  tmp=$(mktemp)
  http_download "${tmp}" "$1" "$2" || return 1
  body=$(cat "$tmp")
  rm -f "${tmp}"
  echo "$body"
}

github_release() {
  owner_repo=$1
  version=$2

  # in case no version was set , use latest tag
  test -z "$version" && version="latest"
  giturl="https://github.com/${owner_repo}/releases/${version}"
  json=$(http_copy "$giturl" "Accept:application/json")

  # return 1 if no json was obtained
  test -z "$json" && return 1
  version=$(echo "$json" | tr -s '\n' ' ' | sed 's/.*"tag_name":"//' | sed 's/".*//')

  # return 1 if no version was obtained
  test -z "$version" && return 1
  echo "$version"
  log_info "github_release: the extracted version $version"
}

convert_tag_to_version() {
  # Use either the provided TAG or the latest one
  if [ -z "${TAG}" ]; then
    log_info "Checking GitHub for latest tag."
  else
    log_info "Checking GitHub for tag '${TAG}'"
  fi

  # Obtain the desired release tag
  REALTAG=$(github_release "$OWNER/$REPO" "${TAG}") && true
  if test -z "$REALTAG"; then
    log_crit "Unable to find '${TAG}' - use 'latest' or see https://github.com/$OWNER/$REPO/releases for details"
    exit 1
  fi

  TAG="$REALTAG"
  # remove any prefix 'v' to the tag.
  VERSION=${TAG#v}
  log_info "The desired version to download: ${TAG} for ${TAG}/${OS}/${ARCH}"
}

#-----------------------Logging------------------------------------------
echoerr() {
  echo "$@" 1>&2
}

log_prefix() {
  echo "$0"
}
_logp=6

log_set_priority() {
  _logp="$1"
}

log_priority() {
  if test -z "$1"; then
    echo "$_logp"
    return
  fi
  [ "$1" -le "$_logp" ]
}

log_tag() {
  case $1 in
    0) echo "emerg" ;;
    1) echo "alert" ;;
    2) echo "crit" ;;
    3) echo "err" ;;
    4) echo "warning" ;;
    5) echo "notice" ;;
    6) echo "info" ;;
    7) echo "debug" ;;
    *) echo "$1" ;;
  esac
}

log_debug() {
  log_priority 7 || return 0
  echoerr "$(log_prefix)" "$(log_tag 7)" "$@"
}

log_info() {
  log_priority 6 || return 0
  echoerr "$(log_prefix)" "$(log_tag 6)" "$@"
}

log_err() {
  log_priority 3 || return 0
  echoerr "$(log_prefix)" "$(log_tag 3)" "$@"
}

log_crit() {
  log_priority 2 || return 0
  echoerr "$(log_prefix)" "$(log_tag 2)" "$@"
}

#-----------------------ARGS & Usage---------------------------------------
usage() {
  this=$1
  cat <<EOF
$this: Orca Security Cli binary downloader

Usage: $this [-b] bin_dir [-d] [tag]	[-x]
  -b set bin_dir or installation directory, Default: /usr/local/bin
  -d Turn on debug logging
   [tag] A tag from https://github.com/orcasecurity/orca-cli/releases
         In case a tag is missing, latest tag will be used.
  -x enables a mode of the shell where all executed commands are printed to the terminal.

EOF
  exit 2
}

parse_args() {
  # BINDIR default value is /usr/local/bin unless set be ENV
  # or over-ridden by flag below

  BINDIR=${BINDIR:-/usr/local/bin}
  while getopts "b:dh?x" arg; do
    case "$arg" in
      b) BINDIR="$OPTARG" ;;
      d) log_set_priority 10 ;;
      h | \?) usage "$0" ;;
      x) set -x ;;
    esac
  done

  #OPTIND gives the position of the next command line argument.
  # Shift to get the next arg
  shift $((OPTIND - 1))
  TAG=$1
}

# ----------------OS & ARCH validations------------------------------------
get_os() {
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$os" in
    cygwin_nt*) os="windows" ;;
    mingw*) os="windows" ;;
    msys_nt*) os="windows" ;;
  esac
  log_info "Discovered os: $os"
  echo "$os"
}

get_arch() {
  arch=$(uname -m)
  case $arch in
    x86_64) arch="amd64" ;;
    x86) arch="386" ;;
    i686) arch="386" ;;
    i386) arch="386" ;;
    aarch64) arch="arm64" ;;
    armv5*) arch="armv5" ;;
    armv6*) arch="armv6" ;;
    armv7*) arch="armv7" ;;
  esac
  log_info "Discovered architecture: ${arch}"
  echo ${arch}
}

os_check() {
  os=$OS
  case "$os" in
    darwin) return 0 ;;
    dragonfly) return 0 ;;
    freebsd) return 0 ;;
    linux) return 0 ;;
    android) return 0 ;;
    nacl) return 0 ;;
    netbsd) return 0 ;;
    openbsd) return 0 ;;
    plan9) return 0 ;;
    solaris) return 0 ;;
    windows) return 0 ;;
  esac
  log_crit "os_check: '$(uname -s)' got converted to '$os', which is not a supported GOOS value. Please file a report to Orca Security support."
  return 1
}

arch_check() {
  arch=$ARCH
  case "$arch" in
    386) return 0 ;;
    amd64) return 0 ;;
    arm64) return 0 ;;
    armv5) return 0 ;;
    armv6) return 0 ;;
    armv7) return 0 ;;
    ppc64) return 0 ;;
    ppc64le) return 0 ;;
    mips) return 0 ;;
    mipsle) return 0 ;;
    mips64) return 0 ;;
    mips64le) return 0 ;;
    s390x) return 0 ;;
    amd64p32) return 0 ;;
  esac
  log_crit "Architecture check: '$(uname -m)' got converted to '$arch', which is not a supported GOARCH value. Please file a report to Orca Security support."
  return 1
}

is_supported_platform() {
  platform=$1
  supported=1
  case "$platform" in
    darwin/amd64) supported=0 ;;
    darwin/arm64) supported=0 ;;
    linux/amd64) supported=0 ;;
    linux/arm64) supported=0 ;;
  esac

  return $supported
}

check_platform() {
  if is_supported_platform "$PLATFORM"; then
    true
  else
    log_crit "Platform check: Platform $PLATFORM is not supported. For more information please follow the documentation or contact Orca Security support for assistance."
    exit 1
  fi
  log_info "Platform check: Platform $PLATFORM is supported"
}

adjust_format() {
  # change format (tar.gz or zip) based on OS
  case ${OS} in
    windows) FORMAT=zip ;;
  esac
  true
}
# -------------------------------------------------------------------------
# Var
PROJECT_NAME="orca-cli"
OWNER="orcasecurity"
REPO="orca-cli"
FORMAT=tar.gz

# Obtain platform and architecture
OS=$(get_os)
ARCH=$(get_arch)
PREFIX="Orca-Cli"

PLATFORM="${OS}/${ARCH}"
ORIG_PLATFORM="$PLATFORM"
GITHUB_DOWNLOAD=https://github.com/orcasecurity/orca-cli/releases/download


function main(){
  #Validate os and architecture
  os_check "$OS"
  arch_check "$ARCH"

  parse_args "$@"
  check_platform

  convert_tag_to_version
  adjust_format

  NAME=${PROJECT_NAME}_${VERSION}_${OS}_${ARCH}
  TARBALL=${NAME}.${FORMAT}
  TARBALL_URL=${GITHUB_DOWNLOAD}/${TAG}/${TARBALL}
  CHECKSUM=${PROJECT_NAME}_${VERSION}_checksums.txt
  CHECKSUM_URL=${GITHUB_DOWNLOAD}/${TAG}/${CHECKSUM}

  execute
}

main "${@}"

