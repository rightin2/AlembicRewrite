//
//  UpdateChecker.swift
//  AlembicRewrite
//
//  In-app update check. On launch (async, never blocking the UI) the app asks
//  the GitHub Releases API whether a newer AlembicRewrite build exists, and if
//  so surfaces a small glass banner offering "Update now" (opens the .dmg
//  download) or "Later" (dismisses that version). The whole thing is silent on
//  failure: no network, a 500, or a malformed payload leaves the user with no
//  visible error, exactly as if no check had run.
//
//  Layers:
//    SemanticVersion  - tolerant major.minor.patch parse + Comparable.
//    AppVersion       - the running build's version (Bundle, else "1.1.0").
//    UpdateStatus     - the outcome of one network check.
//    UpdateChecking   - protocol; GitHubUpdateChecker is the impl (URLSession
//                       injected so tests drive it with a mock protocol).
//    UpdatePolicy     - ObservableObject: 24h throttle, per-version dismissal,
//                       published `updateAvailable` the UI binds to. All state
//                       persists to UserDefaults under AlembicRewrite.update.*.
//    UpdateBanner     - the glass banner view (Update now / Later).
//
//  No client data ever touches this path (guardrail 2): the only request is an
//  unauthenticated GET to the public releases endpoint, carrying nothing.
//

import Foundation
import SwiftUI
import AppKit

// MARK: - Semantic version

/// A tolerant `major.minor.patch` version. Parsing strips a leading `v`, treats
/// a missing minor/patch as `0`, and reads the leading integer of each dotted
/// component (so `1.2.3-beta.1` parses as `1.2.3`). Comparison is the usual
/// left-to-right numeric ordering.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse `"v1.2.3"`, `"1.2"`, `"1"`, or `"1.2.3-rc.1"`. Returns `nil` only
    /// when the first component has no leading digits at all.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        func leadingInt(_ sub: Substring?) -> Int? {
            guard let sub else { return nil }
            let digits = sub.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        guard let maj = leadingInt(parts.first) else { return nil }
        self.major = maj
        self.minor = leadingInt(parts.count > 1 ? parts[1] : nil) ?? 0
        self.patch = leadingInt(parts.count > 2 ? parts[2] : nil) ?? 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

// MARK: - Running build version

/// The running build's version. `Bundle.main` has no `CFBundleShortVersionString`
/// under `swift run` (a bare SPM executable ships no Info.plist), so we fall back
/// to the compiled constant. Bump `fallback` in lockstep with the real release
/// version so dev builds compare sanely.
public enum AppVersion {
    /// Compiled-in fallback used when no bundle version is present.
    public static let fallback = "1.1.0"

    /// The current version string, from the bundle when available.
    public static var currentString: String {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let bundled, !bundled.trimmingCharacters(in: .whitespaces).isEmpty {
            return bundled
        }
        return fallback
    }

    /// The current version, parsed. Guaranteed non-nil (fallback is well-formed).
    public static var current: SemanticVersion {
        SemanticVersion(currentString) ?? SemanticVersion(major: 1, minor: 1, patch: 0)
    }
}

// MARK: - Check outcome

/// The result of one update check.
///  - upToDate:  no newer release than the running build.
///  - available: a newer release exists. `releaseURL` is the human release page;
///               `downloadURL` is the `.dmg` asset when present, else the same
///               release page.
///  - failed:    network error, non-2xx, or unparseable payload. Silent: the
///               UI shows nothing, exactly as if the check had not run.
public enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(version: String, releaseURL: URL, downloadURL: URL)
    case failed
}

// MARK: - Checker

/// One network check against the releases endpoint. Injectable so the policy and
/// tests can supply a mock transport.
public protocol UpdateChecking: Sendable {
    func check() async -> UpdateStatus
}

/// Queries GitHub's "latest release" endpoint for `rightin2/AlembicRewrite`,
/// compares the tag against the running build, and reports the outcome. Never
/// throws: every failure path collapses to `.failed`.
public struct GitHubUpdateChecker: UpdateChecking {
    /// The public "latest release" endpoint.
    public static let endpoint = URL(string: "https://api.github.com/repos/rightin2/AlembicRewrite/releases/latest")!

    private let session: URLSession
    private let currentVersion: SemanticVersion

    /// A short-timeout session so a launch-time check can never hang the app.
    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public init(session: URLSession? = nil,
                currentVersion: SemanticVersion = AppVersion.current) {
        self.session = session ?? GitHubUpdateChecker.defaultSession()
        self.currentVersion = currentVersion
    }

    public func check() async -> UpdateStatus {
        var request = URLRequest(url: GitHubUpdateChecker.endpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AlembicRewrite", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return .failed
            }
            return Self.parse(data, currentVersion: currentVersion)
        } catch {
            return .failed
        }
    }

    /// Parse a `releases/latest` payload into a status. Pure and static so tests
    /// can exercise the parse without a session. Any missing/garbled field yields
    /// `.failed`.
    static func parse(_ data: Data, currentVersion: SemanticVersion) -> UpdateStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let latest = SemanticVersion(tag),
              let htmlString = obj["html_url"] as? String,
              let releaseURL = URL(string: htmlString) else {
            return .failed
        }

        guard latest > currentVersion else {
            return .upToDate
        }

        // Prefer the .dmg asset's direct download; fall back to the release page.
        var downloadURL = releaseURL
        if let assets = obj["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.lowercased().hasSuffix(".dmg"),
                   let urlString = asset["browser_download_url"] as? String,
                   let url = URL(string: urlString) {
                    downloadURL = url
                    break
                }
            }
        }

        return .available(version: latest.description, releaseURL: releaseURL, downloadURL: downloadURL)
    }
}

