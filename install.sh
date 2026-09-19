#!/data/data/com.termux/files/usr/bin/bash

# ============================================================
# install.sh
# Run this from Termux (with root/Magisk already set up) to
# install battery-charge-limit.sh into Magisk's service.d.
#
# Usage:
#   bash install.sh
# ============================================================

set -e

SRC="$(dirname "$0")/scripts/battery-charge-limit.sh"
DEST="/data/adb/service.d/battery-charge-limit.sh"

if [ ! -f "$SRC" ]; then
    echo "[!] scripts/battery-charge-limit.sh not found. Run this from the repo root."
    exit 1
fi

echo "[*] This will copy the script to $DEST (needs root)."
echo "[*] Edit scripts/battery-charge-limit.sh FIRST to set STOP_AT/RESUME_AT"
echo "    if you haven't already."
read -p "Continue? [y/N] " CONFIRM

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

su -c "mkdir -p /data/adb/service.d"
cat "$SRC" | su -c "cat > $DEST"
su -c "chmod 755 $DEST"

echo "[*] Installed."
read -p "Start it now without rebooting? [y/N] " NOW

if [ "$NOW" = "y" ] || [ "$NOW" = "Y" ]; then
    su -c "$DEST stop" >/dev/null 2>&1 || true
    su -c "nohup $DEST run >/dev/null 2>&1 &"
    echo "[*] Started."
fi

echo "[*] Check the state with:"
echo "    su -c '$DEST status'"
echo "[*] Full log:"
echo "    su -c 'cat /data/local/tmp/battery-charge-limit.log'"
