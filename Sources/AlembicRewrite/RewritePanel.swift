//
//  RewritePanel.swift
//  AlembicRewrite
//
//  The review surface: a floating, non-activating NSPanel hosting SwiftUI.
//  Shows the captured selection (top, scrollable, dimmed), the streaming
//  rewrite below (tokens appended live), and the action row:
//  Accept (Return) / Retry (Cmd+R) / Cancel (Esc), plus an iterate field that
//  submits a follow-up instruction and re-runs the stream.
//
//  This file also defines the shared floating-panel infrastructure reused by
//  Palette.swift (same module): `NonActivatingPanel` and `VisualEffectBackground`.
//
//  The view model exposes published state; the integrator (App.swift) drives it
//  by appending tokens, flipping state, and wiring the Accept/Retry/Cancel/
//  Iterate callbacks to the LLM client + selection service. This file owns none
//  of that wiring; it owns only presentation.
//

import SwiftUI
import AppKit

// MARK: - Shared floating-panel infrastructure

/// A borderless, non-activating panel that can still become key so it receives
/// keyboard input WITHOUT activating (and thus stealing focus from) the app the
/// user is working in. This is the Spotlight / launcher behaviour: the target
/// app stays frontmost in spirit; the panel just floats above and takes keys.
///
/// Reused by both the RewritePanel and the Palette.
public final class NonActivatingPanel: NSPanel {
    /// Optional intercept for raw key events. Return `true` to consume the
    /// event; return `false` to fall through to the default handling. The
    /// Palette uses this to drive keyboard-first navigation; the RewritePanel
    /// leaves it `nil` and relies on SwiftUI keyboard shortcuts.
    public var keyDownHandler: ((NSEvent) -> Bool)?

    /// Optional click-away hook. Fired when the panel resigns key status (the
    /// user clicked into another app or window). The Palette and RewritePanel
    /// controllers use it to cancel and tear the floating surface down instead
    /// of leaving it stuck on screen (B1). Left `nil` by the HUD, which never
    /// becomes key.
    public var onResignKey: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    public override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// SwiftUI wrapper over `NSVisualEffectView` so both floating surfaces get the
/// slightly translucent HUD material behind their rounded content.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - View model

/// Streaming lifecycle of a rewrite, published to the view.
public enum RewritePhase: Equatable {
    /// A rewrite is streaming in; tokens are being appended.
    case streaming
    /// The stream finished cleanly; the rewrite is ready to accept.
    case completed
    /// The captured selection was empty; the panel shows a hint and closes.
    case emptySelection
    /// Something failed (missing key, API error, interrupted stream). Any
    /// partial text already streamed is kept so Retry can resume from context.
    case error(String)
}

/// Observable state for the review panel. The integrator owns the driving:
/// it sets `original`/`styleName`, appends tokens as they arrive, flips
/// `phase`, and supplies the four callbacks. The view is a pure function of
/// this object.
@MainActor
public final class RewritePanelViewModel: ObservableObject {
    /// The captured selection being rewritten (shown dimmed up top).
    @Published public var original: String
    /// The rewrite as it streams in.
    @Published public var rewrite: String
    /// Display name of the active style.
    @Published public var styleName: String
    /// Current streaming lifecycle phase.
    @Published public var phase: RewritePhase
    /// Bound to the iterate text field.
    @Published public var iterateText: String

    /// Fired when the user accepts the current rewrite (Return / Accept button).
    public var onAccept: ((String) -> Void)?
    /// Fired when the user asks to re-run the last request (Cmd+R / Retry).
    public var onRetry: (() -> Void)?
    /// Fired when the user dismisses the panel (Esc / Cancel button).
    public var onCancel: (() -> Void)?
    /// Fired when the user submits a follow-up instruction in the iterate field.
    /// The integrator appends it as a new user turn and re-streams.
    public var onIterate: ((String) -> Void)?

