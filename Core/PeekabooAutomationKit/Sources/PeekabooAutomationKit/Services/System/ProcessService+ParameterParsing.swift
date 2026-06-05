import Foundation

@MainActor
extension ProcessService {
    /// Normalize generic parameters to typed parameters based on command
    func normalizeStepParameters(_ step: ScriptStep) -> ScriptStep {
        guard case let .generic(dict) = step.params else {
            return step
        }

        guard let typedParams = self.typedParameters(for: step.command.lowercased(), dict: dict) else {
            return step
        }

        return ScriptStep(
            stepId: step.stepId,
            comment: step.comment,
            command: step.command,
            params: typedParams)
    }

    private func typedParameters(for command: String, dict: [String: String]) -> ProcessCommandParameters? {
        switch command {
        case "see":
            .screenshot(self.typedScreenshotParameters(from: dict))
        case "click":
            .click(self.typedClickParameters(from: dict))
        case "type":
            self.typedTypeParameters(from: dict)
        case "scroll":
            .scroll(self.typedScrollParameters(from: dict))
        case "hotkey":
            self.typedHotkeyParameters(from: dict)
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

    private func typedScreenshotParameters(from dict: [String: String]) -> ProcessCommandParameters
    .ScreenshotParameters {
        ProcessCommandParameters.ScreenshotParameters(
            path: dict["path"] ?? "screenshot.png",
            app: dict["app"],
            window: dict["window"],
            display: dict["display"].flatMap { Int($0) },
            mode: dict["mode"],
            annotate: dict["annotate"].flatMap { Bool($0) })
    }

    private func typedClickParameters(from dict: [String: String]) -> ProcessCommandParameters.ClickParameters {
        ProcessCommandParameters.ClickParameters(
            x: dict["x"].flatMap { Double($0) },
            y: dict["y"].flatMap { Double($0) },
            label: dict["query"] ?? dict["label"],
            app: dict["app"],
            button: dict["button"] ??
                (dict["right-click"] == "true" ? "right" :
                    dict["double-click"] == "true" ? "double" : "left"),
            modifiers: nil)
    }

    private func typedTypeParameters(from dict: [String: String]) -> ProcessCommandParameters? {
        guard let text = dict["text"] else { return nil }
        return .type(ProcessCommandParameters.TypeParameters(
            text: text,
            app: dict["app"],
            field: dict["field"],
            clearFirst: self.boolValue(from: dict, keys: ["clear-first", "clearFirst", "clear_first"]),
            pressEnter: self.boolValue(from: dict, keys: ["press-enter", "pressEnter", "press_enter"])))
    }

    private func typedScrollParameters(from dict: [String: String]) -> ProcessCommandParameters.ScrollParameters {
        ProcessCommandParameters.ScrollParameters(
            direction: dict["direction"] ?? "down",
            amount: dict["amount"].flatMap { Int($0) },
            app: dict["app"],
            target: dict["on"] ?? dict["target"])
    }

    private func typedHotkeyParameters(from dict: [String: String]) -> ProcessCommandParameters? {
        guard let key = dict["key"] else { return nil }
        var modifiers: [String] = []
        if dict["cmd"] == "true" || dict["command"] == "true" { modifiers.append("command") }
        if dict["shift"] == "true" { modifiers.append("shift") }
        if dict["control"] == "true" || dict["ctrl"] == "true" { modifiers.append("control") }
        if dict["option"] == "true" || dict["alt"] == "true" { modifiers.append("option") }
        if dict["fn"] == "true" || dict["function"] == "true" { modifiers.append("function") }
        if let modifierList = dict["modifiers"] {
            modifiers.append(contentsOf: self.parseModifierList(modifierList))
        }

        return .hotkey(ProcessCommandParameters.HotkeyParameters(
            key: key,
            modifiers: modifiers,
            app: dict["app"]))
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
            fromY: dict["from-y"].flatMap { Double($0) })
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
        if dict["cmd"] == "true" || dict["command"] == "true" { modifiers.append("command") }
        if dict["shift"] == "true" { modifiers.append("shift") }
        if dict["control"] == "true" || dict["ctrl"] == "true" { modifiers.append("control") }
        if dict["option"] == "true" || dict["alt"] == "true" { modifiers.append("option") }
        if dict["fn"] == "true" || dict["function"] == "true" { modifiers.append("function") }
        if let modifierList = dict["modifiers"] {
            modifiers.append(contentsOf: self.parseModifierList(modifierList))
        }

        return .drag(ProcessCommandParameters.DragParameters(
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            duration: dict["duration"].flatMap { Double($0) },
            modifiers: modifiers.isEmpty ? nil : modifiers))
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

    private func boolValue(from dict: [String: String], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key].flatMap(Bool.init) {
                return value
            }
        }
        return nil
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
