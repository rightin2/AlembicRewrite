//
//  Onboarding.swift
//  AlembicRewrite
//
//  First-run onboarding shown when AXIsProcessTrusted() is false. Explains the
//  Accessibility permission (needed for the synthetic Cmd+C / Cmd+V selection
//  dance) and links straight to the System Settings pane.
//

import SwiftUI
import AppKit

public struct OnboardingView: View {
    /// Opens the Accessibility pane (wired to SelectionServicing in the app).
    private let onOpenSettings: () -> Void
    /// Re-checks whether the permission is now granted. Returns the live value.
    private let onRecheck: () -> Bool
    /// Closes the onboarding window.
    private let onDismiss: () -> Void

    @State private var granted = false

    public init(
        onOpenSettings: @escaping () -> Void = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        },
        onRecheck: @escaping () -> Bool = { false },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onOpenSettings = onOpenSettings
        self.onRecheck = onRecheck
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Prompt Rewriter")
                        .font(.title2).bold()
                    Text("One quick permission and you're set.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Prompt Rewriter rewrites whatever text you have selected in any app. To read your selection and paste the result back, macOS needs to grant it the Accessibility permission.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Label("Click Open System Settings below.", systemImage: "1.circle")
                Label("Enable Prompt Rewriter under Accessibility.", systemImage: "2.circle")
                Label("Come back here and click Re-check.", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if granted {
                Label("Permission granted. You're ready to go.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Open System Settings") { onOpenSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Re-check") { granted = onRecheck() }
                Spacer()
                Button(granted ? "Done" : "Later") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 340)
        .onAppear { granted = onRecheck() }
    }
}
