import Foundation
import UIKit
import OSLog

// Observation only. This object never requests/resigns focus, changes windows,
// replaces input views, installs gestures, or reads a field's text.
@MainActor
final class InputDiagnostics: NSObject {
    static let shared = InputDiagnostics()
    private var started = false
    private var startedAt = Date()
    private var lastEditingAt: Date?
    private var events: [[String: Any]] = []
    private var droppedEvents = 0
    private var textChangeCount = 0
    private var keyboardEventCount = 0
    private var keyboardLocalEventCount = 0
    private var keyboardNonemptyFrameCount = 0
    private weak var lastEditor: UIView?
    private var editorIDs: [ObjectIdentifier: Int] = [:]
    private var nextEditorID = 1

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification,
                     UITextField.textDidEndEditingNotification,
                     UITextField.textDidChangeNotification,
                     UITextView.textDidBeginEditingNotification,
                     UITextView.textDidEndEditingNotification,
                     UITextView.textDidChangeNotification] {
            center.addObserver(self, selector: #selector(editorEvent(_:)), name: name, object: nil)
        }
        for name in [UIResponder.keyboardWillShowNotification,
                     UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardDidHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification] {
            center.addObserver(self, selector: #selector(keyboardEvent(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification,
                     UIApplication.willResignActiveNotification,
                     UIScene.didActivateNotification,
                     UIScene.willDeactivateNotification,
                     UIWindow.didBecomeKeyNotification,
                     UIWindow.didResignKeyNotification,
                     UITextInputMode.currentInputModeDidChangeNotification] {
            center.addObserver(self, selector: #selector(lifecycleEvent(_:)), name: name, object: nil)
        }
        record("monitor_started", details: environment())
    }

    @objc private func editorEvent(_ notification: Notification) {
        guard let editor = notification.object as? UIView,
              editor is UITextField || editor is UITextView else { return }
        lastEditor = editor
        if notification.name == UITextField.textDidChangeNotification ||
            notification.name == UITextView.textDidChangeNotification {
            textChangeCount += 1
            // Count changes only: no text, selection, placeholder or labels.
            return
        }
        let began = notification.name == UITextField.textDidBeginEditingNotification ||
            notification.name == UITextView.textDidBeginEditingNotification
        if began { lastEditingAt = Date() }
        record(began ? "editing_began" : "editing_ended", details: editorSnapshot(editor))
        if began {
            // Observe the completed input transition; do not retry focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak editor] in
                guard let self, let editor else { return }
                self.record("one_second_after_editing_began", details: self.editorSnapshot(editor))
            }
        }
    }

    @objc private func keyboardEvent(_ notification: Notification) {
        keyboardEventCount += 1
        let info = notification.userInfo ?? [:]
        let isLocal = (info[UIResponder.keyboardIsLocalUserInfoKey] as? NSNumber)?.boolValue
        if isLocal == true { keyboardLocalEventCount += 1 }
        var details: [String: Any] = [
            "notification": notification.name.rawValue,
            "isLocal": isLocal.map { $0 as Any } ?? NSNull()
        ]
        if let value = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            let frame = value.cgRectValue
            details["endFrameInScreenCoordinates"] = rectangle(frame)
            if !frame.isEmpty { keyboardNonemptyFrameCount += 1 }
        }
        if let editor = lastEditor { details["editor"] = editorSnapshot(editor) }
        // Keep local, nonlocal, missing-local and hide notifications separately.
        // Absence of notifications does not prove absence of a system keyboard.
        record("keyboard_notification", details: details)
    }

    @objc private func lifecycleEvent(_ notification: Notification) {
        record("lifecycle", details: [
            "notification": notification.name.rawValue,
            "environment": environment()
        ])
    }

    private func record(_ name: String, details: [String: Any]) {
        events.append(["elapsedSeconds": Date().timeIntervalSince(startedAt),
                       "event": name, "details": details])
        if events.count > 180 {
            droppedEvents += events.count - 180
            events.removeFirst(events.count - 180)
        }
    }

    private func editorSnapshot(_ editor: UIView) -> [String: Any] {
        let key = ObjectIdentifier(editor)
        if editorIDs[key] == nil {
            editorIDs[key] = nextEditorID
            nextEditorID += 1
        }
        var result: [String: Any] = [
            "controlID": editorIDs[key] ?? 0,
            "class": String(describing: type(of: editor)),
            "isFirstResponder": editor.isFirstResponder,
            "canBecomeFirstResponder": editor.canBecomeFirstResponder,
            "isUserInteractionEnabled": editor.isUserInteractionEnabled,
            "isHidden": editor.isHidden,
            "alpha": Double(editor.alpha),
            "attachedToWindow": editor.window != nil,
            "applicationState": applicationState(),
            "mainThread": Thread.isMainThread,
            "keyboardNotificationsSoFar": keyboardEventCount,
            "textChangesSoFar": textChangeCount
        ]
        if let field = editor as? UITextField {
            result["kind"] = "UITextField"
            result["enabled"] = field.isEnabled
            result["keyboardType"] = field.keyboardType.rawValue
            result["hasCustomInputView"] = field.inputView != nil
            result["inputLanguage"] = field.textInputMode?.primaryLanguage ?? "unavailable"
        } else if let textView = editor as? UITextView {
            result["kind"] = "UITextView"
            result["editable"] = textView.isEditable
            result["selectable"] = textView.isSelectable
            result["keyboardType"] = textView.keyboardType.rawValue
            result["hasCustomInputView"] = textView.inputView != nil
            result["inputLanguage"] = textView.textInputMode?.primaryLanguage ?? "unavailable"
        }
        if let window = editor.window {
            result["window"] = windowSnapshot(window)
        }
        var parents: [String] = []
        var parent = editor.superview
        while let current = parent, parents.count < 12 {
            parents.append(String(describing: type(of: current)))
            parent = current.superview
        }
        result["ancestorClasses"] = parents
        return result
    }

    private func windowSnapshot(_ window: UIWindow) -> [String: Any] {
        var result: [String: Any] = [
            "class": String(describing: type(of: window)),
            "isKeyWindow": window.isKeyWindow,
            "isHidden": window.isHidden,
            "level": Double(window.windowLevel.rawValue),
            "bounds": rectangle(window.bounds),
            "sceneState": window.windowScene.map { sceneState($0.activationState) } ?? "no_scene"
        ]
        if let root = window.rootViewController {
            result["rootControllerClass"] = String(describing: type(of: root))
            var presented: [String] = []
            var controller = root.presentedViewController
            while let current = controller, presented.count < 8 {
                presented.append(String(describing: type(of: current)))
                controller = current.presentedViewController
            }
            result["presentedControllerClasses"] = presented
            if let view = root.viewIfLoaded {
                result["keyboardLayoutGuideFrame"] = rectangle(view.keyboardLayoutGuide.layoutFrame)
            }
        }
        return result
    }

    private func environment() -> [String: Any] {
        var result: [String: Any] = [
            "applicationState": applicationState(),
            "activeInputLanguages": UITextInputMode.activeInputModes.map { $0.primaryLanguage ?? "unavailable" },
            "scenes": UIApplication.shared.connectedScenes.compactMap { scene -> [String: Any]? in
                guard let windowScene = scene as? UIWindowScene else { return nil }
                return ["state": sceneState(scene.activationState),
                        "windows": windowScene.windows.map { windowSnapshot($0) }]
            }
        ]
        if let editor = lastEditor { result["lastEditor"] = editorSnapshot(editor) }
        return result
    }

    private func applicationState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func sceneState(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        case .unattached: return "unattached"
        @unknown default: return "unknown"
        }
    }

    private func rectangle(_ rect: CGRect) -> [String: Any] {
        func finite(_ value: CGFloat) -> Any {
            value.isFinite ? Double(value) as Any : NSNull()
        }
        return ["x": finite(rect.origin.x), "y": finite(rect.origin.y),
                "width": finite(rect.width), "height": finite(rect.height)]
    }

    func makeReport() async throws -> Data {
        start()
        record("report_requested", details: environment())
        let extensionInfo = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any]
        var report: [String: Any] = [
            "schemaVersion": 3,
            "sourceVersion": "DeliveryRouteProbe 0.9.0",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "systemVersion": UIDevice.current.systemVersion,
            "operatingSystemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "processName": ProcessInfo.processInfo.processName,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unavailable",
            "extensionPoint": (extensionInfo?["NSExtensionPointIdentifier"] as? String) ?? "not_declared",
            "eventLimit": 180, "droppedEvents": droppedEvents,
            "events": events,
            "counts": ["textChanges": textChangeCount,
                       "keyboardNotifications": keyboardEventCount,
                       "localKeyboardNotifications": keyboardLocalEventCount,
                       "nonemptyKeyboardFrames": keyboardNonemptyFrameCount],
            "environmentAtExport": environment(),
            "privacy": "Field text and clipboard are not read directly. This export includes selected current-process system-log messages as returned by OSLog, including available argument values. Messages may contain app, view, path or other logged information. OSLog redaction remains in place; private values are not recovered. Export happens only on request, with no automatic upload.",
            "limits": [
                "Focus and notifications alone cannot establish why the keyboard is missing.",
                "No keyboard notifications or no matching logs is not proof that the system has no input session.",
                "System log access is limited to this process; Playgrounds and keyboard-service process logs may be unavailable.",
                "Nonempty keyboard frames may be offscreen; their count does not establish visible keyboard display.",
                "OSLog may redact argument values or return an empty message; unavailable values cannot be reconstructed.",
                "Message and entry limits are reported. A truncated export is not a complete log.",
                "Error/fault logs can be unrelated to keyboard failure. Temporal proximity does not establish causation."
            ]
        ]
        let since = max(lastEditingAt?.addingTimeInterval(-2) ?? startedAt,
                        Date().addingTimeInterval(-120))
        let logs = await InputSystemLog.read(since: since)
        report["inputSystemLogSignals"] = try JSONSerialization.jsonObject(with: logs)
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }
}

