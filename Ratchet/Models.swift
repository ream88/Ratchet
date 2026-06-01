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
    var lines: [DiffLine]

    /// Reconstructs the raw unified-diff text for this hunk (used in exports).
    var rawText: String {
        var out = header
        for line in lines {
            out += "\n" + marker(for: line.kind) + line.content
        }
        return out
    }

    /// Stable identity for the chunk based on its *content*, not its line ranges.
    ///
    /// The `@@ … @@` header is deliberately excluded because its line numbers shift
    /// whenever unrelated edits land above the hunk. Hashing the file path plus the
    /// marked body lines means: identical changes keep the same hash (review state and
    /// comments persist), while a rewrite produces a new hash that must be reviewed again.
    var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(filePath.utf8))
        hasher.update(data: Data("\n".utf8))
        for line in lines {
            hasher.update(data: Data((marker(for: line.kind) + line.content + "\n").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func marker(for kind: DiffLineKind) -> String {
        switch kind {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        }
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
    var createdAt: Date
    var updatedAt: Date
}
