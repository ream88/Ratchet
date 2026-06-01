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
            // Only include hunks that actually have a comment.
            let commentedHunks = file.hunks.compactMap { hunk -> (DiffHunk, String)? in
                let key = ReviewStore.key(
                    repositoryPath: repositoryPath,
                    commitSHA: commit.id,
                    filePath: hunk.filePath,
                    hunkHeader: hunk.header
                )
                let text = store.text(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : (hunk, text)
            }
            guard !commentedHunks.isEmpty else { continue }

            wroteAny = true
            out += "\n## \(file.path)\n"
            for (hunk, comment) in commentedHunks {
                out += "\n### Hunk: \(hunk.header)\n"
                out += "\nComment:\n\(comment)\n"
                out += "\nRelevant diff:\n\n```diff\n\(hunk.rawText)\n```\n"
            }
        }

        if !wroteAny {
            out += "\n_No review comments were written for this commit._\n"
        }
        return out
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
