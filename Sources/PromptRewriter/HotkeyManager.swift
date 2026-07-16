//
//  HotkeyManager.swift
//  PromptRewriter
//
//  Implements: HotkeyManaging
//
//  A thin Swift wrapper around Carbon's RegisterEventHotKey. Each registration
//  gets a unique hot-key id; a single installed Carbon event handler routes
//  presses back to the stored Swift closure. The global hotkey opens the style
//  palette; per-style hotkeys skip the palette and fire straight at a style.
//
//  Default global hotkey: Cmd+Shift+R.
//

import Foundation
import Carbon.HIToolbox

public final class HotkeyManager: HotkeyManaging {

    /// The app default global shortcut: Cmd+Shift+R.
    public static let defaultGlobalHotkey = Hotkey(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    // MARK: - Registration bookkeeping

    private final class Registration {
        let ref: EventHotKeyRef
        let handler: () -> Void
        init(ref: EventHotKeyRef, handler: @escaping () -> Void) {
            self.ref = ref
            self.handler = handler
        }
    }

    /// FourCharCode signature identifying this app's hot keys.
    private let signature: OSType = {
        // 'PRWr'
        let chars: [Character] = ["P", "R", "W", "r"]
        return chars.reduce(OSType(0)) { ($0 << 8) + OSType($1.asciiValue ?? 0) }
    }()

    /// hotKeyID.id -> registration.
    private var registrations: [UInt32: Registration] = [:]
    /// styleID -> hotKeyID.id, so per-style keys can be unregistered by style.
    private var styleKeyIDs: [UUID: UInt32] = [:]
    /// Reserved id for the single global palette hotkey.
    private let globalKeyID: UInt32 = 1
    /// Monotonic id source for per-style hotkeys (kept clear of globalKeyID).
    private var nextKeyID: UInt32 = 2

    private var eventHandler: EventHandlerRef?

    public init() {
        installEventHandlerIfNeeded()
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - HotkeyManaging

    public func registerGlobalHotkey(_ hotkey: Hotkey, action: @escaping () -> Void) throws {
        // Replace any prior global registration.
        if let existing = registrations[globalKeyID] {
            UnregisterEventHotKey(existing.ref)
            registrations[globalKeyID] = nil
        }
        let ref = try register(hotkey, id: globalKeyID)
        registrations[globalKeyID] = Registration(ref: ref, handler: action)
    }

    public func registerStyleHotkey(_ hotkey: Hotkey, styleID: UUID, action: @escaping (UUID) -> Void) throws {
        // Replace any prior registration for this style.
        unregisterStyleHotkey(styleID: styleID)

        let id = nextKeyID
        nextKeyID += 1

        let ref = try register(hotkey, id: id)
        registrations[id] = Registration(ref: ref, handler: { action(styleID) })
        styleKeyIDs[styleID] = id
    }

    public func unregisterStyleHotkey(styleID: UUID) {
        guard let id = styleKeyIDs.removeValue(forKey: styleID) else { return }
        if let reg = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(reg.ref)
        }
    }

    public func unregisterAll() {
        for reg in registrations.values {
            UnregisterEventHotKey(reg.ref)
        }
        registrations.removeAll()
        styleKeyIDs.removeAll()
    }

    // MARK: - Carbon plumbing

    private func register(_ hotkey: Hotkey, id: UInt32) throws -> EventHotKeyRef {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            throw PromptRewriterError.apiError("Failed to register hotkey (OSStatus \(status))")
        }
        return ref
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            manager.handlePress(id: hotKeyID.id)
            return noErr
        }

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
    }

    /// Invoked from the Carbon event handler; fire on the main queue since the
    /// handlers drive UI (palette, panel).
    private func handlePress(id: UInt32) {
        guard let handler = registrations[id]?.handler else { return }
        DispatchQueue.main.async {
            handler()
        }
    }
}
