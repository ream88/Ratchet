//
//  Models.swift
//  Ratchet
//
//  Core value types for commits, diffs, and review comments.
//

import Foundation

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
            let prefix: String
            switch line.kind {
            case .context: prefix = " "
            case .addition: prefix = "+"
            case .deletion: prefix = "-"
            }
            out += "\n" + prefix + line.content
        }
        return out
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
    let commitSHA: String
    let filePath: String
    let hunkHeader: String
    var comment: String
    var createdAt: Date
    var updatedAt: Date
}
