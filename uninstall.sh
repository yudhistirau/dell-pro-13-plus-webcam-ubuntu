#!/usr/bin/env bash
# Remove the webcam fix and return the machine to stock Ubuntu behaviour.
# Note: the webcam will stop working again — that is the stock behaviour.

set -euo pipefail

CVS_PKG=vision-driver;  CVS_VER=1.0.0
OV_PKG=ov05c10-ipu6;    OV_VER=1.0
KREL=$(uname -r)

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] && { echo "Run as a normal user, not root."; exit 1; }

if ! sudo -n true 2>/dev/null; then
    if [ -t 0 ]; then
        sudo -v || { echo "sudo authentication failed"; exit 1; }
    elif [ -n "${SUDO_ASKPASS:-}" ]; then
        sudo -A -v || { echo "sudo authentication failed"; exit 1; }
    else
        echo "No terminal available to read the sudo password."
        echo "Run this script from a normal terminal window."
        exit 1
    fi
fi

say "Removing DKMS packages"
for spec in "$CVS_PKG/$CVS_VER" "$OV_PKG/$OV_VER"; do
    if dkms status "$spec" 2>/dev/null | grep -q .; then
        sudo dkms remove "$spec" --all || true
    else
        echo "    $spec not installed, skipping"
    fi
done

say "Removing sources and any manually installed modules"
sudo rm -rf "/usr/src/$CVS_PKG-$CVS_VER" "/usr/src/$OV_PKG-$OV_VER"
sudo rm -f  "/lib/modules/$KREL/updates/intel_cvs.ko" "/lib/modules/$KREL/updates/ov05c10.ko"
sudo depmod -a

say "Done — reboot to return to the stock stack"
echo "    sudo reboot"
