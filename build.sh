#!/usr/bin/env bash
# Build a bootable live/installer ISO of the remix.
#
# Run on an x86_64 Linux machine:
#   - On Fedora: runs directly (needs sudo).
#   - On any other Linux with podman or docker: re-runs itself inside a
#     privileged Fedora container.
#
# Settings (environment variables):
#   REMIX_NAME      name shown in the boot menu and Settings > About
#   FEDORA_VERSION  Fedora release to base on
#
#   REMIX_NAME="Nimbus" FEDORA_VERSION=45 ./build.sh
set -euo pipefail

REMIX_NAME="${REMIX_NAME:-Nimbus}"
FEDORA_VERSION="${FEDORA_VERSION:-45}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where the ~20 GB of build files go. Point this at a real disk when building
# from a live USB, e.g. WORK_DIR=/run/media/liveuser/BUILD
WORK_DIR="${WORK_DIR:-$HERE}"
OUT="$WORK_DIR/out"
SLUG="$(printf '%s' "$REMIX_NAME" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
VOLID="$(printf '%s' "$SLUG" | tr '[:lower:]-' '[:upper:]_' | cut -c1-24)_$FEDORA_VERSION"
ISO_NAME="$SLUG-$FEDORA_VERSION-x86_64.iso"

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == Linux ]] || die "build on x86_64 Linux (a Fedora machine is easiest). macOS can't build this ISO."
[[ "$(uname -m)" == x86_64 ]] || die "this is a $(uname -m) machine; the ISO targets x86_64 PCs, so build on one."

is_fedora() { grep -qx 'ID=fedora' /etc/os-release 2>/dev/null; }

# Not on Fedora (and not already inside our container): hop into a container.
if ! is_fedora && [[ -z "${IN_REMIX_CONTAINER:-}" ]]; then
  engine="$(command -v podman || command -v docker || true)"
  [[ -n "$engine" ]] || die "not on Fedora and neither podman nor docker is installed."
  echo ">> Building inside registry.fedoraproject.org/fedora:$FEDORA_VERSION via $engine"
  exec sudo "$engine" run --rm --privileged \
    -v /dev:/dev \
    -v "$HERE":/work:Z -w /work \
    -e IN_REMIX_CONTAINER=1 -e REMIX_NAME="$REMIX_NAME" -e FEDORA_VERSION="$FEDORA_VERSION" \
    "registry.fedoraproject.org/fedora:$FEDORA_VERSION" bash ./build.sh
fi

SUDO=""; [[ $EUID -eq 0 ]] || SUDO="sudo"

# Space check. A live USB session keeps files in RAM, which can't hold the build.
mkdir -p "$WORK_DIR"
fstype="$(findmnt -no FSTYPE --target "$WORK_DIR" 2>/dev/null || true)"
case "$fstype" in
  tmpfs|overlay|squashfs)
    die "$WORK_DIR is in memory ($fstype), not on a disk. Plug in a drive formatted as ext4 and run:
  WORK_DIR=/run/media/\$USER/<drive name> ./build.sh" ;;
  vfat|exfat|msdos)
    die "$WORK_DIR is on a $fstype drive, which can't hold Linux build files. Reformat it as ext4 in the Disks app." ;;
esac
free_gb=$(( $(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}') / 1024 / 1024 ))
(( free_gb >= 20 )) || die "only ${free_gb} GB free in $WORK_DIR; the build needs about 20 GB."
echo ">> Building in $WORK_DIR ($free_gb GB free)"

echo ">> Installing build tools (lorax / livemedia-creator)"
$SUDO dnf -y install lorax lorax-lmc-novirt pykickstart

echo ">> Rendering kickstart for $REMIX_NAME (Fedora $FEDORA_VERSION base)"
KS="$HERE/remix-$FEDORA_VERSION.ks"
sed -e "s/@FEDORA_VERSION@/$FEDORA_VERSION/g" \
    -e "s/@REMIX_NAME@/$REMIX_NAME/g" \
    "$HERE/remix.ks.in" > "$KS"
ksflatten -c "$KS" -o "$HERE/remix-flat.ks"
ksvalidator "$HERE/remix-flat.ks"

# livemedia-creator --no-virt runs Anaconda on this host; SELinux enforcing
# breaks it. Put it back afterwards.
restore_selinux=0
if command -v getenforce >/dev/null && [[ "$(getenforce)" == Enforcing ]]; then
  $SUDO setenforce 0; restore_selinux=1
fi
trap '[[ $restore_selinux == 1 ]] && $SUDO setenforce 1 || true' EXIT

$SUDO mkdir -p "$WORK_DIR/tmp"
echo ">> Building ISO (20-60 min, downloads ~3 GB)"
# Package mirrors sometimes fail to answer, which stops the installer with
# "Error setting up repositories". Retry that case up to 3 times.
attempt=1
while :; do
  $SUDO rm -rf "$OUT"
  $SUDO rm -f "$WORK_DIR/lmc.log"
  if $SUDO livemedia-creator \
      --ks "$HERE/remix-flat.ks" \
      --no-virt \
      --make-iso \
      --iso-only \
      --iso-name "$ISO_NAME" \
      --project "$REMIX_NAME" \
      --releasever "$FEDORA_VERSION" \
      --volid "$VOLID" \
      --resultdir "$OUT" \
      --tmp "$WORK_DIR/tmp" \
      --logfile "$WORK_DIR/lmc.log"; then
    break
  fi
  if (( attempt < 3 )) && grep -q "Error setting up repositories" "$WORK_DIR/lmc.log"; then
    echo ">> Package mirrors didn't respond (attempt $attempt of 3). Retrying in 60 s."
    attempt=$((attempt + 1))
    sleep 60
    continue
  fi
  die "the ISO build failed. Logs: $WORK_DIR/lmc.log and $WORK_DIR/anaconda/"
done

echo
echo ">> Done: $OUT/$ISO_NAME"
echo "   Write it to a USB stick with Fedora Media Writer, balenaEtcher, or:"
echo "   sudo dd if=$OUT/$ISO_NAME of=/dev/sdX bs=4M status=progress oflag=sync"