    public init(
        original: String = "",
        rewrite: String = "",
        styleName: String = "",
        phase: RewritePhase = .streaming,
        iterateText: String = ""
    ) {
        self.original = original
        self.rewrite = rewrite
        self.styleName = styleName
        self.phase = phase
        self.iterateText = iterateText
    }

    // Driving helpers the integrator calls from its streaming loop.

    /// Reset for a fresh stream (Retry or a new iterate turn).
    public func beginStreaming() {
        rewrite = ""
        phase = .streaming
    }

    /// Append one streamed delta.
    public func appendToken(_ delta: String) {
        rewrite += delta
    }

    /// Mark the stream complete.
    public func finish() {
        phase = .completed
    }

    /// Mark the stream failed (partial `rewrite` is preserved).
    public func fail(_ message: String) {
        phase = .error(message)
    }

    // Intent handlers the view calls.

    func accept() {
        // Only accept a finished stream. Accepting mid-stream would paste
        // half-finished text and log zero tokens (B5).
        guard phase == .completed else { return }
        onAccept?(rewrite)
    }

    func retry() {
        onRetry?()
    }

    func cancel() {
        onCancel?()
    }

    func submitIterate() {
        // Only iterate on a finished stream, so a follow-up never captures
        // partial assistant text as a completed turn (B6).
        guard phase == .completed else { return }
        let instruction = iterateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        iterateText = ""
        onIterate?(instruction)
    }
}

// MARK: - View

public struct RewritePanelView: View {
    @ObservedObject private var model: RewritePanelViewModel
    @FocusState private var iterateFocused: Bool

    public init(model: RewritePanelViewModel) {
        self.model = model
    }

    // Convenience for previews / the scaffold's default construction.
    public init() {
        self.init(model: RewritePanelViewModel(
            original: "make this prompt better",
            rewrite: "Rewrite the following into a clear, effective prompt…",
            styleName: "Effective prompt rewrite",
            phase: .completed
        ))
    }

    public var body: some View {
        GlassPanel(radius: AlembicMetrics.r3, material: .hudWindow) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                hairline
                VStack(alignment: .leading, spacing: 16) {
                    originalPane
                    rewritePane
                    // Iterate only makes sense once the stream has finished. Hiding
                    // it otherwise keeps an "iterate" input from appearing under an
                    // empty-selection or error layout (B14) and stops a mid-stream
                    // follow-up by construction (B6).
                    if model.phase == .completed {
                        iterateField
                    }
                }
                .padding(18)
                hairline
                actionRow
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 360)
        .tint(Alembic.accent)
    }

