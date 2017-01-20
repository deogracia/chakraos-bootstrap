#!/bin/bash
#
# chakra-bootstrap: Bootstrap a base Chakra system using any GNU distribution.
#
# Dependencies: bash >= 4, coreutils, wget, sed, gawk, tar, gzip, chroot, xz.
# Project: https://github.com/deogracia/chakraos-bootstrap
#
# Install:
#
#   # install -m 755 chakra-bootstrap.sh /usr/local/bin/chakra-bootstrap
#
# Usage:
#
#   # chakra-bootstrap destination
#   # chakra-bootstrap -a x86_64 -r ftp://ftp.archlinux.org destination-64
#
# And then you can chroot to the destination directory (user: root, password: root):
#
#   # chroot destination

set -e -u -o pipefail

# Packages needed by pacman (see get-pacman-dependencies.sh)
CORE_PACKAGES=(
  acl attr bash bzip2 chakra-signatures coreutils curl e2fsprogs expat file filesystem gcc-libs 
  glibc gawk gpgme gpm grep icu krb5 keyutils libarchive libassuan libcap libgpg-error libidn libssh2 
  linux-api-headers lz4 lzo2 ncurses nettle openssl pacman pacman-mirrorlist readline 
  sed systemd tar tzdata xz zlib
)
BASIC_PACKAGES=( 
  vim
)

DEFAULT_REPO_URL="https://rsync.chakralinux.org/packages"

stderr() { 
  echo "$@" >&2 
}

debug() {
  stderr "--- $@"
}

extract_href() {
  sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\)".*$/\1/p'
}

fetch() {
  curl -s "$@"
  debug curl -s "$@"
}

uncompress() {
  local FILEPATH=$1 DEST=$2
  
  case "$FILEPATH" in
    *.gz) tar xzf "$FILEPATH" -C "$DEST";;
    *.xz) xz -dc "$FILEPATH" | tar x -C "$DEST";;
    *) debug "Error: unknown package format: $FILEPATH"
       return 1;;
  esac
}  

###
get_default_repo() {
  echo $DEFAULT_REPO_URL
}

get_template_repo_url() {
  # param
  # $1: repo's URL ( https://rsync.chakralinux.org/packages/ )
  # $2: group ( core|desktop|gtk|lib32)
  # $3: arch
  local REPO_URL=$1 GROUP=$2 ARCH=$3
  debug  "get_template_repo_url: ${REPO_URL}/${GROUP}/${ARCH}"
  echo "${REPO_URL}/${GROUP}/${ARCH}"
}

get_core_repo_url() {
  # param
  # $1: repo's URL ( https://rsync.chakralinux.org/packages/ )
  # $2: arch
  local REPO_URL=$1 ARCH=$2
  get_template_repo_url ${REPO_URL} "core" ${ARCH}
}

configure_pacman() {
  local DEST=$1 ARCH=$2
  debug "configure DNS and pacman"
  sudo cp "/etc/resolv.conf" "$DEST/etc/resolv.conf"
  SERVER=$(get_template_repo_url "$REPO_URL" '$repo'  "$ARCH")
  echo "Server = $SERVER" >> "$DEST/etc/pacman.d/mirrorlist"
}

configure_minimal_system() {
  local DEST=$1
  
  mkdir -p "$DEST/dev"
  echo "root:x:0:0:root:/root:/bin/bash" > "$DEST/etc/passwd" 
  echo 'root:$1$GT9AUpJe$oXANVIjIzcnmOpY07iaGi/:14657::::::' > "$DEST/etc/shadow"
  touch "$DEST/etc/group"
  echo "bootstrap" > "$DEST/etc/hostname"
  
  test -e "$DEST/etc/mtab"    || echo "rootfs / rootfs rw 0 0" > "$DEST/etc/mtab"
  test -e "$DEST/dev/null"    || sudo mknod "$DEST/dev/null" c 1 3
  test -e "$DEST/dev/random"  || sudo mknod -m 0644 "$DEST/dev/random" c 1 8
  test -e "$DEST/dev/urandom" || sudo mknod -m 0644 "$DEST/dev/urandom" c 1 9
  
  sed -i "s/^[[:space:]]*\(CheckSpace\)/# \1/" "$DEST/etc/pacman.conf"
  sed -i "s/^[[:space:]]*SigLevel[[:space:]]*=.*$/SigLevel = Never/" "$DEST/etc/pacman.conf"
}

fetch_repo_file_list() {
  # param
  # $1 : repo's URL ( https://rsync.chakralinux.org/packages/desktop/x86_64/ )
  # $2 : temp dir
  local repo_url=$1
  local temp_dir=$2
  local bdd_file_name="core.db.tar.gz"
  debug "fetch_repo_file_list ${repo_url}"
  debug "temp dir: ${temp_dir}"
  
  pushd ${temp_dir}
  wget --no-verbose --no-check-certificate ${repo_url}/${bdd_file_name}
  tar xzf ${bdd_file_name}
  rm ${bdd_file_name}
  popd
}

