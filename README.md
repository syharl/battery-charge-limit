# battery-charge-limit

Stop charging at a set battery level and resume at a lower one — **without unplugging the charger**. Default: stop at 80%, resume at 60%.

Built for phones that stay plugged in for long periods (desk, car, hotspot setups): keeping a lithium battery between 60–80% instead of sitting at 100% is gentler on it over time.

## The problem this solves

Most Android ROMs have no built-in "charge limit" setting. The usual workaround is an app that nags you to unplug at 80%, which defeats the point of leaving the phone plugged in.

This script runs as a root service and flips the kernel's own charging switch (via `/sys/class/power_supply/battery`) when the battery crosses your thresholds. It does not guess which switch your device uses — it **tests each known switch and keeps the one that actually stops charging**.

## Requirements

- **Root access** via Magisk (tested) or KernelSU (should also work — both support `/data/adb/service.d`).
- **Termux** installed on the phone (used to install the script; not needed afterwards).
- A kernel that exposes at least one of these switches in `/sys/class/power_supply/battery/`:
  - `battery_charging_enabled`
  - `charging_enabled`
  - `input_suspend`

### Checking you actually have root

Open Termux and run:

```
su
```

- If a popup appears asking to grant root access, tap **Grant**.
- If you see `su: command not found` or nothing happens, root isn't set up yet.

If it worked, your prompt changes from `$` to `#`. Type `exit` to leave the root shell.

### Checking your phone has a usable switch

```
su -c 'ls /sys/class/power_supply/battery'
```

If you see any of the three files listed above, you're good. (Not seeing one doesn't always mean it won't work — see Troubleshooting.)

## Step-by-step installation

### 1. Get the files onto your phone

**Option A — using `git` (recommended):**

```
pkg install git
git clone https://github.com/syharl/battery-charge-limit.git
cd battery-charge-limit
```

**Option B — download the ZIP manually:**

1. On the GitHub repo page, tap **Code → Download ZIP**.
2. In Termux:

```
termux-setup-storage   # only needed once, grants storage access
cd ~/storage/downloads
unzip battery-charge-limit-main.zip
cd battery-charge-limit-main
```

### 2. Edit the thresholds

```
nano scripts/battery-charge-limit.sh
```

Find these lines near the top:

```
STOP_AT=80          # stop charging when battery >= this %
RESUME_AT=60        # resume charging when battery <= this %
INTERVAL=30         # seconds between checks
SWITCH=""           # leave empty to auto-detect
DETECT_UNPLUG=1     # re-enable charging when the cable is unplugged
WAKELOCK=1          # stay awake while charging so STOP_AT isn't overshot
```

Save with `Ctrl+O`, Enter, then exit with `Ctrl+X`.

### 3. Run the installer

```
bash install.sh
```

This will:

- Ask you to confirm before doing anything (type `y` and Enter).
- Use `su` to copy the script into `/data/adb/service.d/battery-charge-limit.sh` (the folder Magisk automatically runs scripts from after boot).
- Make it executable.
- Offer to start it right away, so you don't have to reboot to try it.

### 4. Check that it works

```
su -c '/data/adb/service.d/battery-charge-limit.sh status'
```

You should see something like:

```
service : running (pid 12345)
battery : 74% (Charging)
temp    : 33 C
--- last log ---
...
```

Plug in the charger and wait until the battery reaches `STOP_AT`. Then check the log:

```
su -c 'cat /data/local/tmp/battery-charge-limit.log'
```

You should see the startup lines followed by the events:

```
1. start: stop=80 resume=60 interval=30s
2. boot_completed
3. switch: auto-detect on first stop
switch charging_enabled did not stop charging, skipped
switch detected: input_suspend (charge=0 stop=1)
paused at 80%
resumed at 60% (capacity)
```

## Commands

Run as root (`su -c '...'` from Termux):

```
battery-charge-limit.sh          # run the loop (this is what boot does)
battery-charge-limit.sh status   # service state, battery, temperature, last log lines
battery-charge-limit.sh stop     # stop the loop and restore normal charging
```

