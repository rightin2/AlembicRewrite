//
//  RewriteHUD.swift
//  AlembicRewrite
//
//  The silent-replace HUD: a small floating pill shown near the mouse while a
//  direct-hotkey rewrite runs with no review panel. It shows a spinner and
//  "Rewriting…" with a small ✕ to cancel, then disappears the instant the result
//  is pasted. On error it morphs into a brief message: transient errors (empty
//  selection) auto-dismiss after ~3s; other errors stay until clicked.
//
//  Frosted material + Alembic tokens, matching the review panel's look.
//

import SwiftUI
import AppKit

// MARK: - View model

@MainActor
public final class HUDViewModel: ObservableObject {
    public enum Phase: Equatable {
        /// The rewrite is streaming; spinner + "Rewriting…" + cancel ✕.
        case rewriting
        /// A failure message. `sticky` = stays until clicked; otherwise the
        /// coordinator auto-dismisses it.
        case error(String, sticky: Bool)
    }

    @Published public var phase: Phase = .rewriting

    /// Fired by the ✕ while rewriting.
    public var onCancel: (() -> Void)?
    /// Fired by a click on a sticky error pill.
    public var onDismiss: (() -> Void)?

    public init() {}

    func showError(_ message: String, sticky: Bool) {
        phase = .error(message, sticky: sticky)
    }
}

// MARK: - View

struct HUDView: View {
    @ObservedObject var model: HUDViewModel
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassPanel(radius: AlembicMetrics.r2, material: .hudWindow) {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .fixedSize()
        .contentShape(RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous))
        .onTapGesture {
            if case .error(_, let sticky) = model.phase, sticky {
                model.onDismiss?()
            }
        }
        .tint(Alembic.accent)
        // Spring entry (section 5.4): settle-without-overshoot, suppressed under
        // Reduce Motion.
        .scaleEffect(shown ? 1 : 0.92)
        .opacity(shown ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { shown = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .rewriting:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Rewriting")
                    .font(.alBody)
                    .foregroundStyle(Color.inkBase)
                Button {
                    model.onCancel?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.mutedBase)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Alembic.accentSoft.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
        case .error(let message, let sticky):
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Alembic.warning)
                Text(message)
                    .font(.alBody)
                    .foregroundStyle(Color.inkBase)
                    .frame(maxWidth: 320, alignment: .leading)
                if sticky {
                    Text("Click to dismiss")
                        .font(.alState)
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.mutedBase)
                }
            }
        }
    }
}

// MARK: - Controller

/// Owns the HUD panel: a tiny non-activating floating pill positioned just above
/// the mouse. Never becomes key, so it never steals keyboard focus from the app
/// the user is working in.
@MainActor
public final class HUDController {
    private var panel: NonActivatingPanel?

    public init() {}

    public func show(model: HUDViewModel) {
        close()
        let hosting = NSHostingController(rootView: HUDView(model: model))
        let panel = NonActivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44))
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        position(panel)
        // orderFront (not key): the HUD must never take keyboard focus, so a
        // synthesized Cmd+V during paste still targets the user's app.
        panel.orderFront(nil)
        self.panel = panel
    }

    public func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// Place the pill just above and to the right of the mouse, clamped to the
    /// screen that holds the cursor.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y + 18)
        if let frame = screen?.visibleFrame {
            origin.x = min(max(frame.minX + 8, origin.x), frame.maxX - size.width - 8)
            origin.y = min(max(frame.minY + 8, origin.y), frame.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}