    /// Full-width hairline divider between the header, body, and action row.
    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: AlembicMetrics.hairline)
    }

    /// Small circular ✕ that cancels any in-flight stream and closes the panel,
    /// mirroring Cancel / Esc.
    private var closeButton: some View {
        Button {
            model.cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.mutedBase)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Alembic.accentSoft.opacity(0.5))
                )
                .overlay(
                    Circle().strokeBorder(Color.hairline, lineWidth: AlembicMetrics.hairline)
                )
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Alembic.accentVibrant)
                .shadow(color: AlembicUnderglow.glowColor, radius: AlembicUnderglow.glowRadius)
            Text(model.styleName.isEmpty ? "Rewrite" : model.styleName)
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            statusBadge
            closeButton
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.phase {
        case .streaming:
            StatusBadge(.streaming)
        case .completed:
            StatusBadge(.ready)
        case .emptySelection:
            StatusBadge(.empty, text: "No text selected")
        case .error:
            StatusBadge(.error)
        }
    }

    /// A solid, opaque reading surface (rule L5: never a text pane on glass).
    private func readingPane<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                    .fill(Color.inputBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                    .strokeBorder(Color.inputBorder, lineWidth: 1)
            )
    }

    private var originalPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Original")
            readingPane {
                ScrollView {
                    Text(model.original.isEmpty ? "—" : model.original)
                        .font(.alBody)
                        .foregroundStyle(Color.mutedBase)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
        }
    }

    @ViewBuilder
    private var rewritePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Rewrite")
            readingPane {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Top anchor so the view can pin to the start when a fresh
                        // stream begins, before following the tail as tokens arrive.
                        Color.clear.frame(height: 0).id("rewrite-top")
                        Group {
                            if case .error(let message) = model.phase {
                                errorBody(message)
                            } else if case .emptySelection = model.phase {
                                Text("Nothing was selected. Press any key to dismiss.")
                                    .font(.alBody)
                                    .foregroundStyle(Color.mutedBase)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(model.rewrite.isEmpty && model.phase == .streaming
                                     ? " " : model.rewrite)
                                    .font(.alBody)
                                    .foregroundStyle(Color.inkBase)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .id("rewrite-bottom")
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .onChange(of: model.phase) { newPhase in
                        // Pin to the top the moment a new stream starts, so the
                        // first tokens are never rendered mid-scroll.
                        if newPhase == .streaming && model.rewrite.isEmpty {
                            proxy.scrollTo("rewrite-top", anchor: .top)
                        }
                    }
                    .onChange(of: model.rewrite) { _ in
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("rewrite-bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func errorBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.alBody)
                .foregroundStyle(Color.danger)
            if !model.rewrite.isEmpty {
                Rectangle()
                    .fill(Color.hairline)
                    .frame(height: AlembicMetrics.hairline)
                Text(model.rewrite)
                    .font(.alBody)
                    .foregroundStyle(Color.mutedBase)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iterateField: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.accentText)
            TextField("Iterate: shorter, more direct, friendlier", text: $model.iterateText)
                .textFieldStyle(.plain)
                .font(.alInput)
                .foregroundStyle(Color.inkBase)
                .focused($iterateFocused)
                .onSubmit { model.submitIterate() }
            if !model.iterateText.isEmpty {
                Button {
                    model.submitIterate()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Alembic.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .fill(Alembic.accentSoft.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .strokeBorder(Color.inputBorder, lineWidth: AlembicMetrics.hairline)
        )
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            GlassButton("Cancel", style: .smoke) {
                model.cancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            GlassButton("Retry", style: .smoke) {
                model.retry()
            }
            .keyboardShortcut("r", modifiers: .command)

            // Accept is the primary affordance: gold, to stand apart from the
            // green accent used elsewhere (retained per Alembic convention).
            GlassButton("Accept", style: .gold, disabled: disableAccept) {
                model.accept()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var disableAccept: Bool {
        switch model.phase {
        case .completed: return model.rewrite.isEmpty
        // Accept stays disabled until the stream finishes, so a partial paste
        // with zero logged tokens is impossible (B5).
        case .streaming, .emptySelection, .error: return true
        }
    }
}

// MARK: - Controller

/// Owns the panel window for the review surface: builds it, positions it
/// centred on the active screen, and hands the SwiftUI view its view model.
/// The integrator retains one of these, calls `show(model:)` after capturing
/// the selection, and `close()` on Accept/Cancel.
@MainActor
public final class RewritePanelController {
    private var panel: NonActivatingPanel?

    public init() {}

    /// Present the review panel for the given model, centred on the screen that
    /// currently holds the mouse. Non-activating: the target app is not
    /// deactivated, but the panel becomes key so its field + shortcuts work.
    public func show(model: RewritePanelViewModel) {
        let hosting = NSHostingController(rootView: RewritePanelView(model: model))
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420)
        )
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        // Drag-to-select in the reading panes must not drag the whole window
        // (F7): disable background dragging on the review surface specifically.
        panel.isMovableByWindowBackground = false
        // Click-away dismissal: clicking back into the target app cancels the
        // review instead of leaving the panel stuck on top (B1). Detached in
        // `close()` so Accept/Cancel/Esc do not re-fire cancel.
        panel.onResignKey = { [weak model] in model?.cancel() }
        centre(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    public func close() {
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    private func centre(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + frame.height * 0.08
        )
        panel.setFrameOrigin(origin)
    }
}