To change the thresholds later: edit `scripts/battery-charge-limit.sh` and run `bash install.sh` again (say `y` to start it now — it restarts the service with the new values).

## Uninstall

```
bash uninstall.sh
```

This stops the service, restores normal charging, and removes the script and its log.

## Which switch gets picked matters

The three switches behave differently:

| Switch | What happens after "stop" |
|---|---|
| `battery_charging_enabled` / `charging_enabled` | Usually only the battery stops charging; the phone keeps running from the charger. The level **holds around `STOP_AT`** and rarely drops to `RESUME_AT`. |
| `input_suspend` | The charger input is cut entirely. The phone runs on the battery, so the level **slowly drops until `RESUME_AT`**, then charging resumes. |

If you want the full 80 → 60 → 80 cycle, force the second one in the script:

```
SWITCH="input_suspend:0:1"
```

The format is `<file>:<value to charge>:<value to stop>`.

## Troubleshooting

**Log shows `no working switch found, retry in 10 min`:** None of the three known switches stopped charging on your device. Your kernel may use a different node, or a vendor daemon is overriding the value. List what you have with `ls /sys/class/power_supply/battery` (also check `ls /sys/class/power_supply/`) and, if you find a candidate, force it with `SWITCH="<file>:<charge>:<stop>"`.

**Log shows `charger detection unreliable here, DETECT_UNPLUG disabled`:** Your device hides the charger while input is suspended, so the script can't tell "unplugged" from "paused". It disabled unplug detection on its own to avoid flapping. Side effect: if you unplug while paused above `RESUME_AT` and plug in again later, charging won't restart until the battery reaches `RESUME_AT`. You can also set `DETECT_UNPLUG=0` yourself.

**Battery goes past `STOP_AT` (e.g. 84%):** The phone probably went into deep sleep between checks. Keep `WAKELOCK=1` and/or lower `INTERVAL`. The wakelock is only held while actively charging, and released while paused.

**Charging doesn't restart after a reboot or crash:** The script restores every known switch to "charging" at startup and whenever it stops. You can also do it by hand with `su -c '/data/adb/service.d/battery-charge-limit.sh stop'`.

**Commands silently do the wrong thing / behave unexpectedly:** If you have BusyBox installed, a bare command in your `PATH` might resolve to BusyBox's own version instead of Android's. The script puts `/system/bin` first in `PATH` for this reason — keep that line if you modify the script.

**Using another charge-control tool:** Don't run this alongside ACC (Advanced Charging Controller) or similar tools — they fight over the same switches. Pick one.

## How it works internally

Placed in `/data/adb/service.d/`, the script is executed by Magisk at the `late_start service` boot stage. It then:

1. Waits for the `sys.boot_completed` system property to become `1`.
2. Writes the "charging on" value to every known switch, so a previous crash can never leave charging disabled.
3. Every `INTERVAL` seconds reads `capacity` and `status` from `/sys/class/power_supply/battery`.
4. When the battery is at or above `STOP_AT` and charging, it stops charging. On the first stop it auto-detects the switch: it writes the "stop" value to each candidate in turn, waits 5 seconds, and keeps the first one that changes `status` away from `Charging`.
5. While paused, it resumes charging when the battery reaches `RESUME_AT`, or immediately if the charger is unplugged.
6. On exit (`stop`, `SIGTERM`, `SIGINT`), it restores charging and releases the wakelock.

Only events are logged (with timestamps) to `/data/local/tmp/battery-charge-limit.log` — not every check — so the file stays tiny.

## Disclaimer

This writes to kernel power-supply nodes on a rooted phone. Behaviour differs between devices and kernels, so a basic understanding of what you're doing is expected. Start with the default thresholds and confirm in the log that it behaves as described before relying on it.

## License

This project is released under the **MIT License**.

- ✅ You can use, copy, modify, and share this code — for personal or commercial projects.
- ⚠️ Keep the original copyright notice and license text in your copy (that's what the `LICENSE` file is for).
- 🚫 No warranty — use at your own risk.

See the full legal text in [LICENSE](LICENSE).
