import XCTest
@testable import AlembicRewrite

final class PlaceholderTests: XCTestCase {
    /// Trivial passing test proving the target compiles and links against the
    /// AlembicRewrite module. Module agents add real suites alongside this.
    func testScaffoldCompiles() {
        let style = Style(
            name: "Effective prompt rewrite",
            promptTemplate: "Rewrite this prompt: {{selection}}",
            provider: .anthropic,
            model: "claude-3-5-sonnet-latest",
            temperature: 0.7,
            sortOrder: 0
        )
        XCTAssertEqual(style.provider, .anthropic)
        XCTAssertTrue(style.promptTemplate.contains("{{selection}}"))
    }
}
