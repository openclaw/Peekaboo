import Foundation
import PeekabooFoundation

@MainActor
extension ProcessService {
    /// Normalize generic parameters to typed parameters based on command
    func normalizeStepParameters(_ step: ScriptStep) throws -> ScriptStep {
        guard case let .generic(dict) = step.params else {
            return step
        }

        guard let typedParams = try self.typedParameters(for: step.command.lowercased(), dict: dict) else {
            return step
        }

        return ScriptStep(
            stepId: step.stepId,
            comment: step.comment,
            command: step.command,
            params: typedParams)
    }

    private func typedParameters(for command: String, dict: [String: String]) throws -> ProcessCommandParameters? {
        switch command {
        case "see":
            try .screenshot(self.typedScreenshotParameters(from: dict))
        case "click":
            try .click(self.typedClickParameters(from: dict))
        case "type":
            try self.typedTypeParameters(from: dict)
        case "scroll":
            try .scroll(self.typedScrollParameters(from: dict))
        case "hotkey":
            try self.typedHotkeyParameters(from: dict)
        case "menu":
            self.typedMenuParameters(from: dict)
        case "window":
            .focusWindow(self.typedWindowParameters(from: dict))
        case "app":
            self.typedAppParameters(from: dict)
        case "swipe":
            .swipe(self.typedSwipeParameters(from: dict))
        case "drag":
            self.typedDragParameters(from: dict)
        case "sleep":
            .sleep(self.typedSleepParameters(from: dict))
        case "dock":
            .dock(self.typedDockParameters(from: dict))
        case "clipboard":
            self.typedClipboardParameters(from: dict)
        default:
            nil
        }
    }

    private func typedScreenshotParameters(from dict: [String: String]) throws -> ProcessCommandParameters
    .ScreenshotParameters {
        try ProcessCommandParameters.ScreenshotParameters(
            path: dict["path"] ?? "screenshot.png",
            app: dict["app"],
            pid: self.int32Value(from: dict, keys: ["pid"]),
            windowId: self.intValue(from: dict, keys: ["windowId", "window-id", "window_id"]),
            window: dict["window"],
            display: dict["display"].flatMap { Int($0) },
            mode: dict["mode"],
            annotate: dict["annotate"].flatMap { Bool($0) })
    }

    private func typedClickParameters(from dict: [String: String]) throws -> ProcessCommandParameters.ClickParameters {
        try ProcessCommandParameters.ClickParameters(
            x: dict["x"].flatMap { Double($0) },
            y: dict["y"].flatMap { Double($0) },
            label: dict["query"] ?? dict["label"],
            app: dict["app"],
            pid: self.int32Value(from: dict, keys: ["pid"]),
            windowId: self.intValue(from: dict, keys: ["windowId", "window-id", "window_id", "window"]),
            snapshot: dict["snapshot"] ?? dict["snapshotId"] ?? dict["snapshot-id"],
            foreground: self.boolValue(from: dict, keys: ["foreground"]),
            button: dict["button"] ??
                (dict["right-click"] == "true" ? "right" :
                    dict["double-click"] == "true" ? "double" : "left"),
            modifiers: nil)
    }

    private func typedTypeParameters(from dict: [String: String]) throws -> ProcessCommandParameters? {
        guard let text = dict["text"] else { return nil }
        return try .type(ProcessCommandParameters.TypeParameters(
            text: text,
            app: dict["app"],
            pid: self.int32Value(from: dict, keys: ["pid"]),
            windowId: self.intValue(from: dict, keys: ["windowId", "window-id", "window_id", "window"]),
            snapshot: dict["snapshot"] ?? dict["snapshotId"] ?? dict["snapshot-id"],
            foreground: self.boolValue(from: dict, keys: ["foreground"]),
            field: dict["field"],
            clearFirst: self.boolValue(from: dict, keys: ["clear", "clear-first", "clearFirst", "clear_first"]),
            pressEnter: self.boolValue(from: dict, keys: ["press-enter", "pressEnter", "press_enter"])))
    }

    private func typedScrollParameters(from dict: [String: String]) throws -> ProcessCommandParameters
    .ScrollParameters {
        try ProcessCommandParameters.ScrollParameters(
            direction: dict["direction"] ?? "down",
            amount: dict["amount"].flatMap { Int($0) },
            app: dict["app"],
            pid: self.int32Value(from: dict, keys: ["pid"]),
            windowId: self.intValue(from: dict, keys: ["windowId", "window-id", "window_id", "window"]),
            snapshot: dict["snapshot"] ?? dict["snapshotId"] ?? dict["snapshot-id"],
            foreground: self.boolValue(from: dict, keys: ["foreground"]),
            target: dict["on"] ?? dict["target"])
    }

