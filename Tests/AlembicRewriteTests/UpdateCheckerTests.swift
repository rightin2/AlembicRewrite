import XCTest
@testable import AlembicRewrite

/// Tests for the in-app update feature (UpdateChecker.swift): semantic-version
/// parsing and comparison, the GitHub release parse + network check driven by a
/// mock URLProtocol, and the UpdatePolicy throttle / per-version dismissal /
/// silent-failure behaviour driven by a stub checker on an isolated
/// UserDefaults suite.

// MARK: - Mock URL transport

/// A URLProtocol that returns a canned response (or error) so the checker's real
/// network path can be exercised without hitting GitHub.
final class MockURLProtocol: URLProtocol {
    /// Set per-test. Returns (status, body) to succeed, or throws to simulate a
    /// transport error. Guarded by a lock because URLProtocol runs off the test's
    /// thread.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private static let lock = NSLock()

    static func setHandler(_ h: (@Sendable (URLRequest) throws -> (Int, Data))?) {
        lock.lock(); defer { lock.unlock() }
        handler = h
    }
    static func currentHandler() -> (@Sendable (URLRequest) throws -> (Int, Data))? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = MockURLProtocol.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func releaseJSON(tag: String, dmg: String? = "https://example.com/AlembicRewrite.dmg") -> Data {
    var assets = ""
    if let dmg {
        assets = """
        , "assets": [
            {"name": "AlembicRewrite.dmg", "browser_download_url": "\(dmg)"}
        ]
        """
    }
    let json = """
    {
        "tag_name": "\(tag)",
        "html_url": "https://github.com/rightin2/AlembicRewrite/releases/tag/\(tag)"
        \(assets)
    }
    """
    return Data(json.utf8)
}

// MARK: - Stub checker (for policy tests)

/// A checker that returns a fixed status and counts invocations.
final class StubChecker: UpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: UpdateStatus
    private(set) var callCount = 0

    init(_ status: UpdateStatus) { self._status = status }

    func setStatus(_ s: UpdateStatus) { lock.lock(); _status = s; lock.unlock() }

    func check() async -> UpdateStatus {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        return _status
    }
}

// MARK: - Tests

final class UpdateCheckerTests: XCTestCase {

    // MARK: SemanticVersion

