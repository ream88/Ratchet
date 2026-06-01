//
//  ReviewStore.swift
//  Ratchet
//
//  Local persistence for per-hunk review comments. A single shared store backs every
//  window so multiple repositories can be reviewed at once without clobbering the file.
//

import Foundation
import Combine

@MainActor
final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()

    /// Comments keyed by a stable composite of repo + commit + file + hunk header.
    @Published private(set) var comments: [String: ReviewComment] = [:]

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    // MARK: Keys

    /// Composite key. Uses control characters as separators so they never collide with path text.
    static func key(repositoryPath: String, commitSHA: String, filePath: String, hunkHeader: String) -> String {
        [repositoryPath, commitSHA, filePath, hunkHeader].joined(separator: "\u{1}")
    }

    // MARK: Lookup / mutation

    func comment(forKey key: String) -> ReviewComment? {
        comments[key]
    }

    func text(forKey key: String) -> String {
        comments[key]?.comment ?? ""
    }

    /// Updates (or clears) a comment. An empty/whitespace value removes the entry entirely so
    /// blank comments never leak into exports.
    func setText(_ text: String,
                 forKey key: String,
                 repositoryPath: String,
                 commitSHA: String,
                 filePath: String,
                 hunkHeader: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        if trimmed.isEmpty {
            if comments.removeValue(forKey: key) != nil { scheduleSave() }
            return
        }

        if var existing = comments[key] {
            existing.comment = text
            existing.updatedAt = now
            comments[key] = existing
        } else {
            comments[key] = ReviewComment(
                id: UUID(),
                repositoryPath: repositoryPath,
                commitSHA: commitSHA,
                filePath: filePath,
                hunkHeader: hunkHeader,
                comment: text,
                createdAt: now,
                updatedAt: now
            )
        }
        scheduleSave()
    }

    // MARK: Persistence

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Ratchet", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reviews.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: ReviewComment].self, from: data) {
            comments = decoded
        }
    }

    /// Debounced write so rapid typing doesn't thrash the disk.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = comments
        let url = fileURL
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
