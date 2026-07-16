import XCTest
@testable import AlembicRewrite

/// Unit tests for the onboarding state machine and persistence (design 7.2 /
/// 7.1). Pure transitions and the launch-gate decision are exercised directly;
/// OnboardingState is driven against an isolated UserDefaults suite so the tests
/// never touch the real domain.
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Step metadata

    func testCoreStepsAreOneThroughFour() {
        XCTAssertEqual(OnboardingStep.welcome.coreNumber, nil)
        XCTAssertEqual(OnboardingStep.permission.coreNumber, 1)
        XCTAssertEqual(OnboardingStep.apiKey.coreNumber, 2)
        XCTAssertEqual(OnboardingStep.firstRewrite.coreNumber, 3)
        XCTAssertEqual(OnboardingStep.tour.coreNumber, 4)
        XCTAssertEqual(OnboardingStep.settingsTour.coreNumber, nil)
        XCTAssertEqual(OnboardingStep.finish.coreNumber, nil)
    }

    func testInlineSkipOnlyOnStepsTwoThroughFour() {
        XCTAssertFalse(OnboardingStep.welcome.allowsInlineSkip)
        XCTAssertFalse(OnboardingStep.permission.allowsInlineSkip)
        XCTAssertTrue(OnboardingStep.apiKey.allowsInlineSkip)
        XCTAssertTrue(OnboardingStep.firstRewrite.allowsInlineSkip)
        XCTAssertTrue(OnboardingStep.tour.allowsInlineSkip)
        XCTAssertFalse(OnboardingStep.settingsTour.allowsInlineSkip)
        XCTAssertFalse(OnboardingStep.finish.allowsInlineSkip)
    }

    // MARK: - Advance / back

    func testAdvanceIsLinearAndStopsAtFinish() {
        XCTAssertEqual(OnboardingFlow.advance(from: .welcome), .permission)
        XCTAssertEqual(OnboardingFlow.advance(from: .permission), .apiKey)
        XCTAssertEqual(OnboardingFlow.advance(from: .apiKey), .firstRewrite)
        XCTAssertEqual(OnboardingFlow.advance(from: .firstRewrite), .tour)
        XCTAssertEqual(OnboardingFlow.advance(from: .tour), .settingsTour)
        XCTAssertEqual(OnboardingFlow.advance(from: .settingsTour), .finish)
        XCTAssertEqual(OnboardingFlow.advance(from: .finish), .finish)
    }

    func testBackNeverDropsBelowWelcome() {
        XCTAssertEqual(OnboardingFlow.back(from: .welcome), .welcome)
        XCTAssertEqual(OnboardingFlow.back(from: .permission), .welcome)
        XCTAssertEqual(OnboardingFlow.back(from: .firstRewrite), .apiKey)
        XCTAssertEqual(OnboardingFlow.back(from: .finish), .settingsTour)
    }

    // MARK: - Inline skip

    func testSkipStepAdvancesOnlyForSkippableSteps() {
        XCTAssertEqual(OnboardingFlow.skipStep(from: .apiKey), .firstRewrite)
        XCTAssertEqual(OnboardingFlow.skipStep(from: .firstRewrite), .tour)
        XCTAssertEqual(OnboardingFlow.skipStep(from: .tour), .settingsTour)
        XCTAssertNil(OnboardingFlow.skipStep(from: .welcome))
        XCTAssertNil(OnboardingFlow.skipStep(from: .permission))
        XCTAssertNil(OnboardingFlow.skipStep(from: .settingsTour))
    }

    // MARK: - Skip tour (the hard gate)

    func testSkipTourGrantedCompletesToFinish() {
        let out = OnboardingFlow.skipTour(granted: true)
        XCTAssertEqual(out.target, .finish)
        XCTAssertTrue(out.markCompleted)
        XCTAssertFalse(out.showGateNote)
    }

    func testSkipTourWithoutPermissionRoutesToPermissionAndDoesNotComplete() {
        let out = OnboardingFlow.skipTour(granted: false)
        XCTAssertEqual(out.target, .permission)
        XCTAssertFalse(out.markCompleted)
        XCTAssertTrue(out.showGateNote)
    }

    // MARK: - Launch gate

    func testLaunchResumesAtLastStepWhenNotSatisfied() {
        XCTAssertEqual(
            OnboardingFlow.launchOutcome(satisfied: false, granted: false, lastStep: .apiKey),
            .show(.apiKey)
        )
        XCTAssertEqual(
            OnboardingFlow.launchOutcome(satisfied: false, granted: true, lastStep: .welcome),
            .show(.welcome)
        )
    }

    func testLaunchJumpsToPermissionWhenSatisfiedButRevoked() {
        XCTAssertEqual(
            OnboardingFlow.launchOutcome(satisfied: true, granted: false, lastStep: .welcome),
            .show(.permission)
        )
    }

    func testLaunchIsSilentWhenSatisfiedAndGranted() {
        XCTAssertEqual(
            OnboardingFlow.launchOutcome(satisfied: true, granted: true, lastStep: .welcome),
            .none
        )
    }

    // MARK: - Persistence

    private func freshState() -> (OnboardingState, UserDefaults) {
        let suite = "onboarding.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (OnboardingState(defaults: defaults), defaults)
    }

    func testDefaultsAreUnsatisfiedAndAtWelcome() {
        let (state, _) = freshState()
        XCTAssertFalse(state.completed)
        XCTAssertFalse(state.isSatisfied)
        XCTAssertEqual(state.lastStep, .welcome)
    }

    func testRecordStepPersistsResumePointAndVersion() {
        let (state, _) = freshState()
        state.recordStep(.firstRewrite)
        XCTAssertEqual(state.lastStep, .firstRewrite)
        XCTAssertEqual(state.version, OnboardingState.currentVersion)
        XCTAssertFalse(state.completed)
    }

    func testMarkCompletedSatisfiesAndClearsResumePoint() {
        let (state, _) = freshState()
        state.recordStep(.tour)
        state.markCompleted()
        XCTAssertTrue(state.completed)
        XCTAssertTrue(state.isSatisfied)
        XCTAssertEqual(state.lastStep, .welcome)
    }

    func testStaleVersionIsNotSatisfied() {
        let (state, _) = freshState()
        state.completed = true
        state.version = OnboardingState.currentVersion - 1
        XCTAssertFalse(state.isSatisfied)
    }

    func testClampsOutOfRangeLastStep() {
        let (state, defaults) = freshState()
        defaults.set(99, forKey: "onboarding.lastStep")
        XCTAssertEqual(state.lastStep, .welcome)
    }
}
