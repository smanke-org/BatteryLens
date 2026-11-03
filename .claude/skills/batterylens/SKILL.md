---
name: batterylens
description: Drive BatteryLens, the battery app on this Mac, from the shell with the `batterylens` command: list the Mac's and connected devices' battery levels, charging state and when each was read, show a device's history and time left, rename, hide or forget devices, set low-battery levels and alerts, and read every source again. Use when the user asks about battery levels of their Mac, mouse, keyboard, earbuds or other devices, or names BatteryLens.
---

# BatteryLens

`batterylens` runs commands in the BatteryLens app. Changes show in its menu, Settings and the
widget at once. If the app is closed, the command opens it in the background. If `batterylens`
isn't on PATH, use `/Applications/BatteryLens.app/Contents/MacOS/BatteryLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- A device is named by its id (like `bt:aa:bb:cc:11:22:33` or `mac:internal`, from
  `batterylens devices list`) or its name; part of a name works when only one device matches.
- Devices that aren't connected keep their last-known level: check `connected` and `lastRead`.
- `devices forget` only reports what it would forget. Show the user that report and ask before
  you run it again with `--yes`: its name and settings go too.
- `devices refresh` reads every Bluetooth and HID device again; readings arrive over a few seconds.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/batterylens-test`
  in front (a folder holding devices.json); it reads that folder only.

## Main commands

| Command | Does |
| --- | --- |
| `batterylens status --json` | Version, device counts, lowest battery, low and charging devices, sources, permissions |
| `batterylens devices list [--connected] [--kind mouse] --json` | Every device: level, charging, connected, last read |
| `batterylens devices show <device> --json` | Each battery, its source, settings, forecast, estimate |
| `batterylens devices history <device> [--since 7d] --json` | Level changes, newest first |
| `batterylens devices update <device> [--name N] [--hidden] [--low-threshold 15] --json` | Change one |
| `batterylens settings update [--low-alerts] [--low-threshold 20] [--menu-bar-device <device>] --json` | Alert and menu bar settings |

Everything else: `batterylens help`, and `batterylens help <command>` for its options.
