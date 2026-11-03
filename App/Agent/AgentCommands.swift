import AppKit
import BatteryLensKit
import BatteryLensShared

/// Everything an agent can do in BatteryLens. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same code as the menu
/// bar menu, Settings and the batterylens:// links, so the menu, Settings and the widget follow.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, how many devices BatteryLens knows and how many are connected, the lowest battery, which batteries are low or charging, each source's status and the permissions.",
                     example: "batterylens status --json", readOnly: true) { _ in
            let app = try delegate()
            let hub = app.hub, model = app.model
            let visible = hub.devices
            let lowest = visible.filter(\.isConnected).filter { $0.lowest != nil }.min { $0.lowest! < $1.lowest! }
            var permissions: JSONObject = [:]
            for permission in Permission.allCases {
                permissions[permission.title] = state(model.permissions[permission])
            }
            return ["app": AppInfo.name, "version": AppInfo.version,
                    "devices": hub.allDevices.count, "shown": visible.count, "connected": visible.filter(\.isConnected).count,
                    "lowest": lowest.map { ["id": $0.id, "name": $0.name, "level": $0.lowest!] as JSONObject } ?? NSNull(),
                    "low": visible.filter { $0.isConnected && ($0.lowest ?? 100) <= $0.threshold }.map(\.name),
                    "charging": visible.filter { $0.isConnected && $0.isCharging }.map(\.name),
                    "sources": hub.sources.map { source -> JSONObject in
                        ["source": source.kind.displayName,
                         "status": hub.isStarted(source.kind) ? source.status : "waiting for its permission"]
                    },
                    "permissions": permissions,
                    "settingsOpen": app.settingsWindow.isVisible]
        },

        // MARK: Devices

        AgentCommand(name: "devices list", summary: "List every device BatteryLens knows, as Settings › Devices does: the Mac first, then connected devices, then ones last seen earlier. Returns `devices` (id, name, kind, level, levels, charging, connected, lastRead in UTC, hidden, reporting, lowThreshold, forecast), `total` and `nextOffset` when there are more.",
                     params: [.init(name: "connected", kind: .boolean, help: "only devices connected now"),
                              .init(name: "kind", help: "only this kind: \(DeviceKind.allCases.map(\.rawValue).joined(separator: ", "))"),
                              .init(name: "shown", kind: .boolean, help: "only the ones the widget and menu bar show (not hidden, reported)"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "batterylens devices list --connected --json", readOnly: true) { args in
            let app = try delegate()
            var devices = app.hub.allDevices
            if try args.bool("connected") == true { devices = devices.filter(\.isConnected) }
            if try args.bool("shown") == true { devices = app.hub.store.visible(devices) }
            if let kind = args.string("kind") {
                guard let value = DeviceKind(rawValue: kind.lowercased()) else {
                    throw AgentError.usage("--kind must be one of \(DeviceKind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                devices = devices.filter { $0.kind == value }
            }
            return try page(devices, args) { summary($0, app) }
        },
        AgentCommand(name: "devices show", summary: "Show one device: each battery's level, charging state, source and when it was read, its settings, its forecast, and its estimate for a device that reports no level.",
                     params: [deviceParam],
                     example: "batterylens devices show Mouse --json", readOnly: true) { args in
            let app = try delegate()
            let device = try find(args, app)
            return detail(device, app)
        },
        AgentCommand(name: "devices history", summary: "Show a device's charge history, newest first: every change in a battery's level or charging state, kept 90 days. Returns `samples` (part, percent, charging, date in UTC), `total` and `nextOffset`.",
                     params: [deviceParam,
                              .init(name: "since", help: "only samples newer than this: 1d, 7d, 30d, 12h, or an ISO 8601 date"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "batterylens devices history Mouse --since 7d --json", readOnly: true) { args in
            let app = try delegate()
            let device = try find(args, app)
            var samples = app.model.history(for: device).sorted { $0.date > $1.date }
            if let since = args.string("since") {
                let start = try date(since)
                samples = samples.filter { $0.date >= start }
            }
            var result = try page(samples, args, key: "samples") { sample -> JSONObject in
                ["part": partName(sample.part), "percent": sample.percent, "charging": sample.isCharging,
                 "date": JSON.date(sample.date)]
            }
            result["device"] = device.name
            return result
        },
        AgentCommand(name: "devices update", summary: "Change a device's settings, as Settings › Devices does: its name, whether the widget and menu bar show it, its low-battery level, and whether it's reported at all. Only the options you give change.",
                     params: [deviceParam,
                              .init(name: "name", help: "a new name (\"\" goes back to the name the device gives itself)"),
                              .init(name: "hidden", kind: .boolean, help: "true hides it from the widget and the menu bar; it stays in Settings"),
                              .init(name: "low-threshold", help: "the level its low-battery alert comes at: \(thresholds.map(String.init).joined(separator: ", ")), or default"),
                              .init(name: "reporting", kind: .boolean, help: "false for a device shared with another computer: no widget entry, alerts or estimate")],
                     example: "batterylens devices update Mouse --name \"Desk mouse\" --low-threshold 15 --json") { args in
            let app = try delegate()
            let device = try find(args, app)
            let before = app.model.settings(for: device.id)
            var threshold: Int?? = nil
            if let raw = args.string("low-threshold") {
                if raw.lowercased() == "default" {
                    threshold = .some(nil)
                } else {
                    guard let value = Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))), thresholds.contains(value) else {
                        throw AgentError.usage("--low-threshold must be one of \(thresholds.map(String.init).joined(separator: ", ")), or default")
                    }
                    threshold = .some(value)
                }
            }
            let hidden = try args.bool("hidden"), reporting = try args.bool("reporting")
            let name = args.string("name")
            // As the name field does: blank, or the device's own name, clears a custom one.
            let originalName = app.model.remembered(device.id)?.name ?? device.name
            app.model.update(device.id) { settings in
                if let name {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    settings.customName = trimmed.isEmpty || trimmed == originalName ? nil : trimmed
                }
                if let hidden { settings.isHidden = hidden }
                if let reporting { settings.isReporting = reporting }
                if let threshold { settings.lowThreshold = threshold }
            }
            let after = app.model.settings(for: device.id)
            guard let updated = app.hub.allDevices.first(where: { $0.id == device.id }) else {
                throw AgentError.notFound("the device went away while it was changing. Run `batterylens devices list`")
            }
            var result = detail(updated, app)
            result["changed"] = after != before
            return result
        },
        AgentCommand(name: "devices mark-charged", summary: "For a device that reports no level of its own: say it was just charged fully, so BatteryLens estimates its level from how much you use it (Mark as Charged in Settings › Devices).",
                     params: [deviceParam,
                              .init(name: "ran-out", kind: .boolean, help: "it went flat before you charged it, which teaches BatteryLens how long a charge lasts")],
                     example: "batterylens devices mark-charged Keyboard --json") { args in
            let app = try delegate()
            let device = try find(args, app)
            guard app.model.canEstimate(device) else {
                throw AgentError.invalid("\(device.name) reports its own level, so it isn't estimated")
            }
            guard app.hub.estimates != nil else { throw AgentError.invalid("estimates aren't running in this copy of BatteryLens") }
            app.model.markCharged(device, ranOut: try args.bool("ran-out") == true)
            app.hub.recompute()
            let estimate = app.model.estimate(for: device)
            return ["id": device.id, "name": device.name, "marked": true, "estimate": estimate.map { estimateJSON($0) as Any } ?? NSNull()]
        },
        AgentCommand(name: "devices forget", summary: "Forget a device and its settings, as Forget in Settings › Devices does. It comes back as new if it reports again. Without --yes it only shows what it would forget.",
                     params: [deviceParam],
                     example: "batterylens devices forget \"Old keyboard\" --yes --json", destructive: true) { args in
            let app = try delegate()
            let device = try find(args, app)
            guard args.confirmed else {
                return ["wouldForget": summary(device, app),
                        "hint": "add --yes (over MCP, set yes to true) to forget it. Its name, low-battery level and other settings go too"]
            }
            app.model.forget(device.id)
            return ["forgotten": device.id, "name": device.name]
        },
        AgentCommand(name: "devices refresh", summary: "Read every source again now, as Refresh Now in the menu does (Logitech devices are otherwise read hourly). Readings arrive over the next few seconds: then run `batterylens devices list`.",
                     example: "batterylens devices refresh --json") { _ in
            let app = try delegate()
            app.hub.refresh()
            return ["refreshing": app.hub.sources.filter { app.hub.isStarted($0.kind) }.map(\.kind.displayName),
                    "next": "run `batterylens devices list` in a few seconds"]
        },

        // MARK: Settings

        AgentCommand(name: "settings show", summary: "Show the alert and menu bar settings: low-battery and fully-charged alerts, the default low-battery level, what the menu bar shows, and Ask before quitting.",
                     example: "batterylens settings show --json", readOnly: true) { _ in
            settingsJSON(try delegate())
        },
        AgentCommand(name: "settings update", summary: "Change the alert and menu bar settings, as Settings › Alerts, Menu Bar and General do. Only the options you give change.",
                     params: [.init(name: "low-alerts", kind: .boolean, help: "true or false: tell me when a battery is low"),
                              .init(name: "full-alerts", kind: .boolean, help: "true or false: tell me when a battery is fully charged (asks for Notifications the first time)"),
                              .init(name: "low-threshold", kind: .integer, help: "the default low-battery level: \(thresholds.map(String.init).joined(separator: ", "))"),
                              .init(name: "menu-bar-device", help: "the device whose level the menu bar shows (an id or name), or lowest"),
                              .init(name: "menu-bar-percent", kind: .boolean, help: "true or false: show the percentage next to the icon"),
                              .init(name: "confirm-quit", kind: .boolean, help: "true or false: ask before quitting")],
                     example: "batterylens settings update --low-threshold 15 --menu-bar-device Mouse --json") { args in
            let app = try delegate()
            let model = app.model
            // Checked before anything changes, so a bad value changes nothing.
            let threshold = try args.string("low-threshold").map { _ in try args.int("low-threshold", default: 0) }
            if let threshold, !thresholds.contains(threshold) {
                throw AgentError.usage("--low-threshold must be one of \(thresholds.map(String.init).joined(separator: ", "))")
            }
            let menuBarDevice = try args.string("menu-bar-device").map { key -> String in
                if key.lowercased() == "lowest" || key.isEmpty { return "" }
                return try find(key, app).id
            }
            let low = try args.bool("low-alerts"), full = try args.bool("full-alerts")
            let percent = try args.bool("menu-bar-percent"), confirm = try args.bool("confirm-quit")
            let before = settingsJSON(app)
            if let low, model.lowAlerts != low { model.lowAlerts = low }
            if let full, model.fullAlerts != full { model.fullAlerts = full }
            if let threshold, model.defaultLowThreshold != threshold { model.defaultLowThreshold = threshold }
            if let menuBarDevice, model.menuBarDevice != menuBarDevice { model.menuBarDevice = menuBarDevice }
            if let percent, model.menuBarShowsPercent != percent { model.menuBarShowsPercent = percent }
            if let confirm, model.confirmQuit != confirm { model.confirmQuit = confirm }
            var result = settingsJSON(app)
            result["changed"] = !NSDictionary(dictionary: before).isEqual(to: result)
            return result
        },

        // MARK: Windows

        AgentCommand(name: "open", summary: "Bring up a Settings tab (general, devices, alerts, menu-bar, permissions) or Help. With --device, Devices opens on that device.",
                     params: [.init(name: "page", required: true, positional: true, help: "general, devices, alerts, menu-bar, permissions or help"),
                              .init(name: "device", help: "with devices: the device to select (an id or name)")],
                     example: "batterylens open devices --device Mouse --json") { args in
            let app = try delegate()
            let page = try args.required("page").lowercased()
            if page == "help" {
                app.showHelp()
                return ["open": "help"]
            }
            let tabs: [String: SettingsTab] = ["general": .general, "settings": .general, "devices": .devices, "alerts": .alerts,
                                               "menu-bar": .menuBar, "menubar": .menuBar, "permissions": .permissions]
            guard let tab = tabs[page] else {
                throw AgentError.notFound("no page \"\(page)\". Give general, devices, alerts, menu-bar, permissions or help")
            }
            let device = try args.string("device").map { try find($0, app) }
            if device != nil && tab != .devices { throw AgentError.usage("--device goes with the devices page") }
            if let device { app.model.selectedDevice = device.id }
            app.settingsWindow.show(tab: tab)
            return ["open": page, "device": device?.id ?? NSNull()]
        },
    ]

    /// The levels the low-battery pickers in Settings offer.
    static let thresholds = [5, 10, 15, 20, 25, 30, 40, 50]

    // MARK: Finding devices

    static let deviceParam = AgentCommand.Param(name: "device", required: true, positional: true,
                                                help: "the device's id (from `batterylens devices list`) or its name")

    @MainActor
    static func delegate() throws -> AppDelegate {
        guard let app = AppDelegate.shared else { throw AgentError.unavailable("BatteryLens is still starting. Try again in a moment") }
        return app
    }

    @MainActor
    static func find(_ args: Args, _ app: AppDelegate) throws -> DeviceBattery { try find(try args.required("device"), app) }

    /// The device with this id or name; the start of an id, or part of a name, works when only one matches.
    @MainActor
    static func find(_ key: String, _ app: AppDelegate) throws -> DeviceBattery {
        let devices = app.hub.allDevices
        let lowered = key.lowercased()
        if let exact = devices.first(where: { $0.id.lowercased() == lowered }) { return exact }
        let named = devices.filter { $0.name.lowercased() == lowered }
        if named.count == 1 { return named[0] }
        var matches = devices.filter { $0.id.lowercased().hasPrefix(lowered) }
        if matches.isEmpty { matches = devices.filter { $0.name.lowercased().contains(lowered) } }
        if named.count > 1 { matches = named }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw AgentError.notFound("no device \"\(key)\". Run `batterylens devices list`")
        default:
            throw AgentError.invalid("\(matches.count) devices match \"\(key)\" (\(matches.map { "\($0.name): \($0.id)" }.joined(separator: ", "))). Give the id")
        }
    }

    // MARK: Results

    static func partName(_ part: BatteryPart?) -> String {
        switch part {
        case nil: "main"
        case .left: "left"
        case .right: "right"
        case .chargingCase: "case"
        }
    }

    static func state(_ state: Permission.State?) -> String {
        switch state {
        case .granted: "allowed"
        case .denied: "denied"
        case .notAsked, nil: "not asked"
        }
    }

    @MainActor
    static func summary(_ device: DeviceBattery, _ app: AppDelegate) -> JSONObject {
        let settings = app.model.settings(for: device.id)
        var json: JSONObject = ["id": device.id, "name": device.name, "kind": device.kind.rawValue,
                                "level": device.lowest ?? NSNull(), "charging": device.isCharging,
                                "connected": device.isConnected, "lastRead": JSON.date(device.updated),
                                "levels": levelsText(device), "hidden": settings.isHidden, "reporting": settings.isReporting,
                                "lowThreshold": device.threshold]
        if let forecast = device.forecast { json["forecast"] = forecast.text() }
        return json
    }

    /// "L 90% charging, R 88%, Case 40% (estimate)": the batteries in one line.
    static func levelsText(_ device: DeviceBattery) -> String {
        guard !device.levels.isEmpty else { return "no level" }
        return device.levels.map { level in
            (level.part.map { "\($0.shortName) " } ?? "") + (level.source == .estimate ? "about " : "") + "\(level.percent)%"
                + (level.isCharging ? " charging" : "")
        }.joined(separator: ", ")
    }

    @MainActor
    static func detail(_ device: DeviceBattery, _ app: AppDelegate) -> JSONObject {
        var json = summary(device, app)
        let settings = app.model.settings(for: device.id)
        json["batteries"] = device.levels.map { level -> JSONObject in
            ["part": partName(level.part), "percent": level.percent, "charging": level.isCharging,
             "source": level.source.displayName, "read": JSON.date(level.date)]
        }
        json["customName"] = settings.customName ?? NSNull()
        json["ownLowThreshold"] = settings.lowThreshold ?? NSNull()
        if let remembered = app.model.remembered(device.id) {
            json["deviceName"] = remembered.name
            json["firstSeen"] = JSON.date(remembered.firstSeen)
        }
        if let forecast = device.forecast {
            json["forecast"] = forecast.text()
            json["forecastKind"] = forecast.kind.rawValue
            json["forecastDate"] = JSON.date(forecast.date)
            json["forecastBasis"] = forecast.basis.rawValue
        }
        json["estimated"] = app.model.canEstimate(device)
        if app.model.canEstimate(device), let estimate = app.model.estimate(for: device) {
            json["estimate"] = estimateJSON(estimate)
        }
        json["historySamples"] = app.model.history(for: device).count
        json["menuBarShows"] = app.model.menuBarDevice == device.id
        return json
    }

    static func estimateJSON(_ estimate: Estimator.Estimate) -> JSONObject {
        ["percent": estimate.percent, "chargedAt": JSON.date(estimate.chargedAt), "activeMinutes": estimate.activeMinutes,
         "hoursPerCharge": (estimate.hoursPerCharge * 10).rounded() / 10, "learnedFrom": estimate.learnedFrom]
    }

    @MainActor
    static func settingsJSON(_ app: AppDelegate) -> JSONObject {
        let model = app.model
        let shown = model.menuBarDevice.isEmpty ? nil : model.devices.first { $0.id == model.menuBarDevice }
        return ["lowAlerts": model.lowAlerts, "fullAlerts": model.fullAlerts, "lowThreshold": model.defaultLowThreshold,
                "menuBarDevice": model.menuBarDevice.isEmpty ? "lowest" : model.menuBarDevice,
                "menuBarDeviceName": model.menuBarDevice.isEmpty ? "The lowest battery" : shown?.name ?? "Unknown device",
                "menuBarPercent": model.menuBarShowsPercent, "confirmQuit": model.confirmQuit]
    }

    static func page<T>(_ all: [T], _ args: Args, key: String = "devices", _ json: (T) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50)
        let offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be 1 or more, and --offset 0 or more") }
        let slice = all.dropFirst(offset).prefix(limit)
        var result: JSONObject = [key: slice.map(json), "total": all.count]
        if offset + slice.count < all.count { result["nextOffset"] = offset + slice.count }
        return result
    }

    // MARK: Options

    /// "7d", "12h", "30m", or an ISO 8601 date.
    static func date(_ text: String) throws -> Date {
        let units: [Character: TimeInterval] = ["d": 86_400, "h": 3_600, "m": 60]
        if let unit = text.last.flatMap({ units[$0] }), let count = Double(text.dropLast()), count >= 0 {
            return Date().addingTimeInterval(-count * unit)
        }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let day = try? Date(text, strategy: .iso8601.year().month().day()) { return day }
        throw AgentError.usage("--since must be like 7d, 12h or 30m, or an ISO 8601 date such as 2026-11-01")
    }
}