fetch_packages_list() {
  local REPO=$1
  local dl_temp_dir=`mktemp -d`
  debug $REPO
  debug "fetch packages list: $REPO/"

#  fetch_repo_file_list ${REPO} ${dl_temp_dir}
 
  fetch "$REPO/" | extract_href | awk -F"/" '{print $NF}' | sort -rn ||
    { debug "Error: cannot fetch packages list: $REPO"; return 1; }

  rm -rf ${dl_temp_dir} || debug "temp dir already cleaned!"
  debug "temp dir cleaned"
}

install_pacman_packages() {
  local BASIC_PACKAGES=$1 DEST=$2 LIST=$3 DOWNLOAD_DIR=$4
  debug "pacman package and dependencies: $BASIC_PACKAGES"
  
  for PACKAGE in $BASIC_PACKAGES; do
    local FILE=$(echo "$LIST" | grep -m1 "^$PACKAGE-[[:digit:]].*\(\.gz\|\.xz\)$")
    test "$FILE" || { debug "Error: cannot find package: $PACKAGE"; return 1; }
    local FILEPATH="$DOWNLOAD_DIR/$FILE"
    
    debug "download package: $REPO/$FILE"
    fetch -o "$FILEPATH" "$REPO/$FILE"
    debug "uncompress package: $FILEPATH"
    uncompress "$FILEPATH" "$DEST"
  done
}

install_packages() {
  local ARCH=$1 DEST=$2 PACKAGES=$3
  debug "install packages: $PACKAGES"
  sudo LC_ALL=C chroot "$DEST" /usr/bin/pacman \
    --noconfirm --arch $ARCH -Sy --force $PACKAGES
}

fix_perm(){
  # $1: dest dir
  local DIR=$1
  debug "Fix permission"

  sudo chmod 1777 ${DIR}/tmp/
  sudo chmod 775  ${DIR}/var/games/
  sudo chmod 1777 ${DIR}/var/tmp/
  sudo chmod 1777 ${DIR}/var/spool/mail/
}

show_usage() {
  stderr "Usage: $(basename "$0") [-q] [-a i686|x86_64] [-r REPO_URL] [-d DOWNLOAD_DIR] DESTDIR"
}

main() {
  debug "LIO 00"
  # Process arguments and options
  test $# -eq 0 && set -- "-h"
  local ARCH=
  local REPO_URL=
  local DOWNLOAD_DIR=
  
  while getopts "a:r:d:h" ARG; do
    case "$ARG" in
      a) ARCH=$OPTARG;;
      r) REPO_URL=$OPTARG;;
      d) DOWNLOAD_DIR=$OPTARG;;
      *) show_usage; return 1;;
    esac
  done
  shift $(($OPTIND-1))
  test $# -eq 1 || { show_usage; return 1; }

  debug "Lio 01"
  
  [[ -z "$ARCH" ]] && ARCH=$(uname -m)
  [[ -z "$REPO_URL" ]] && REPO_URL=$(get_default_repo "$ARCH")

  debug "Lio 02"
  
  
  local DEST=$1
  local REPO=$(get_core_repo_url "$REPO_URL" "$ARCH")
  debug "REPO: " $REPO
  [[ -z "$DOWNLOAD_DIR" ]] && DOWNLOAD_DIR=$(mktemp -d)
  mkdir -p "$DOWNLOAD_DIR"
  [[ "$DOWNLOAD_DIR" ]] && trap "rm -rf '$DOWNLOAD_DIR'" KILL TERM EXIT

  debug "Lio 03"
  
  debug "destination directory: $DEST"
  debug "core repository: $REPO"
  debug "temporary directory: $DOWNLOAD_DIR"
  
  # Fetch packages, install system and do a minimal configuration
  mkdir -p "$DEST"
  LIST=$(fetch_packages_list $REPO)

  debug install_pacman_packages "${CORE_PACKAGES[*]}" "$DEST" "$LIST" "$DOWNLOAD_DIR"

  debug "Lio 04"
  
  install_pacman_packages "${CORE_PACKAGES[*]}" "$DEST" "$LIST" "$DOWNLOAD_DIR"

  debug "Lio 05"
  
  configure_pacman "$DEST" "$ARCH"

  debug "Lio 06"
  
  configure_minimal_system "$DEST"

  fix_perm "$DEST"

  debug "Lio 07"
  
  install_packages "$ARCH" "$DEST" "${BASIC_PACKAGES[*]}"

  debug "Lio 08"
  
  configure_pacman "$DEST" "$ARCH" # Pacman must be re-configured

  debug "Lio 09"
  
  [[ "$DOWNLOAD_DIR" ]] && rm -rf "$DOWNLOAD_DIR"
  
  debug "done"
}

main "$@"
