#!/data/data/com.termux/files/usr/bin/bash

# ============================================================
# uninstall.sh
# Stop battery-charge-limit, restore normal charging and remove
# it from Magisk's service.d.
#
# Usage:
#   bash uninstall.sh
# ============================================================

DEST="/data/adb/service.d/battery-charge-limit.sh"

su -c "[ -f $DEST ] && $DEST stop"
su -c "rm -f $DEST /data/local/tmp/battery-charge-limit.log /data/local/tmp/battery-charge-limit.pid"

echo "[*] Removed. Charging is back to normal."
