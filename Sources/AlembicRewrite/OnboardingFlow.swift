//
//  OnboardingFlow.swift
//  AlembicRewrite
//
//  The pure state machine and UserDefaults persistence behind the resumable
//  onboarding wizard (design section 7). Kept free of SwiftUI and AppKit so the
//  transition logic and the launch-gate decision are unit-testable in isolation.
//
//  The view layer (OnboardingWizardView in Onboarding.swift) owns the current
//  step as SwiftUI @State and calls into these pure helpers to decide where each
//  affordance goes, then persists through OnboardingState.
//

import Foundation

// MARK: - Steps

/// The seven wizard stages. Raw values ARE the persisted `onboarding.lastStep`
/// integers (design 7.1): 0 welcome, 1-4 the four core steps, 5 the settings
/// tour, 6 finish. Do not renumber; resume points depend on these.
enum OnboardingStep: Int, CaseIterable, Equatable {
    case welcome = 0
    case permission = 1
    case apiKey = 2
    case firstRewrite = 3
    case tour = 4
    case settingsTour = 5
    case finish = 6

    /// The four numbered core steps that carry a filled dot on the progress rail
    /// and a "Step N of 4" counter. Welcome, the settings tour, and finish are
    /// framed differently (no dot / a labelled chip / a completion screen).
    var isCore: Bool { (1...4).contains(rawValue) }

    /// 1-based index for the "Step N of 4" counter, or nil for the non-core
    /// stages.
    var coreNumber: Int? { isCore ? rawValue : nil }

    /// Linear successor in the canonical order, or nil past finish.
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }

    /// Linear predecessor, or nil at welcome. Back never drops below welcome and
    /// carries no side effects (design 7.2).
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// Only the API key, first-rewrite, and palette-tour steps carry the inline
    /// "Skip this step" affordance. Permission is the hard gate and has none;
    /// welcome, settings tour, and finish are not core steps.
    var allowsInlineSkip: Bool {
        self == .apiKey || self == .firstRewrite || self == .tour
    }
}

// MARK: - Skip-tour outcome

/// Result of the footer "Skip tour / Skip setup" affordance. Skipping is only
/// permitted when Accessibility is granted, because permission is the single
/// non-skippable gate (design 7.2). When it is missing, the wizard routes to the
/// permission step and shows a gate note instead of completing.
struct SkipTourOutcome: Equatable {
    let target: OnboardingStep
    /// True only when the skip actually lands on finish (granted). A gated skip
    /// does not mark onboarding complete.
    let markCompleted: Bool
    /// True when the skip was blocked by the missing permission and the
    /// permission step should surface the "Grant Accessibility first" note.
    let showGateNote: Bool
}

// MARK: - Launch decision

/// What the app should do with the wizard window at launch or on a mid-flow
/// permission miss (design 7.1). `.none` means run silent in the menu bar.
enum OnboardingLaunchOutcome: Equatable {
    case none
    case show(OnboardingStep)
}

// MARK: - Transitions (pure)

/// Namespaced pure transition functions. The view calls these; the tests drive
/// them directly. Nothing here reads UserDefaults or touches the UI.
enum OnboardingFlow {

    /// Primary-CTA advance. Linear from the current step; finish has no next so
    /// it returns finish unchanged. Callers gate the permission -> apiKey and
    /// apiKey -> firstRewrite edges on their own conditions (a disabled CTA and
    /// the "I'll add later" fallback respectively), so advance itself is purely
    /// the canonical successor.
    static func advance(from step: OnboardingStep) -> OnboardingStep {
        step.next ?? step
    }

    /// Back button: previous state, clamped at welcome, no side effects.
    static func back(from step: OnboardingStep) -> OnboardingStep {
        step.previous ?? .welcome
    }

    /// Inline "Skip this step" (steps 2-4). Advances one state without any
    /// completion side effect. Returns nil for steps that carry no inline skip.
    static func skipStep(from step: OnboardingStep) -> OnboardingStep? {
        guard step.allowsInlineSkip else { return nil }
        return step.next
    }

    /// Footer skip. Granted -> jump to finish and complete; missing -> route to
    /// permission with the gate note, no completion.
    static func skipTour(granted: Bool) -> SkipTourOutcome {
        if granted {
            return SkipTourOutcome(target: .finish, markCompleted: true, showGateNote: false)
        } else {
            return SkipTourOutcome(target: .permission, markCompleted: false, showGateNote: true)
        }
    }

    /// The launch / mid-flow-miss gate (design 7.1), expressed over primitives so
    /// it is testable without UserDefaults. `satisfied` folds the completed flag
    /// and the version check together (see OnboardingState.isSatisfied).
    ///
    /// - not satisfied            -> resume at `lastStep` (default welcome)
    /// - satisfied but not granted -> jump straight to the permission step
    /// - satisfied and granted     -> no window, menu bar only
    static func launchOutcome(
        satisfied: Bool,
        granted: Bool,
        lastStep: OnboardingStep
    ) -> OnboardingLaunchOutcome {
        if !satisfied { return .show(lastStep) }
        if !granted { return .show(.permission) }
        return .none
    }
}

// MARK: - Persistence

/// Thin UserDefaults wrapper for the three onboarding keys (design 7.1). A
/// struct, not an ObservableObject: the wizard reads it once at construction and
/// writes through it on each transition; there is nothing to observe.
struct OnboardingState {

    /// Bump when a release adds steps, to re-surface onboarding for existing
    /// users (design 7.1, `onboarding.version`).
    static let currentVersion = 1

    private enum Key {
        static let completed = "onboarding.completed"
        static let lastStep = "onboarding.lastStep"
        static let version = "onboarding.version"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var completed: Bool {
        get { defaults.bool(forKey: Key.completed) }
        nonmutating set { defaults.set(newValue, forKey: Key.completed) }
    }

    /// Persisted resume point. Reads clamp to a valid step; writes store the raw
    /// value.
    var lastStep: OnboardingStep {
        get { OnboardingStep(rawValue: defaults.integer(forKey: Key.lastStep)) ?? .welcome }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.lastStep) }
    }

    var version: Int {
        get { defaults.integer(forKey: Key.version) }
        nonmutating set { defaults.set(newValue, forKey: Key.version) }
    }

    /// Completed AND on the current onboarding version. A stale version behaves
    /// as "not completed" so a release that adds steps re-surfaces the wizard.
    var isSatisfied: Bool { completed && version >= Self.currentVersion }

    /// Record a resume point as the user advances. Also stamps the current
    /// version so a resumed flow is bound to this build.
    func recordStep(_ step: OnboardingStep) {
        lastStep = step
        version = Self.currentVersion
    }

    /// Reaching finish (or a granted footer skip): mark complete, stamp version,
    /// and clear the resume point back to welcome for any future replay.
    func markCompleted() {
        completed = true
        version = Self.currentVersion
        lastStep = .welcome
    }
}