// MARK: - Policy (throttle + dismissal + published state)

/// The available-update surface the UI binds to.
public struct UpdateInfo: Equatable, Sendable {
    public let version: String
    public let releaseURL: URL
    public let downloadURL: URL
}

/// Orchestrates the launch-time check: runs at most once per 24 hours, persists
/// the last-check date and the last dismissed version, and publishes
/// `updateAvailable` for the UI. A dismissed version stays quiet; a strictly
/// newer version re-prompts. Every failure is silent.
@MainActor
public final class UpdatePolicy: ObservableObject {

    /// Non-nil when a newer, non-dismissed version is available. The UI shows the
    /// banner while this is set and clears it on dismissal.
    @Published public private(set) var updateAvailable: UpdateInfo?

    private let checker: UpdateChecking
    private let defaults: UserDefaults
    private let now: () -> Date
    private let currentVersion: SemanticVersion

    /// Minimum spacing between automatic checks.
    static let throttleInterval: TimeInterval = 24 * 60 * 60

    // Persisted keys, namespaced per the design.
    static let lastCheckKey = "AlembicRewrite.update.lastCheckDate"
    static let dismissedVersionKey = "AlembicRewrite.update.dismissedVersion"

    public init(checker: UpdateChecking = GitHubUpdateChecker(),
                defaults: UserDefaults = .standard,
                currentVersion: SemanticVersion = AppVersion.current,
                now: @escaping () -> Date = Date.init) {
        self.checker = checker
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
    }

    /// The launch entry point. Skips silently when a check ran within the last
    /// 24 hours; otherwise records the attempt and runs one check.
    public func checkOnLaunch() async {
        guard isDue else { return }
        await runCheck()
    }

    /// A manual check that ignores the 24h throttle (for a future "Check for
    /// updates" menu item). Still records the check time.
    public func checkNow() async {
        await runCheck()
    }

    /// Dismiss the currently offered version: it will not prompt again, but a
    /// strictly newer release later will.
    public func dismiss() {
        if let v = updateAvailable?.version {
            defaults.set(v, forKey: Self.dismissedVersionKey)
        }
        updateAvailable = nil
    }

    /// Open the download URL in the user's browser and clear the banner.
    public func openDownload() {
        if let url = updateAvailable?.downloadURL {
            NSWorkspace.shared.open(url)
        }
        updateAvailable = nil
    }

    // MARK: internals

    private var isDue: Bool {
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.throttleInterval
    }

    private func runCheck() async {
        // Record the attempt up front so a slow or failing check cannot cause a
        // second launch to hammer the endpoint.
        defaults.set(now(), forKey: Self.lastCheckKey)

        let status = await checker.check()
        switch status {
        case .upToDate, .failed:
            // Silent: leave any existing banner untouched only if nothing new;
            // a failed check never clears a legitimately-shown banner from a
            // prior successful check in the same session.
            if case .failed = status { return }
            updateAvailable = nil
        case let .available(version, releaseURL, downloadURL):
            guard !isDismissed(version) else {
                updateAvailable = nil
                return
            }
            updateAvailable = UpdateInfo(version: version, releaseURL: releaseURL, downloadURL: downloadURL)
        }
    }

    /// True when `version` is not strictly newer than the last dismissed version,
    /// i.e. the user already said "Later" to this or a newer one. A release
    /// strictly newer than the dismissed marker re-prompts.
    private func isDismissed(_ version: String) -> Bool {
        guard let dismissedRaw = defaults.string(forKey: Self.dismissedVersionKey),
              let dismissed = SemanticVersion(dismissedRaw),
              let candidate = SemanticVersion(version) else {
            return false
        }
        return candidate <= dismissed
    }
}

// MARK: - Banner UI

/// The glass update banner. Shown while `policy.updateAvailable` is set. "Update
/// now" opens the download and clears the banner; "Later" dismisses this version.
///
/// It reuses the component library (GlassPanel, GlassButton) so it matches the
/// menu and review panel. Drop it at the top of the menu content (see the
/// INTEGRATION note below) or present it as a small sheet.
public struct UpdateBanner: View {
    @ObservedObject var policy: UpdatePolicy

    public init(policy: UpdatePolicy) {
        self.policy = policy
    }

    public var body: some View {
        if let info = policy.updateAvailable {
            GlassPanel(radius: AlembicMetrics.r2, material: .popover) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Alembic.accentVibrant)
                        Text("Update available")
                            .font(.alTitle)
                            .foregroundStyle(Color.inkBase)
                    }
                    Text("Version \(info.version) is ready to download. You have \(AppVersion.currentString).")
                        .font(.alBody)
                        .foregroundStyle(Color.mutedBase)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        GlassButton("Update now", style: .primaryFlat) {
                            policy.openDownload()
                        }
                        GlassButton("Later", style: .quiet) {
                            policy.dismiss()
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }
}

// INTEGRATION(update-checker): two-line hookup for the integrator.
//
//  1. In `AppDelegate` add a stored policy and kick the check off on launch
//     (non-blocking) inside `applicationDidFinishLaunching`:
//
//         let updatePolicy = UpdatePolicy()
//         // ...inside applicationDidFinishLaunching:
//         Task { await updatePolicy.checkOnLaunch() }
//
//  2. Pass `updatePolicy` into `MenuContent` and render the banner at the top of
//     its `VStack` so it appears above `spendCard`:
//
//         UpdateBanner(policy: updatePolicy)
//
//     (`UpdatePolicy` is an ObservableObject, so the menu re-renders when a
//     newer version is found; the banner draws nothing while `updateAvailable`
//     is nil.)
