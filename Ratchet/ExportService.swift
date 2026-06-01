//
//  ExportService.swift
//  Ratchet
//
//  Builds a Markdown review document and saves it via NSSavePanel.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportService {

    /// Renders all non-empty comments for a commit into the Markdown format the AI agent consumes.
    static func markdown(
        commit: GitCommit,
        repositoryPath: String,
        branch: String?,
        files: [DiffFile],
        store: ReviewStore
    ) -> String {
        var out = "# Review comments for commit \(commit.shortSHA)\n\n"
        out += "Repository: \(repositoryPath)\n"
        out += "Commit: \(commit.id)\n"
        out += "Branch: \(branch ?? "—")\n"
        out += "Title: \(commit.title)\n"

        var wroteAny = false
        for file in files {
            var fileSection = ""
            for hunk in file.hunks {
                var hunkSection = ""

                // Whole-chunk note.
                let key = ReviewStore.key(repositoryPath: repositoryPath, contentHash: hunk.contentHash)
                let note = store.text(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    hunkSection += "\nComment:\n\(note)\n"
                }

                // Line-range comments, in line order.
                let lineComments = store.lineComments(repositoryPath: repositoryPath, filePath: hunk.filePath)
                    .compactMap { record -> (ClosedRange<Int>, ReviewComment)? in
                        guard let anchor = record.anchorLines,
                              let range = hunk.locate(anchorLines: anchor),
                              !record.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return nil }
                        return (range, record)
                    }
                    .sorted { $0.0.lowerBound < $1.0.lowerBound }

                for (range, record) in lineComments {
                    hunkSection += "\nComment on \(lineLabel(for: range, in: hunk)):\n\(record.comment)\n"
                    hunkSection += "\nRelevant lines:\n\n```diff\n\(snippet(for: range, in: hunk))\n```\n"
                }

                guard !hunkSection.isEmpty else { continue }
                fileSection += "\n### Hunk: \(hunk.header)\n" + hunkSection
                if note.isEmpty == false {
                    // Whole-chunk note: include the full hunk for context.
                    fileSection += "\nRelevant diff:\n\n```diff\n\(hunk.rawText)\n```\n"
                }
            }

            guard !fileSection.isEmpty else { continue }
            wroteAny = true
            out += "\n## \(file.path)\n" + fileSection
        }

        if !wroteAny {
            out += "\n_No review comments were written for this commit._\n"
        }
        return out
    }

    /// Renders every comment in the repository — across all commits — into one Markdown file.
    /// Diff context comes from each record's stored anchor lines (for line comments); whole-chunk
    /// comments show their hunk header. No git calls are needed, so unvisited commits are covered.
    static func markdownForAllComments(
        repositoryPath: String,
        commits: [GitCommit],
        store: ReviewStore
    ) -> String {
        var out = "# All review comments\n\nRepository: \(repositoryPath)\n"

        let all = store.allComments(repositoryPath: repositoryPath)
        if all.isEmpty {
            out += "\n_No review comments recorded._\n"
            return out
        }

        let byCommit = Dictionary(grouping: all, by: \.commitSHA)
        let titles = Dictionary(commits.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })

        // Newest-first to match the sidebar; commits not on the current branch come last.
        let orderedSHAs = commits.map(\.id).filter { byCommit[$0] != nil }
        let leftovers = byCommit.keys.filter { !orderedSHAs.contains($0) }.sorted()

        for sha in orderedSHAs + leftovers {
            guard let comments = byCommit[sha] else { continue }
            let short = String(sha.prefix(7))
            out += "\n## Commit \(short)"
            if let title = titles[sha] { out += " — \(title)" }
            out += "\n"

            let byFile = Dictionary(grouping: comments, by: \.filePath)
            for file in byFile.keys.sorted() {
                out += "\n### \(file)\n"
                let fileComments = (byFile[file] ?? []).sorted {
                    ($0.hunkHeader, $0.createdAt) < ($1.hunkHeader, $1.createdAt)
                }
                for comment in fileComments {
                    if let anchor = comment.anchorLines, !anchor.isEmpty {
                        out += "\n**Lines** (\(comment.hunkHeader)):\n\(comment.comment)\n"
                        out += "\n```diff\n\(anchor.joined(separator: "\n"))\n```\n"
                    } else {
                        out += "\n**Hunk \(comment.hunkHeader):**\n\(comment.comment)\n"
                    }
                }
            }
        }
        return out
    }

    private static func lineLabel(for range: ClosedRange<Int>, in hunk: DiffHunk) -> String {
        func number(_ i: Int) -> String {
            let line = hunk.lines[i]
            return (line.newLineNumber ?? line.oldLineNumber).map(String.init) ?? "?"
        }
        return range.count == 1
            ? "line \(number(range.lowerBound))"
            : "lines \(number(range.lowerBound))–\(number(range.upperBound))"
    }

    private static func snippet(for range: ClosedRange<Int>, in hunk: DiffHunk) -> String {
        Array(hunk.markedLines[range]).joined(separator: "\n")
    }

    /// Presents a save panel and writes the Markdown. Returns the saved URL, or nil if cancelled.
    @MainActor
    @discardableResult
    static func save(markdown: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.title = "Export Review Comments"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try? markdown.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
