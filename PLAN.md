# BatteryLens — plan

A menu bar app plus desktop widget that shows the battery of every battery-powered
device connected to the Mac (mice, keyboards, headphones, headsets, controllers),
including the ones Apple's Batteries widget leaves out. Free, public, notarized DMG at
smanke-org/BatteryLens, like the other apps.

Source survey done with `BatteryProbe/` (2026-10-29); its findings decide the design.

## What we know can be read

| Source | Covers | Permission |
|---|---|---|
| Private power-source list (`IOPSCopyPowerSourcesByType(0)`, what `pmset -g accps` uses) | Mac, Apple and Bluetooth LE accessories, AirPods + case, likely many HFP headphones | none |
| `system_profiler SPBluetoothDataType` | AirPods/Beats left, right, case; keeps last levels after disconnecting | none |
| Bluetooth LE Battery Service (0x180F) | most BLE mice, keyboards, many headphones | Bluetooth |
| Logitech HID++ 2.0 | MX devices over Bluetooth and Bolt/Unifying receivers, Logitech G (Lightspeed); exact %, charging state | Input Monitoring |
| HID Battery Strength usage | keyboards/mice that send it | Input Monitoring |
| GameController | Xbox, PlayStation, Switch controllers | none |
| Vendor headset protocols | SteelSeries, Corsair, HyperX etc. dongles; per model | Input Monitoring (some none) |
| Usage estimate | devices that report nothing (the Matias keyboard) | Input Monitoring |

Every permission is optional: the app works with none and explains what each one adds.

## Architecture

```
BatteryLens.app            menu bar host, Developer ID, not sandboxed
├─ BatteryLensKit (SPM)    sources, merging, store, estimator — all logic + tests
├─ BatteryLensWidget.appex WidgetKit extension (sandboxed; WidgetKit requires it)
└─ Helpers/                none planned
App Group 32CWL275JJ.com.smanke.BatteryLens   snapshot.json the widget reads
```

- **Sources** each implement one protocol and push `Reading`s (device key, part, percent,
  charging, source, time). They're event-driven where possible: power-source change
  notifications, BLE notify on 0x2A19, HID++ battery events, HID input reports,
  GameController notifications; system_profiler polled every 5 min.
- **Device registry** merges readings for one physical device that arrive under different
  names ("MX Master 4 M" from the power list, "MX Master 4 for Mac" from HID++, a BLE
  UUID). Key on the Bluetooth address / Logitech unit ID where available, name matching
  as fallback. Picks the best reading per device by source priority and freshness. This
  is the trickiest part, so it gets thorough unit tests.
- **Store** keeps last-known levels (shown dimmed with their age when disconnected),
  charge history, and per-device settings. Writes `snapshot.json` to the App Group and
  asks WidgetKit to reload only on meaningful changes (a 5% step, connect/disconnect,
  charging change), to stay within the reload budget.
- **Estimator** for silent devices: you mark "Charged", the app counts active typing time
  from the device's own reports, learns the drain rate over one or two charges, and shows
  "~60% est." Any real reading always replaces an estimate.

## Features

**Menu bar**: icon shows the lowest battery (or a chosen device); the menu lists all
devices with level, charging, and last-seen age for disconnected ones.

**Widget** (desktop and Notification Center; small, medium, large, extra large):
- Style per widget: **rings** (like Apple's) or **bars with numbers**, chosen when editing.
- Devices: all connected, or picked ones; option to include disconnected ones.
- Interactive "Mark charged" button for estimated devices.

**Per-device settings**: rename, hide, low-battery threshold, and **"Report this
device" on/off**. For the shared Matias keyboard, turning reporting off stops its estimate
and removes it from the widget. When it's used on several of your Macs running BatteryLens,
typing time is added up across them through iCloud so the estimate stays right; use on an
iPad or another computer can't be counted, which is when you'd turn reporting off.

**Alerts**: low-battery notification once per discharge (default 20%, per device),
optional "fully charged" notification.

**History**: per-device charge chart (step interpolation, not smooth curves) and a
time-remaining estimate from the recent drain rate.

**Usual app setup**: Appearance switch, Show in Dock / menu bar options, Dock-menu
Settings, Help (⌘?), auto-updater with interval, settings sync, ToolHUD menu hub,
`batterylens://` URLs, README in the standard layout, release scripts, site page.

## Phases

1. **Foundation and the risky parts first.** XcodeGen project with app, Kit, and widget
   targets. Port the probe's sources into the Kit as live, event-driven sources. Prove
   early that a Developer ID host app and the sandboxed widget share the App Group
   container (macOS 15+ is strict about group IDs), and measure how often the widget
   really reloads from a menu bar app.
2. **Device registry and store**: merging, last-known levels, snapshot for the widget.
3. **Menu bar app**: device list, per-device settings, permissions onboarding, alerts.
4. **Widget**: rings and bars styles, all sizes, configuration, interactive button.
5. **More devices**: Logitech receivers (HID++ slots 1–6), game controllers, your non-Apple
   headphones and gaming headset dongles. Headset protocols are per model; the open-source
   HeadsetControl project (GPL-3.0) is a protocol reference only, no code copied.
   Each device is verified with BatteryProbe first.
6. **Matias estimate**: typing-time counter, "Mark charged", learned drain rate, cross-Mac
   usage sync, "Report this device" switch.
7. **History and time remaining.**
8. **Polish and release**: the usual app setup above, Help text, README, notarized DMG,
   site page; first public release as a beta.

## Still needed from you

- Exact models of the non-Apple headphones, the gaming headset, and the controllers, and
  whether the Logitech receiver is Bolt or Unifying. Then connect each one and run
  `BatteryProbe/run.sh` so we know what it reports before writing code for it.
- Name: BatteryLens, to match the Lens apps?

## Risks

- **Widget reload budget**: WidgetKit limits background reloads; the widget shows each
  level's age, so a late reload is visible rather than misleading.
- **Undocumented calls**: the private power-source list and IOBluetooth getters could change
  in a macOS update; every source is independent, so losing one degrades rather than breaks.
- **Headset protocols**: some vendors' dongles may not be readable at all.
- **App Store**: the private power-source call and HID access rule out a Mac App Store
  version; this is a Developer ID app.
