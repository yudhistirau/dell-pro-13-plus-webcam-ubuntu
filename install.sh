#!/usr/bin/env bash
# Install the webcam fix for Dell Pro 13 Plus (PB13250) on Ubuntu 24.04.
#
#   1. intel_cvs      - claims the Intel CVS chip (ACPI INTC10E0) and hands the
#                       sensor to the host, which unblocks ACPI _DEP enumeration
#   2. ov05c10        - patched to expose only the 2800x1576 @ 480 MHz mode
#
# Both are installed through DKMS so they survive kernel updates.

set -euo pipefail

CVS_REPO=https://github.com/intel/vision-drivers.git
CVS_COMMIT=845d6f8bdf66ff1f455901da9de5e00a53a83dce
CVS_PKG=vision-driver
CVS_VER=1.0.0

OV_REPO=https://github.com/NightScript370/ov05c10-ipu6-cvs.git
OV_COMMIT=9f581ca49b8410cd98e3497eadfd6153afdb3615
OV_PKG=ov05c10-ipu6
OV_VER=1.0

KREL=$(uname -r)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && die "Run as a normal user, not root — the script calls sudo itself."

say "Checking hardware"
if ! grep -q . <(ls /sys/bus/acpi/devices/ | grep -i '^INTC10E0' || true); then
    warn "ACPI device INTC10E0 (Intel CVS) not found on this machine."
    warn "This fix is almost certainly not what you need. Continuing anyway in 10s..."
    sleep 10
fi
echo "    kernel : $KREL"
echo "    model  : $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"

say "Requesting sudo access"
# Ask once, up front, so a missing password fails here with a clear message
# instead of halfway through the install. Caching it also keeps every later
# sudo call in this script non-interactive.
if sudo -n true 2>/dev/null; then
    echo "    already authorised"
elif [ -t 0 ]; then
    sudo -v || die "sudo authentication failed"
elif [ -n "${SUDO_ASKPASS:-}" ]; then
    sudo -A -v || die "sudo authentication failed via SUDO_ASKPASS"
else
    die "No terminal available to read the sudo password.

Run this script from a normal terminal window:

    bash $0

Or, for a non-interactive shell, point SUDO_ASKPASS at a graphical helper:

    printf '#!/bin/sh\nexec zenity --password\n' > /tmp/askpass.sh
    chmod +x /tmp/askpass.sh
    SUDO_ASKPASS=/tmp/askpass.sh bash $0"
fi

say "Installing build prerequisites"
sudo apt-get update -qq
sudo apt-get install -y -q build-essential dkms git "linux-headers-$KREL" v4l-utils

say "Removing any previous manual installation"
sudo rm -f "/lib/modules/$KREL/updates/intel_cvs.ko" "/lib/modules/$KREL/updates/ov05c10.ko"
for spec in "$CVS_PKG/$CVS_VER" "$OV_PKG/$OV_VER"; do
    if dkms status "$spec" 2>/dev/null | grep -q .; then
        echo "    removing existing DKMS $spec"
        sudo dkms remove "$spec" --all || true
    fi
done
sudo rm -rf "/usr/src/$CVS_PKG-$CVS_VER" "/usr/src/$OV_PKG-$OV_VER"

say "Fetching intel_cvs (intel/vision-drivers @ ${CVS_COMMIT:0:7})"
git clone -q "$CVS_REPO" "$WORK/vision-drivers"
git -C "$WORK/vision-drivers" checkout -q "$CVS_COMMIT"
sudo cp -a "$WORK/vision-drivers" "/usr/src/$CVS_PKG-$CVS_VER"

say "Fetching patched ov05c10 (NightScript370/ov05c10-ipu6-cvs @ ${OV_COMMIT:0:7})"
git clone -q "$OV_REPO" "$WORK/ov05c10-ref"
git -C "$WORK/ov05c10-ref" checkout -q "$OV_COMMIT"
[ -f "$WORK/ov05c10-ref/drivers/ov05c10/ov05c10.c" ] \
    || die "upstream layout changed: drivers/ov05c10/ov05c10.c not found"
sudo cp -a "$WORK/ov05c10-ref/drivers/ov05c10" "/usr/src/$OV_PKG-$OV_VER"

say "Building and installing via DKMS"
for spec in "$CVS_PKG/$CVS_VER" "$OV_PKG/$OV_VER"; do
    echo "--- $spec"
    sudo dkms add     "$spec"
    sudo dkms build   "$spec"
    sudo dkms install "$spec"
done
sudo depmod -a

say "Checking module autoload wiring"
if grep -qi 'INTC10E0' "/lib/modules/$KREL/modules.alias"; then
    echo "    ok: alias acpi*:INTC10E0:* -> intel_cvs is registered"
else
    warn "alias for INTC10E0 is missing; intel_cvs may not load automatically"
fi

say "Done"
cat <<EOF

DKMS status:
$(dkms status | sed 's/^/    /')

Reboot now, then verify:

    dmesg | grep -i "Transfer of ownership"
    v4l2-ctl -d /dev/v4l-subdev6 --list-ctrls | grep link_frequency   # default=1
    dmesg | grep -ciE "csi2.*error|stream (stop|close) time out"      # expect 0

If Secure Boot is enabled, DKMS asked you to enrol a MOK key — you must confirm
it on the next boot or the modules will refuse to load.
EOF