    func testSemverParsesTolerant() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("V2.0.0"), SemanticVersion(major: 2, minor: 0, patch: 0))
        // Missing patch and minor default to zero.
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion("3"), SemanticVersion(major: 3, minor: 0, patch: 0))
        // Prerelease suffix is tolerated (leading digits of each component).
        XCTAssertEqual(SemanticVersion("1.2.3-rc.1"), SemanticVersion(major: 1, minor: 2, patch: 3))
        // Whitespace trimmed.
        XCTAssertEqual(SemanticVersion(" v1.4.0 "), SemanticVersion(major: 1, minor: 4, patch: 0))
        // Non-numeric leading component is unparseable.
        XCTAssertNil(SemanticVersion("beta"))
        XCTAssertNil(SemanticVersion(""))
    }

    func testSemverComparison() {
        XCTAssertLessThan(SemanticVersion("1.1.0")!, SemanticVersion("1.2.0")!)
        XCTAssertLessThan(SemanticVersion("1.1.9")!, SemanticVersion("1.2.0")!)
        XCTAssertLessThan(SemanticVersion("1.1.0")!, SemanticVersion("2.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.1.0")!, SemanticVersion("1.1.1")!)
        XCTAssertEqual(SemanticVersion("1.1")!, SemanticVersion("1.1.0")!)
        XCTAssertGreaterThan(SemanticVersion("2.0.0")!, SemanticVersion("1.9.9")!)
    }

    func testAppVersionFallbackWellFormed() {
        // The compiled fallback must always parse (used when no bundle version).
        XCTAssertNotNil(SemanticVersion(AppVersion.fallback))
        XCTAssertEqual(SemanticVersion(AppVersion.fallback), SemanticVersion(major: 1, minor: 1, patch: 0))
    }

    // MARK: Checker network path

    func testNewerVersionIsAvailable() async {
        MockURLProtocol.setHandler { _ in (200, releaseJSON(tag: "v1.2.0")) }
        defer { MockURLProtocol.setHandler(nil) }

        let checker = GitHubUpdateChecker(session: mockSession(),
                                          currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0))
        let status = await checker.check()

        guard case let .available(version, releaseURL, downloadURL) = status else {
            return XCTFail("expected .available, got \(status)")
        }
        XCTAssertEqual(version, "1.2.0")
        XCTAssertEqual(releaseURL.absoluteString,
                       "https://github.com/rightin2/AlembicRewrite/releases/tag/v1.2.0")
        XCTAssertEqual(downloadURL.absoluteString, "https://example.com/AlembicRewrite.dmg")
    }

    func testSameVersionIsUpToDate() async {
        MockURLProtocol.setHandler { _ in (200, releaseJSON(tag: "v1.1.0")) }
        defer { MockURLProtocol.setHandler(nil) }

        let checker = GitHubUpdateChecker(session: mockSession(),
                                          currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0))
        let status = await checker.check()
        XCTAssertEqual(status, .upToDate)
    }

    func testOlderVersionIsUpToDate() async {
        MockURLProtocol.setHandler { _ in (200, releaseJSON(tag: "v1.0.0")) }
        defer { MockURLProtocol.setHandler(nil) }

        let checker = GitHubUpdateChecker(session: mockSession(),
                                          currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0))
        let status = await checker.check()
        XCTAssertEqual(status, .upToDate)
    }

    func testDownloadFallsBackToReleasePageWhenNoDmg() async {
        MockURLProtocol.setHandler { _ in (200, releaseJSON(tag: "v1.2.0", dmg: nil)) }
        defer { MockURLProtocol.setHandler(nil) }

        let checker = GitHubUpdateChecker(session: mockSession(),
                                          currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0))
        let status = await checker.check()
        guard case let .available(_, releaseURL, downloadURL) = status else {
            return XCTFail("expected .available, got \(status)")
        }
        XCTAssertEqual(downloadURL, releaseURL)
    }

    func testNon2xxIsFailed() async {
        MockURLProtocol.setHandler { _ in (503, Data("nope".utf8)) }
        defer { MockURLProtocol.setHandler(nil) }

        let checker = GitHubUpdateChecker(session: mockSession(),
                                          currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0))
        let status = await checker.check()
        XCTAssertEqual(status, .failed)
    }

    func testTransportErrorIsFailed() async {
        MockURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
        defer { MockURLProtocol.setHandler(nil) }

        let checker = GitHubUpdateChecker(session: mockSession(),
                                          currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0))
        let status = await checker.check()
        XCTAssertEqual(status, .failed)
    }

    func testMalformedPayloadIsFailed() async {
        MockURLProtocol.setHandler { _ in (200, Data("{ not json".utf8)) }
        defer { MockURLProtocol.setHandler(nil) }

        let checker = GitHubUpdateChecker(session: mockSession(),
                                          currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0))
        let status = await checker.check()
        XCTAssertEqual(status, .failed)
    }

    // MARK: Policy — availability + dismissal

    @MainActor
    func testPolicySurfacesNewerVersion() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let checker = StubChecker(.available(
            version: "1.2.0",
            releaseURL: URL(string: "https://example.com/rel")!,
            downloadURL: URL(string: "https://example.com/app.dmg")!))
        let policy = UpdatePolicy(checker: checker, defaults: defaults,
                                  currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                  now: { Date() })

        await policy.checkOnLaunch()
        XCTAssertEqual(policy.updateAvailable?.version, "1.2.0")
    }

    @MainActor
    func testDismissalSuppressesSameVersionButNotNewer() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let checker = StubChecker(.available(
            version: "1.2.0",
            releaseURL: URL(string: "https://example.com/rel")!,
            downloadURL: URL(string: "https://example.com/app.dmg")!))

        // First launch offers 1.2.0; the user dismisses it.
        let policy1 = UpdatePolicy(checker: checker, defaults: defaults,
                                   currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                   now: { Date(timeIntervalSince1970: 0) })
        await policy1.checkOnLaunch()
        XCTAssertEqual(policy1.updateAvailable?.version, "1.2.0")
        policy1.dismiss()
        XCTAssertNil(policy1.updateAvailable)

        // A later check (past the throttle) that still offers 1.2.0 stays quiet.
        let policy2 = UpdatePolicy(checker: checker, defaults: defaults,
                                   currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                   now: { Date(timeIntervalSince1970: 200_000) })
        await policy2.checkOnLaunch()
        XCTAssertNil(policy2.updateAvailable, "dismissed version must not re-prompt")

        // But a strictly newer release re-prompts despite the earlier dismissal.
        checker.setStatus(.available(
            version: "1.3.0",
            releaseURL: URL(string: "https://example.com/rel2")!,
            downloadURL: URL(string: "https://example.com/app2.dmg")!))
        let policy3 = UpdatePolicy(checker: checker, defaults: defaults,
                                   currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                   now: { Date(timeIntervalSince1970: 400_000) })
        await policy3.checkOnLaunch()
        XCTAssertEqual(policy3.updateAvailable?.version, "1.3.0")
    }

    // MARK: Policy — throttle

    @MainActor
    func testThrottleSkipsWithin24Hours() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let checker = StubChecker(.upToDate)
        var clock = Date(timeIntervalSince1970: 1_000_000)

        let policy = UpdatePolicy(checker: checker, defaults: defaults,
                                  currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                  now: { clock })

        await policy.checkOnLaunch()
        XCTAssertEqual(checker.callCount, 1)

        // 12 hours later: still throttled, no second network call.
        clock = clock.addingTimeInterval(12 * 60 * 60)
        await policy.checkOnLaunch()
        XCTAssertEqual(checker.callCount, 1, "check within 24h must be skipped")

        // 25 hours after the first: due again.
        clock = Date(timeIntervalSince1970: 1_000_000 + 25 * 60 * 60)
        await policy.checkOnLaunch()
        XCTAssertEqual(checker.callCount, 2, "check after 24h must run")
    }

    @MainActor
    func testCheckNowIgnoresThrottle() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let checker = StubChecker(.upToDate)
        let policy = UpdatePolicy(checker: checker, defaults: defaults,
                                  currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                  now: { Date(timeIntervalSince1970: 0) })

        await policy.checkOnLaunch()
        await policy.checkNow()
        XCTAssertEqual(checker.callCount, 2, "manual check bypasses the throttle")
    }

    // MARK: Policy — silent failure

    @MainActor
    func testFailedCheckLeavesNoBannerAndNoCorruption() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let checker = StubChecker(.failed)
        let policy = UpdatePolicy(checker: checker, defaults: defaults,
                                  currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                  now: { Date(timeIntervalSince1970: 0) })

        await policy.checkOnLaunch()
        XCTAssertNil(policy.updateAvailable, "a failed check surfaces nothing")
        // No dismissed marker written on failure.
        XCTAssertNil(defaults.string(forKey: UpdatePolicy.dismissedVersionKey))
    }

    @MainActor
    func testUpToDateClearsNothingHarmful() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let checker = StubChecker(.upToDate)
        let policy = UpdatePolicy(checker: checker, defaults: defaults,
                                  currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
                                  now: { Date(timeIntervalSince1970: 0) })

        await policy.checkOnLaunch()
        XCTAssertNil(policy.updateAvailable)
    }

    // MARK: helpers

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "UpdateCheckerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }
}
