//
//  SelectionService.swift
//  PromptRewriter
//
//  Implements: SelectionServicing
//
//  The clipboard "dance": save NSPasteboard contents -> synthesize Cmd+C ->
//  poll changeCount until the selection lands -> read it -> restore the prior
//  clipboard. replaceSelection places the rewrite, synthesizes Cmd+V, then
//  restores the caller's prior clipboard. The prior clipboard is ALWAYS
//  restored, even on error (restore runs in a defer block).
//
//  Synthetic key events require the Accessibility permission
//  (AXIsProcessTrusted). hasAccessibilityPermission / openAccessibilitySettings
//  drive the onboarding flow.
//

import AppKit
import Carbon.HIToolbox

public final class SelectionService: SelectionServicing {

    // Virtual key codes for the copy/paste dance.
    private let keyC: CGKeyCode = CGKeyCode(kVK_ANSI_C)
    private let keyV: CGKeyCode = CGKeyCode(kVK_ANSI_V)

    /// How long to wait for the target app to answer a synthetic Cmd+C before
    /// giving up and treating the selection as empty.
    private let captureTimeout: TimeInterval = 1.0
    /// Polling granularity while waiting for the pasteboard changeCount to move.
    private let pollInterval: TimeInterval = 0.01
    /// Grace period after Cmd+V before restoring the prior clipboard, so the
    /// target app has finished reading the pasteboard.
    private let pasteSettleDelay: TimeInterval = 0.12

    public init() {}

    // MARK: - Capture

    public func captureSelection() async throws -> String {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        // Always restore the caller's clipboard, whatever happens below.
        defer { restore(saved, to: pasteboard) }

        let beforeCount = pasteboard.changeCount
        // Clear so a stale value can't masquerade as a fresh copy if the app
        // never answers (some apps leave the pasteboard untouched on empty copy).
        pasteboard.clearContents()

        postCommandKeystroke(keyC)

        // Wait for the target app to write the selection to the pasteboard.
        let landed = await waitForChangeCount(above: beforeCount, on: pasteboard)
        guard landed else { return "" }

        return pasteboard.string(forType: .string) ?? ""
    }

    // MARK: - Replace

    public func replaceSelection(with text: String) async throws {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        // Restore the prior clipboard even if pasting throws.
        defer { restore(saved, to: pasteboard) }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandKeystroke(keyV)

        // Give the frontmost app time to consume the pasteboard before we
        // overwrite it with the restored contents.
        try? await Task.sleep(nanoseconds: UInt64(pasteSettleDelay * 1_000_000_000))
    }

    // MARK: - Accessibility permission

    public func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    public func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Clipboard snapshot / restore

    /// A copy of every item currently on the pasteboard, preserved across the
    /// dance so the user's clipboard survives untouched.
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var typed: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typed[type] = data
                }
            }
            if !typed.isEmpty { items.append(typed) }
        }
        return PasteboardSnapshot(items: items)
    }

    private func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        var newItems: [NSPasteboardItem] = []
        for typed in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in typed {
                item.setData(data, forType: type)
            }
            newItems.append(item)
        }
        pasteboard.writeObjects(newItems)
    }

    // MARK: - Synthetic keystrokes

    /// Post a Cmd+<key> keystroke (key down + up) into the frontmost app via
    /// CGEvent. Requires Accessibility permission to reach other processes.
    private func postCommandKeystroke(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)

        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand

        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Polling

    /// Poll the pasteboard changeCount until it exceeds `baseline` or the
    /// capture timeout elapses. Returns true if the count moved.
    private func waitForChangeCount(above baseline: Int, on pasteboard: NSPasteboard) async -> Bool {
        let deadline = Date().addingTimeInterval(captureTimeout)
        while Date() < deadline {
            if pasteboard.changeCount > baseline {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }
}
