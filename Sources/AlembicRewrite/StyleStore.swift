//
//  StyleStore.swift
//  AlembicRewrite
//
//  Implements: StyleStoring (JSON-file-backed — see storage decision in
//  Protocols.swift). Persists to
//  ~/Library/Application Support/AlembicRewrite/styles.json
//

import Foundation

public final class StyleStore: StyleStoring {
    private let overrideDirectory: URL?

    /// - Parameter directory: override the storage directory (tests inject a
    ///   temp dir). `nil` uses the shared Application Support location.
    public init(directory: URL? = nil) {
        self.overrideDirectory = directory
    }

    private func fileURL() throws -> URL {
        let dir = try overrideDirectory ?? StorageLocations.defaultDirectory()
        return dir.appendingPathComponent("styles.json")
    }

    public func all() throws -> [Style] {
        let styles = try JSONFile.read([Style].self, from: fileURL(), fallback: [])
        return styles.sorted { $0.sortOrder < $1.sortOrder }
    }

    public func save(_ style: Style) throws {
        var styles = try all()
        if let idx = styles.firstIndex(where: { $0.id == style.id }) {
            styles[idx] = style
        } else {
            styles.append(style)
        }
        try persist(styles)
    }

    public func delete(id: UUID) throws {
        var styles = try all()
        styles.removeAll { $0.id == id }
        try persist(styles)
    }

    public func reorder(_ styles: [Style]) throws {
        // Assign ascending sortOrder in the given order, preserving all other fields.
        let renumbered = styles.enumerated().map { index, style -> Style in
            var s = style
            s.sortOrder = index
            return s
        }
        try persist(renumbered)
    }

    public func seedDefaultsIfEmpty() throws {
        guard try all().isEmpty else { return }
        try persist(Self.defaultStyles())
    }

    private func persist(_ styles: [Style]) throws {
        let sorted = styles.sorted { $0.sortOrder < $1.sortOrder }
        try JSONFile.write(sorted, to: fileURL())
    }

    // MARK: - Built-in defaults

    static func defaultStyles() -> [Style] {
        [
            Style(
                name: "Effective prompt rewrite",
                promptTemplate: effectivePromptRewriteTemplate,
                provider: .anthropic,
                model: "claude-sonnet-4-6",
                temperature: 0.3,
                sortOrder: 0
            ),
            Style(
                name: "Make concise",
                promptTemplate: """
                Rewrite the text below so it is as short and clear as possible \
                while keeping every fact and instruction intact. Cut filler, \
                redundancy, and hedging. Preserve the original tone and meaning. \
                Return only the rewritten text, with no preamble or commentary.

                {{selection}}
                """,
                provider: .anthropic,
                model: "claude-haiku-4-5",
                temperature: 0.3,
                sortOrder: 1
            ),
            Style(
                name: "Professional tone",
                promptTemplate: """
                Rewrite the text below in a clear, professional, and courteous \
                tone suitable for workplace communication. Keep the meaning and \
                all concrete details unchanged, fix grammar and phrasing, and \
                avoid slang or overly casual wording. Return only the rewritten \
                text, with no preamble or commentary.

                {{selection}}
                """,
                provider: .openai,
                model: "gpt-4o-mini",
                temperature: 0.4,
                sortOrder: 2
            ),
        ]
    }

    /// System-style template that turns a rough, half-formed prompt into a
    /// well-structured, outcome-first prompt. ~200 words of instruction.
    static let effectivePromptRewriteTemplate = """
    You are a prompt engineer. Rewrite the rough prompt below into a single, \
    polished prompt that will get a strong result from a capable AI model. \
    Produce a prompt that leads with the desired outcome, then supplies the \
    context and constraints an assistant needs to hit it on the first try.

    Follow these principles:
    - Open with the goal: state plainly what the assistant should produce and \
    what "good" looks like, before any background.
    - Preserve every concrete detail, fact, name, number, and constraint from \
    the original. Never invent requirements the author did not imply.
    - Organise the request logically: task, then relevant context, then \
    constraints, then the exact output format expected.
    - Make implicit expectations explicit (audience, tone, length, format) only \
    where the original clearly intends them.
    - Use direct, unambiguous language and positive instructions that name the \
    path to the result rather than listing what to avoid.
    - Keep it faithful to the author's intent and voice; clarify, do not expand \
    the scope.

    Return only the rewritten prompt as plain text, ready to paste. Do not add \
    explanations, preambles, headings, or commentary.

    Rough prompt to rewrite:
    {{selection}}
    """
}