    private func typedHotkeyParameters(from dict: [String: String]) throws -> ProcessCommandParameters? {
        let chord = dict["keys"].map(self.parseHotkeyChord)
        guard let key = dict["key"] ?? chord?.key else { return nil }
        var modifiers: [String] = []
        if dict["cmd"] == "true" || dict["command"] == "true" {
            modifiers.append("command")
        }
        if dict["shift"] == "true" {
            modifiers.append("shift")
        }
        if dict["control"] == "true" || dict["ctrl"] == "true" {
            modifiers.append("control")
        }
        if dict["option"] == "true" || dict["alt"] == "true" {
            modifiers.append("option")
        }
        if dict["fn"] == "true" || dict["function"] == "true" {
            modifiers.append("function")
        }
        if let modifierList = dict["modifiers"] {
            modifiers.append(contentsOf: self.parseModifierList(modifierList))
        }
        if let chord {
            modifiers.append(contentsOf: chord.modifiers)
        }
        modifiers = modifiers.reduce(into: []) { unique, modifier in
            if !unique.contains(where: { $0.caseInsensitiveCompare(modifier) == .orderedSame }) {
                unique.append(modifier)
            }
        }

        return try .hotkey(ProcessCommandParameters.HotkeyParameters(
            key: key,
            modifiers: modifiers,
            app: dict["app"],
            pid: self.int32Value(from: dict, keys: ["pid"]),
            windowId: self.intValue(from: dict, keys: ["windowId", "window-id", "window_id", "window"]),
            snapshot: dict["snapshot"] ?? dict["snapshotId"] ?? dict["snapshot-id"],
            foreground: self.boolValue(from: dict, keys: ["foreground"])))
    }

