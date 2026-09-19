#!/system/bin/sh

# ============================================================
# battery-charge-limit.sh
# Stop charging at STOP_AT% and resume at RESUME_AT% while the
# charger stays plugged in. Runs as a Magisk/KernelSU service.
#
# Usage (as root):
#   battery-charge-limit.sh          run the loop (default)
#   battery-charge-limit.sh status   show state + recent log
#   battery-charge-limit.sh stop     stop the loop, restore charging
# ============================================================

# ---------------------- EDIT THESE ----------------------
STOP_AT=80          # stop charging when battery >= this %
RESUME_AT=60        # resume charging when battery <= this %
INTERVAL=30         # seconds between checks

# Charging switch. Leave empty to auto-detect, or force one:
#   format "<file>:<value to charge>:<value to stop>"
#   e.g.   "input_suspend:0:1"
SWITCH=""

DETECT_UNPLUG=1     # 1 = re-enable charging when the cable is unplugged
WAKELOCK=1          # 1 = stay awake while charging so STOP_AT isn't overshot
# --------------------------------------------------------

export PATH=/system/bin:/system/xbin:$PATH

PSY="${PSY:-/sys/class/power_supply}"
BATT="${BATT:-$PSY/battery}"
LOG="${LOG:-/data/local/tmp/battery-charge-limit.log}"
PIDFILE="${PIDFILE:-/data/local/tmp/battery-charge-limit.pid}"
WL_NAME="battery-charge-limit"

# Known switches, "<file>:<charge>:<stop>" -- tried in this order.
CANDIDATES="battery_charging_enabled:1:0 charging_enabled:1:0 input_suspend:0:1"

SW_FILE=""; SW_ON=""; SW_OFF=""
PAUSED=0
NEXT_TRY=0

# ---------------------- helpers ----------------------

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
rd()  { cat "$1" 2>/dev/null; }
wr()  { echo "$1" > "$2"; } 2>/dev/null   # wr <value> <file>, errors silenced
nap() { sleep "$INTERVAL" & wait $!; }

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

is_charging() {
    case "$(rd "$BATT/status")" in
        Charging|Full) return 0 ;;
    esac
    return 1
}

charger_present() {
    for d in "$PSY"/*; do
        case "$(rd "$d/type")" in
            Battery|BMS|UPS|"") continue ;;
        esac
        if [ -f "$d/present" ]; then v="$(rd "$d/present")"; else v="$(rd "$d/online")"; fi
        [ "$v" = "1" ] && return 0
    done
    return 1
}

wl_hold()    { [ "$WAKELOCK" = "1" ] && wr "$WL_NAME" /sys/power/wake_lock; }
wl_release() { wr "$WL_NAME" /sys/power/wake_unlock; }

# ---------------------- switch control ----------------------

# Write the "charge" value to every known switch (safe default state).
restore_all() {
    for c in $CANDIDATES $SWITCH; do
        f="${c%%:*}"; r="${c#*:}"; on="${r%%:*}"
        [ -f "$BATT/$f" ] && wr "$on" "$BATT/$f"
    done
}

charge_on()  { wr "$SW_ON"  "$BATT/$SW_FILE"; }
charge_off() { wr "$SW_OFF" "$BATT/$SW_FILE"; }

# Find a switch that really stops charging. Only valid while charging,
# otherwise "Discharging" would make every switch look like it works.
# On success charging is left OFF.
detect_switch() {
    is_charging || return 1
    for c in $CANDIDATES; do
        f="${c%%:*}"; r="${c#*:}"; on="${r%%:*}"; off="${r#*:}"
        [ -f "$BATT/$f" ] || continue
        wr "$off" "$BATT/$f"
        sleep 5
        if ! is_charging; then
            SW_FILE="$f"; SW_ON="$on"; SW_OFF="$off"
            log "switch detected: $f (charge=$on stop=$off)"
            return 0
        fi
        wr "$on" "$BATT/$f"
        log "switch $f did not stop charging, skipped"
    done
    return 1
}

pause_charging() {
    if [ -z "$SW_FILE" ]; then
        now="$(date +%s)"
        [ "$now" -lt "$NEXT_TRY" ] && return 1
        if ! detect_switch; then
            NEXT_TRY=$((now + 600))
            log "no working switch found, retry in 10 min"
            return 1
        fi
    else
        charge_off
    fi
    PAUSED=1
    log "paused at ${cap}%"
}

resume_charging() {
    charge_on
    PAUSED=0
    log "resumed at ${cap}% ($1)"
    if [ "$1" = "unplugged" ]; then
        # If charging comes right back, the cable was never unplugged:
        # this device hides the charger while input is suspended.
        sleep 5
        if is_charging; then
            DETECT_UNPLUG=0
            log "charger detection unreliable here, DETECT_UNPLUG disabled"
        fi
    fi
}

# ---------------------- commands ----------------------

cleanup() {
    restore_all
    wl_release
    rm -f "$PIDFILE"
    log "stopped, charging restored"
}

run() {
    if is_running; then echo "already running (pid $(cat "$PIDFILE"))"; exit 0; fi
    echo $$ > "$PIDFILE"
    trap cleanup EXIT
    trap 'exit 0' INT TERM

    [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 102400 ] && : > "$LOG"
    log "1. start: stop=$STOP_AT resume=$RESUME_AT interval=${INTERVAL}s"

    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
    log "2. boot_completed"

    restore_all
    if [ -n "$SWITCH" ]; then
        SW_FILE="${SWITCH%%:*}"; r="${SWITCH#*:}"
        SW_ON="${r%%:*}"; SW_OFF="${r#*:}"
        log "3. switch forced: $SW_FILE (charge=$SW_ON stop=$SW_OFF)"
    else
        log "3. switch: auto-detect on first stop"
    fi

    while :; do
        cap="$(rd "$BATT/capacity")"
        [ -z "$cap" ] && { nap; continue; }

        if [ "$PAUSED" = "1" ]; then
            if [ "$cap" -le "$RESUME_AT" ]; then
                resume_charging capacity
            elif [ "$DETECT_UNPLUG" = "1" ] && ! charger_present; then
                resume_charging unplugged
            fi
        elif [ "$cap" -ge "$STOP_AT" ] && is_charging; then
            pause_charging
        fi

        if [ "$PAUSED" = "0" ] && is_charging; then wl_hold; else wl_release; fi
        nap
    done
}

status() {
    if is_running; then echo "service : running (pid $(cat "$PIDFILE"))"; else echo "service : not running"; fi
    echo "battery : $(rd "$BATT/capacity")% ($(rd "$BATT/status"))"
    t="$(rd "$BATT/temp")"; [ -n "$t" ] && echo "temp    : $((t / 10)) C"
    echo "--- last log ---"
    tail -n 8 "$LOG" 2>/dev/null
}

stop() {
    if is_running; then
        kill "$(cat "$PIDFILE")"
        sleep 1
        echo "stopped, charging restored"
    else
        echo "not running"
    fi
    restore_all
    wl_release
}

# ---------------------- main ----------------------

if [ "$(id -u)" != "0" ]; then
    echo "[!] Run as root:  su -c '$0 ${1:-run}'"
    exit 1
fi

case "$1" in
    ""|run) run ;;
    status) status ;;
    stop)   stop ;;
    *)      echo "usage: $0 [run|status|stop]"; exit 1 ;;
esac
