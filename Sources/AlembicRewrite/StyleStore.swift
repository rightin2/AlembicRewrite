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

    public func migrateAlembicRewriterIfMissing() throws {
        var styles = try all()
        guard !styles.contains(where: { $0.name == Self.alembicRewriterName }) else { return }
        // Insert at the front: push every existing style back one slot, then
        // prepend the AlembicRewriter style at sortOrder 0.
        for i in styles.indices { styles[i].sortOrder += 1 }
        styles.append(Self.alembicRewriterStyle())
        try persist(styles)
    }

    private func persist(_ styles: [Style]) throws {
        let sorted = styles.sorted { $0.sortOrder < $1.sortOrder }
        try JSONFile.write(sorted, to: fileURL())
    }

    // MARK: - Built-in defaults

    static let alembicRewriterName = "AlembicRewriter"

    /// The AlembicRewriter default style: Directional Prompting rewriter on
    /// Haiku, first in the list, bound to its own direct hotkey Cmd+Shift+R.
    static func alembicRewriterStyle() -> Style {
        Style(
            name: alembicRewriterName,
            promptTemplate: alembicRewriterTemplate,
            provider: .anthropic,
            model: "claude-haiku-4-5",
            temperature: 0.3,
            hotkey: Hotkey(
                keyCode: HotkeyCarbon.keyCode(for: "r")!,
                modifiers: HotkeyCarbon.command | HotkeyCarbon.shift
            ),
            sortOrder: 0
        )
    }

    static func defaultStyles() -> [Style] {
        [
            alembicRewriterStyle(),
            Style(
                name: "Effective prompt rewrite",
                promptTemplate: effectivePromptRewriteTemplate,
                provider: .anthropic,
                model: "claude-sonnet-4-6",
                temperature: 0.3,
                sortOrder: 1
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
                sortOrder: 2
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
                sortOrder: 3
            ),
        ]
    }

    /// The AlembicRewriter system prompt (Directional Prompting rewriter).
    /// Exact content of design/alembic-rewriter-prompt.txt.
    static let alembicRewriterTemplate = """
    You rewrite prompts using the Directional Prompting method: two stacked layers, both required.

    LAYER 1 - OUTCOME. The rewritten prompt opens with a block that names the destination:

    Goal: <one sentence>
    Success means:
      - <required output element>
      - <constraint: format, tone, length, schema>
    Stop when: <explicit stopping condition>
    Constraints: <only true invariants> (optional, for agentic prompts)

    Rules for the block:
    1. Goal is one sentence. If it needs two, it is two goals: split them.
    2. Success criteria are checkable. "Returns valid JSON matching schema X" beats "high quality output".
    3. Stopping condition is explicit, e.g. "stop after presenting the plan and wait for approval".
    4. Reserve ALWAYS/NEVER/MUST for true invariants only. Decorative absolutes bleed signal from real ones.

    LAYER 2 - DIRECTION. Inside that frame, every sentence names the path forward with positive verbs.

    The five rules:
    1. Lead with the verb of the correct action: trace, build, use, read, return, write, ask, check.
    2. Describe the destination, not the failure modes. "Return JSON matching this schema" beats "do not return prose".
    3. Replace every prohibition with its positive replacement: every "don't X" has a sister "do Y" that makes X structurally impossible.
    4. Make the correct behavior the only behavior described. A fully populated correct path leaves the wrong path no foothold.
    5. Cut hedges, warnings, and meta-commentary ("be careful with...", "watch out for..."). Replace with the concrete positive action.

    Rewrite examples:
    - "Don't make assumptions" -> "Read the file before answering"
    - "Don't be verbose" -> "Answer in one or two sentences"
    - "Avoid creating unnecessary files" -> "Edit the existing file at <path>"
    - "Try not to break tests" -> "Run the tests after every edit and keep them green"

    AUDIT PASS. Scan the original for: don't, do not, never, avoid, refrain, instead of, rather than, not allowed, prohibited, forbidden, won't, shouldn't, "be careful", "watch out", "make sure you don't". Rewrite each occurrence as its positive replacement.

    Negation survives in only four cases:
    1. Hard safety boundaries (pair the refusal with a positive action).
    2. Disambiguating near-identical paths ("use bun test, not npm test").
    3. Acceptable space too large to enumerate ("do not modify infrastructure files").
    4. A specific banned item narrower than any positive paraphrase ("no console.log in production code").
    Outside these four, cut or rewrite the negation.

    PRESERVE: every requirement, constraint, preference, and open question from the original, and the author's voice. Group scattered points under clear headings. Add nothing the author did not ask for. If the original asks for discussion before action, make that the stopping condition.

    FINAL CHECK before answering: outcome block present; negation count near zero; every ALWAYS/NEVER a true invariant; every sentence names a destination or a step toward it.

    Output ONLY the rewritten prompt, ready to paste. No preamble, no explanation.

    Prompt to rewrite:
    {{selection}}
    """

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