    private func typedMenuParameters(from dict: [String: String]) -> ProcessCommandParameters? {
        let menuItems: [String]
        if let path = dict["path"] {
            menuItems = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let menu = dict["menu"], let item = dict["item"] {
            menuItems = [menu, dict["submenu"], item].compactMap(\.self)
        } else if let menu = dict["menu"] {
            menuItems = menu.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            return nil
        }
        return .menuClick(ProcessCommandParameters.MenuClickParameters(
            menuPath: menuItems,
            app: dict["app"]))
    }

    private func typedWindowParameters(from dict: [String: String]) -> ProcessCommandParameters.FocusWindowParameters {
        ProcessCommandParameters.FocusWindowParameters(
            app: dict["app"],
            title: dict["title"],
            index: dict["index"].flatMap { Int($0) })
    }

    private func typedAppParameters(from dict: [String: String]) -> ProcessCommandParameters? {
        guard let appName = dict["name"] else { return nil }
        return .launchApp(ProcessCommandParameters.LaunchAppParameters(
            appName: appName,
            action: dict["action"],
            waitForLaunch: dict["wait"].flatMap { Bool($0) },
            bringToFront: dict["focus"].flatMap { Bool($0) },
            force: dict["force"].flatMap { Bool($0) }))
    }

    private func typedSwipeParameters(from dict: [String: String]) -> ProcessCommandParameters.SwipeParameters {
        ProcessCommandParameters.SwipeParameters(
            direction: dict["direction"] ?? "right",
            distance: dict["distance"].flatMap { Double($0) },
            duration: dict["duration"].flatMap { Double($0) },
            fromX: dict["from-x"].flatMap { Double($0) },
            fromY: dict["from-y"].flatMap { Double($0) },
            foreground: self.boolValue(from: dict, keys: ["foreground"]))
    }

    private func typedDragParameters(from dict: [String: String]) -> ProcessCommandParameters? {
        guard let fromX = dict["from-x"].flatMap(Double.init),
              let fromY = dict["from-y"].flatMap(Double.init),
              let toX = dict["to-x"].flatMap(Double.init),
              let toY = dict["to-y"].flatMap(Double.init)
        else {
            return nil
        }

        var modifiers: [String] = []
        if dict["cmd"] == "true" || dict["command"] == "true" {
            modifiers.append("command")
        }
        if dict["shift"] == "true" {
            modifiers.append("shift")
        }
        if dict["control"] == "true" || dict["ctrl"] == "true" {
            modifiers.append("control")
        }
        if dict["option"] == "true" || dict["alt"] == "true" {
            modifiers.append("option")
        }
        if dict["fn"] == "true" || dict["function"] == "true" {
            modifiers.append("function")
        }
        if let modifierList = dict["modifiers"] {
            modifiers.append(contentsOf: self.parseModifierList(modifierList))
        }

        return .drag(ProcessCommandParameters.DragParameters(
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            duration: dict["duration"].flatMap { Double($0) },
            modifiers: modifiers.isEmpty ? nil : modifiers,
            foreground: self.boolValue(from: dict, keys: ["foreground"])))
    }

    private func typedSleepParameters(from dict: [String: String]) -> ProcessCommandParameters.SleepParameters {
        let duration = dict["duration"].flatMap { Double($0) } ?? 1.0
        return ProcessCommandParameters.SleepParameters(duration: duration)
    }

    private func parseModifierList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseHotkeyChord(_ value: String) -> (key: String?, modifiers: [String]) {
        let tokens = value.split(whereSeparator: { character in
            character == "," || character == "+" || character.isWhitespace
        }).map(String.init)
        let modifierNames = Set(["cmd", "command", "shift", "ctrl", "control", "alt", "option", "fn", "function"])
        let modifiers = tokens.filter { modifierNames.contains($0.lowercased()) }
        let keys = tokens.filter { !modifierNames.contains($0.lowercased()) }
        return (keys.count == 1 ? keys[0] : nil, modifiers)
    }

    private func boolValue(from dict: [String: String], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key].flatMap(Bool.init) {
                return value
            }
        }
        return nil
    }

    private func intValue(from dict: [String: String], keys: [String]) throws -> Int? {
        try ProcessTargetIdentifierParser.windowID(from: dict, keys: keys)
    }

    private func int32Value(from dict: [String: String], keys: [String]) throws -> Int32? {
        try ProcessTargetIdentifierParser.pid(from: dict, keys: keys)
    }

    private func typedDockParameters(from dict: [String: String]) -> ProcessCommandParameters.DockParameters {
        ProcessCommandParameters.DockParameters(
            action: dict["action"] ?? "list",
            item: dict["item"],
            path: dict["path"])
    }

    private func typedClipboardParameters(from dict: [String: String]) -> ProcessCommandParameters? {
        guard let action = dict["action"] else { return nil }

        return .clipboard(ProcessCommandParameters.ClipboardParameters(
            action: action,
            text: dict["text"],
            filePath: dict["file-path"] ?? dict["filePath"] ?? dict["image-path"] ?? dict["imagePath"],
            dataBase64: dict["data-base64"] ?? dict["dataBase64"],
            uti: dict["uti"],
            prefer: dict["prefer"],
            output: dict["output"],
            slot: dict["slot"],
            alsoText: dict["also-text"] ?? dict["alsoText"],
            allowLarge: dict["allow-large"].flatMap { Bool($0) } ?? dict["allowLarge"].flatMap { Bool($0) }))
    }
}

enum ProcessTargetIdentifierParser {
    static func pid(from values: [String: String], keys: [String] = ["pid"]) throws -> Int32? {
        let parsed = try self.parseUnsignedIdentifier(
            from: values,
            keys: keys,
            field: "pid",
            maximum: UInt64(Int32.max))
        return parsed.map(Int32.init)
    }

    static func windowID(from values: [String: String], keys: [String]) throws -> Int? {
        let parsed = try self.parseUnsignedIdentifier(
            from: values,
            keys: keys,
            field: "windowId",
            maximum: UInt64(UInt32.max))
        return parsed.map(Int.init)
    }

    private static func parseUnsignedIdentifier(
        from values: [String: String],
        keys: [String],
        field: String,
        maximum: UInt64) throws -> UInt64?
    {
        let supplied = keys.compactMap { key in values[key].map { (key: key, rawValue: $0) } }
        guard !supplied.isEmpty else { return nil }

        let parsed = try supplied.map { suppliedValue -> UInt64 in
            guard let value = UInt64(suppliedValue.rawValue), value > 0, value <= maximum else {
                throw PeekabooError.invalidInput(
                    field: field,
                    reason: "\(suppliedValue.key) must be an integer between 1 and \(maximum)")
            }
            return value
        }
        guard let first = parsed.first else { return nil }
        if parsed.dropFirst().contains(where: { $0 != first }) {
            throw PeekabooError.invalidInput(
                field: field,
                reason: "\(field) aliases must resolve to the same value")
        }
        return first
    }
}