// Reading OSLog is deferred until export and runs off the main thread.
// Retain both the template and the message OSLog makes available. Empty
// subsystem/category values are valid metadata, not a reason to drop wording.
// Do not recover private values or directly read input contents. The explicit
// export can include information that the system has written into its logs.
private enum InputSystemLog {
    static func read(since: Date) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = collect(since: since)
                let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
                    ?? Data("{\"status\":\"encoding_failed\"}".utf8)
                continuation.resume(returning: data)
            }
        }
    }

    private static func collect(since: Date) -> [String: Any] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: since))
            var scanned = 0
            var matched = 0
            var truncated = false
            var signals: [[String: Any]] = []
            var severeEntries: [[String: Any]] = []
            var severeCount = 0
            var contextDropped = 0
            var severeDropped = 0
            let deadline = Date().addingTimeInterval(2)
            for entry in entries {
                scanned += 1
                if scanned > 3000 || Date() > deadline { truncated = true; break }
                // Some OS versions may return entries before the position.
                guard entry.date >= since, let log = entry as? OSLogEntryLog else { continue }
                let composedMessage = log.composedMessage
                let message = composedMessage.lowercased()
                let category = (log.subsystem + " " + log.category).lowercased()
                let inputRelated = ["keyboard", "textinput", "text input", "rtiinput", "inputsession", "input session"]
                    .contains(where: { message.contains($0) || category.contains($0) })
                let severe = log.level == .error || log.level == .fault
                // Retain errors even when their wording does not match the
                // keyboard keywords. Mark them as potentially unrelated.
                guard inputRelated || severe else { continue }
                matched += 1
                var tags: [String] = []
                if message.contains("valid session") || message.contains("invalid session") {
                    tags.append("session_identifier_rejected")
                }
                if message.contains("denied") || message.contains("not permitted") || message.contains("not allowed") {
                    tags.append("request_denied")
                }
                if message.contains("connection") && (message.contains("invalidated") || message.contains("interrupted")) {
                    tags.append("connection_interrupted_or_invalidated")
                }
                if message.contains("timeout") || message.contains("timed out") { tags.append("timeout") }
                if message.contains("not key") { tags.append("window_not_key") }
                if message.contains("failed") || message.contains("failure") || message.contains("error") {
                    tags.append("error_or_failure_mentioned")
                }
                if tags.isEmpty { tags = ["other_input_log"] }
                let formatTemplate = log.formatString
                let item: [String: Any] = [
                    "secondsSinceQueryStart": entry.date.timeIntervalSince(since),
                    "level": levelName(log.level), "rawLevel": log.level.rawValue,
                    "subsystem": String(log.subsystem.prefix(256)),
                    "category": String(log.category.prefix(256)),
                    "inputRelatedByKeyword": inputRelated,
                    "signals": tags,
                    "formatTemplate": String(formatTemplate.prefix(8192)),
                    "formatTemplateTruncated": formatTemplate.count > 8192,
                    "message": String(composedMessage.prefix(8192)),
                    "messageTruncated": composedMessage.count > 8192,
                    "messageEmpty": composedMessage.isEmpty
                ]
                if formatTemplate.count > 8192 || composedMessage.count > 8192 { truncated = true }
                if severe {
                    severeCount += 1
                    // Separate budget: routine logs cannot displace errors.
                    if severeEntries.count < 40 { severeEntries.append(item) }
                    else { severeDropped += 1; truncated = true }
                }
                if signals.count < 120 { signals.append(item) }
                else { contextDropped += 1; truncated = true }
            }
            return ["status": "read_completed", "scope": "current_process_only",
                    "queryFrom": ISO8601DateFormatter().string(from: since),
                    "scannedEntries": min(scanned, 3000), "matchedEntries": matched,
                    "truncated": truncated, "signals": signals,
                    "errorFaultCount": severeCount, "errorFaultEntries": severeEntries,
                    "droppedContextEntries": contextDropped, "droppedErrorFaultEntries": severeDropped,
                    "messageCharacterLimit": 8192,
                    "messageRepresentation": "formatString and composedMessage as provided by OSLog, for every retained entry regardless of subsystem; OSLog redaction preserved",
                    "interpretation": "Inspect level, subsystem, category, formatTemplate and message together. An empty subsystem is not evidence of a non-Apple source. Signals are keyword hints, not confirmed causes. Error/fault entries may be unrelated. Zero matches does not rule out system errors."]
        } catch {
            let value = error as NSError
            return ["status": "unavailable", "scope": "current_process_only",
                    "errorDomain": value.domain, "errorCode": value.code,
                    "interpretation": "Log access failed. This is not evidence of no keyboard error."]
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undefined"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "unknown"
        }
    }
}
