import AppKit
import Carbon
import QbarCore

@MainActor
final class HotkeyManager {
    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: String] = [:]
    private var handler: EventHandlerRef?
    private var handlerStatus: OSStatus = noErr
    var onAction: ((String) -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            // Other components can register hotkeys on this event target too.
            // Their numeric IDs must not trigger a Qbar action.
            guard id.signature == 0x51424152 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let action = manager.actions[id.id] { manager.onAction?(action) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ preferences: Preferences) -> [String: String] {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll(); actions.removeAll()
        let bindings = preferences.shortcutBindings
        var failures: [String: String] = [:]
        guard handlerStatus == noErr, handler != nil else {
            for action in bindings.keys {
                failures[action] = L10n.format("无法建立全局快捷键监听（%d），请重新打开 Qbar。", handlerStatus)
            }
            return failures
        }
        var seen = Set<String>()
        for (offset, pair) in bindings.sorted(by: { $0.key < $1.key }).enumerated() {
            let (action, shortcut) = pair
            guard shortcut.isValid, seen.insert(shortcut.registrationKey).inserted else { failures[action] = L10n.tr("快捷键无效或与 Qbar 内其他快捷键重复"); continue }
            let id = UInt32(offset + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x51424152, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference); actions[id] = action }
            else { failures[action] = L10n.format("快捷键已被系统或其他应用占用（%d）", status) }
        }
        return failures
    }

    func stop() {
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    func makeNSView(context: Context) -> ShortcutButton {
        let view = ShortcutButton()
        view.onChange = { shortcut = $0 }
        return view
    }
    func updateNSView(_ view: ShortcutButton, context: Context) {
        view.shortcut = shortcut
        view.onChange = { shortcut = $0 }
        view.updateTitle()
    }
}

import SwiftUI

final class ShortcutButton: NSButton {
    var shortcut: Shortcut?
    var onChange: ((Shortcut?) -> Void)?
    private var recording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self; action = #selector(startRecording)
        setAccessibilityLabel(L10n.tr("设置快捷键"))
        toolTip = L10n.tr("点击后按下快捷键。Delete 清除，Esc 取消。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        updateTitle()
    }
    func updateTitle() { title = recording ? L10n.tr("请按快捷键…") : shortcut?.label ?? L10n.tr("录制快捷键") }
    override func resignFirstResponder() -> Bool { recording = false; updateTitle(); return true }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; updateTitle(); return }
        if event.keyCode == 51 || event.keyCode == 117 { shortcut = nil; onChange?(nil); recording = false; updateTitle(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        label += special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
        guard !candidate.conflictsWithInputSwitching else {
            title = L10n.tr("此组合保留给输入法")
            return
        }
        shortcut = candidate
        onChange?(shortcut); recording = false; updateTitle()
    }
}
