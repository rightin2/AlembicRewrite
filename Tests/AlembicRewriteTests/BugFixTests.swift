import XCTest
@testable import AlembicRewrite

/// Behaviour tests for the redesign bug-report fixes that are unit-testable at
/// the view-model level: palette hover-vs-arrow gating (B2), filter highlight
/// reset (B3), and review-panel Accept/iterate gating on stream completion
/// (B5, B6).
@MainActor
final class BugFixTests: XCTestCase {

    // MARK: - Helpers

    private func makeStyle(_ name: String, order: Int) -> Style {
        Style(
            name: name,
            promptTemplate: "{{selection}}",
            provider: .anthropic,
            model: "claude-haiku-4-5",
            temperature: 0.3,
            sortOrder: order
        )
    }

    private func paletteModel() -> PaletteViewModel {
        PaletteViewModel(styles: [
            makeStyle("Alpha", order: 0),
            makeStyle("Beta", order: 1),
            makeStyle("Gamma", order: 2)
        ])
    }

    // MARK: - B3: filter resets highlight to the first result

    func testFilterMutationResetsHighlightToFirst() {
        let model = paletteModel()
        model.moveDown()
        model.moveDown()
        XCTAssertEqual(model.selectedIndex, 2)

        // Typing a filter must move the highlight back to the top result so
        // Return can never run a middle row the user did not aim at.
        model.appendCharacters("a")
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testDeleteBackwardResetsHighlightToFirst() {
        let model = paletteModel()
        model.appendCharacters("a")   // filter set, highlight 0
        model.moveDown()              // highlight 1 within results
        XCTAssertGreaterThan(model.selectedIndex, 0)

        model.deleteBackward()
        XCTAssertEqual(model.selectedIndex, 0)
    }

    // MARK: - B2: hover does not fight keyboard navigation

    func testHoverIgnoredWhenPointerHasNotMovedSinceArrowing() {
        let model = paletteModel()
        model.currentMouseLocation = { CGPoint(x: 10, y: 10) }

        model.moveDown()                       // highlight 1, hover locked at (10,10)
        XCTAssertEqual(model.selectedIndex, 1)

        // Auto-scroll re-fires hover under a stationary cursor: must be ignored.
        model.hover(index: 0)
        XCTAssertEqual(model.selectedIndex, 1)
    }

    func testHoverHonouredOncePointerMoves() {
        let model = paletteModel()
        model.currentMouseLocation = { CGPoint(x: 10, y: 10) }
        model.moveDown()                       // lock at (10,10)

        // The pointer physically moves, so a genuine hover is honoured.
        model.currentMouseLocation = { CGPoint(x: 40, y: 40) }
        model.hover(index: 0)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    // MARK: - B5: Accept only on a completed stream

    func testAcceptIgnoredWhileStreaming() {
        let model = RewritePanelViewModel(
            original: "in", rewrite: "partial", styleName: "S", phase: .streaming
        )
        var accepted: String?
        model.onAccept = { accepted = $0 }

        model.accept()
        XCTAssertNil(accepted, "Accept must be a no-op mid-stream (B5)")

        model.phase = .completed
        model.accept()
        XCTAssertEqual(accepted, "partial")
    }

    // MARK: - B6: iterate only on a completed stream

    func testIterateIgnoredWhileStreaming() {
        let model = RewritePanelViewModel(
            original: "in", rewrite: "partial", styleName: "S", phase: .streaming
        )
        model.iterateText = "make it shorter"
        var iterated: String?
        model.onIterate = { iterated = $0 }

        model.submitIterate()
        XCTAssertNil(iterated, "Iterate must be a no-op mid-stream (B6)")
        XCTAssertEqual(model.iterateText, "make it shorter", "text preserved when rejected")

        model.phase = .completed
        model.submitIterate()
        XCTAssertEqual(iterated, "make it shorter")
        XCTAssertEqual(model.iterateText, "", "iterate field cleared on submit")
    }
}
