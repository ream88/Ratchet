//
//  Models.swift
//  Ratchet
//
//  Core value types for commits, diffs, and review comments.
//

import Foundation
import CryptoKit

// MARK: - Git

/// A branch as reported by `git branch --all`.
struct GitBranch: Identifiable, Hashable {
    /// The short ref name, e.g. `main` or `origin/feature`.
    let name: String
    /// Whether this is the currently checked-out branch.
    let isCurrent: Bool
    /// Whether this ref lives under `remotes/`.
    let isRemote: Bool

    var id: String { name }
}

struct GitCommit: Identifiable, Hashable {
    let id: String          // full SHA
    let shortSHA: String
    let title: String
    let author: String
    let date: Date?
    let additions: Int
    let deletions: Int
}

// MARK: - Diff

enum DiffLineKind {
    case context
    case addition
    case deletion
}

struct DiffLine: Identifiable {
    let id: UUID
    let kind: DiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
}

struct DiffHunk: Identifiable {
    let id: UUID
    let filePath: String
    let header: String
    let oldStartLine: Int?
    let newStartLine: Int?
    let lines: [DiffLine]

    /// Added/removed line counts, tallied once at init for the chunk's diff-stat badge.
    let additions: Int
    let deletions: Int

    /// Each line as a +/-/space marker plus content. Computed once at init because it backs
    /// both hashing and line-comment anchoring, which are read on hot rendering paths.
    let markedLines: [String]

    /// Stable identity for the chunk based on its *content*, not its line ranges. Computed
    /// once at init — recomputing this SHA per access was a major source of lag on big diffs.
    ///
    /// The `@@ … @@` header is deliberately excluded because its line numbers shift whenever
    /// unrelated edits land above the hunk: identical changes keep the same hash (review state
    /// and comments persist), while a rewrite produces a new hash that must be reviewed again.
    let contentHash: String

    /// Path-independent identity of the *change itself* — the added/removed lines only, ignoring
    /// the file path and the surrounding context lines. The same edit (e.g. a module rename) in
    /// differently-surrounded files produces the same signature, which powers "apply to all
    /// identical hunks" suggestions. Distinct from `contentHash`, which folds in the file path
    /// *and* context and keys persisted per-file review state.
    let contentSignature: String

    init(id: UUID, filePath: String, header: String,
         oldStartLine: Int?, newStartLine: Int?, lines: [DiffLine]) {
        self.id = id
        self.filePath = filePath
        self.header = header
        self.oldStartLine = oldStartLine
        self.newStartLine = newStartLine
        self.lines = lines

        var adds = 0, dels = 0
        // The change-only lines (no context) back `contentSignature`: the same edit in two
        // files sits in different surrounding code, so context must be excluded for them to match.
        var changed: [String] = []
        let marked = lines.map { line -> String in
            let m = DiffHunk.marker(for: line.kind) + line.content
            switch line.kind {
            case .addition: adds += 1; changed.append(m)
            case .deletion: dels += 1; changed.append(m)
            case .context: break
            }
            return m
        }
        self.markedLines = marked
        self.additions = adds
        self.deletions = dels
        self.contentHash = DiffHunk.hash(filePath: filePath, prefix: "\n", lines: marked)
        self.contentSignature = DiffHunk.hash(filePath: "", prefix: "\u{2}dup\u{2}", lines: changed)
    }

    /// Reconstructs the raw unified-diff text for this hunk (used in exports).
    var rawText: String {
        var out = header
        for line in lines {
            out += "\n" + DiffHunk.marker(for: line.kind) + line.content
        }
        return out
    }

    /// Content-based identity for a comment anchored to a contiguous range of lines.
    /// Like `contentHash`, this survives line-number shifts and changes when the lines do.
    func lineCommentContentHash(forRange range: ClosedRange<Int>) -> String {
        DiffHunk.hash(filePath: filePath, prefix: "\u{1}line\u{1}", lines: Array(markedLines[range]))
    }

    /// The marked content of a line range — stored with a comment so it can be re-anchored later.
    func anchorLines(forRange range: ClosedRange<Int>) -> [String] {
        Array(markedLines[range])
    }

    /// Finds where a stored anchor's lines currently sit in this hunk, or nil if they no
    /// longer match (i.e. the comment has resolved because the code changed).
    func locate(anchorLines anchor: [String]) -> ClosedRange<Int>? {
        guard !anchor.isEmpty, anchor.count <= markedLines.count else { return nil }
        let lastStart = markedLines.count - anchor.count
        for start in 0...lastStart where Array(markedLines[start..<start + anchor.count]) == anchor {
            return start...(start + anchor.count - 1)
        }
        return nil
    }

    private static func marker(for kind: DiffLineKind) -> String {
        switch kind {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        }
    }

    private static func hash(filePath: String, prefix: String, lines: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(filePath.utf8))
        hasher.update(data: Data(prefix.utf8))
        for line in lines {
            hasher.update(data: Data((line + "\n").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct DiffFile: Identifiable {
    let id: UUID
    let path: String
    var hunks: [DiffHunk]
    /// Set for files git reported as binary (no textual hunks).
    var isBinary: Bool = false
}

// MARK: - Review comments

/// Cached per-commit indicators for the sidebar, persisted by git commit SHA so they show
/// immediately for every commit — not just ones opened this session.
struct CommitBadge {
    var fullyReviewed: Bool
    var hasComments: Bool
}

struct ReviewComment: Codable, Identifiable {
    let id: UUID
    let repositoryPath: String
    /// Stable, content-based chunk identity. The primary key for review state.
    let contentHash: String
    let filePath: String
    /// Last commit/header the chunk was seen in — informational, refreshed on each sighting.
    var commitSHA: String
    var hunkHeader: String
    var comment: String
    var isReviewed: Bool
    /// For line-range comments: the marked content of the anchored lines, used to re-locate
    /// the comment within a hunk. Nil for whole-chunk comments.
    var anchorLines: [String]?
    var createdAt: Date
    var updatedAt: Date
}
