//
//  ReviewStore.swift
//  Ratchet
//
//  Local persistence for review state, keyed by the *content* of each chunk so that
//  a rewritten chunk is treated as new work. A single shared store backs every window
//  so multiple repositories can be reviewed at once without clobbering the file.
//

import Foundation
import Combine

@MainActor
final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()

    /// Records keyed by `repositoryPath + contentHash`.
    @Published private(set) var records: [String: ReviewComment] = [:]

    /// Index of line-range comments by `repositoryPath + filePath`, so re-anchoring lookups
    /// don't scan every record on hot paths (sidebar badges recompute per keystroke).
    private var lineIndex: [String: [ReviewComment]] = [:]

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
        rebuildLineIndex()
    }

    private static func indexKey(_ repositoryPath: String, _ filePath: String) -> String {
        repositoryPath + "\u{1}" + filePath
    }

    private func rebuildLineIndex() {
        lineIndex = [:]
        for record in records.values where record.anchorLines != nil {
            lineIndex[Self.indexKey(record.repositoryPath, record.filePath), default: []].append(record)
        }
    }

    // MARK: Keys

    /// The persistence key. Content-hash based so review state follows the change,
    /// not the commit or line range it currently lives at.
    nonisolated static func key(repositoryPath: String, contentHash: String) -> String {
        repositoryPath + "\u{1}" + contentHash
    }

    /// Everything needed to locate and (re)create a record for a chunk or a line range.
    struct ReviewTarget {
        let repositoryPath: String
        let commitSHA: String
        let filePath: String
        let hunkHeader: String
        let contentHash: String
        /// Non-nil for line-range comments; persisted so the comment can be re-anchored.
        var anchorLines: [String]? = nil

        var key: String {
            ReviewStore.key(repositoryPath: repositoryPath, contentHash: contentHash)
        }
    }

    // MARK: Lookup

    func text(forKey key: String) -> String {
        records[key]?.comment ?? ""
    }

    func isReviewed(forKey key: String) -> Bool {
        records[key]?.isReviewed ?? false
    }

    /// All line-range comments recorded for a file, to be re-anchored against current hunks.
    func lineComments(repositoryPath: String, filePath: String) -> [ReviewComment] {
        lineIndex[Self.indexKey(repositoryPath, filePath)] ?? []
    }

    /// Every non-empty comment recorded for a repository, across all commits.
    func allComments(repositoryPath: String) -> [ReviewComment] {
        records.values.filter {
            $0.repositoryPath == repositoryPath
                && !$0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: Mutation

    /// Updates the comment for a chunk. Empty comments don't delete the record if the
    /// chunk is still marked reviewed.
    func setText(_ text: String, for target: ReviewTarget) {
        mutate(target) { $0.comment = text }
    }

    func setReviewed(_ reviewed: Bool, for target: ReviewTarget) {
        mutate(target) { $0.isReviewed = reviewed }
    }

    /// Upserts a record, refreshes its "last seen" metadata, then prunes it if it carries
    /// neither a comment nor a reviewed flag.
    private func mutate(_ target: ReviewTarget, _ body: (inout ReviewComment) -> Void) {
        let key = target.key
        let now = Date()
        var record = records[key] ?? ReviewComment(
            id: UUID(),
            repositoryPath: target.repositoryPath,
            contentHash: target.contentHash,
            filePath: target.filePath,
            commitSHA: target.commitSHA,
            hunkHeader: target.hunkHeader,
            comment: "",
            isReviewed: false,
            anchorLines: target.anchorLines,
            createdAt: now,
            updatedAt: now
        )

        body(&record)
        record.commitSHA = target.commitSHA
        record.hunkHeader = target.hunkHeader
        record.updatedAt = now

        let hasComment = !record.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasComment && !record.isReviewed {
            records.removeValue(forKey: key)
        } else {
            records[key] = record
        }
        updateLineIndex(for: record, removed: !hasComment && !record.isReviewed)
        scheduleSave()
    }

    /// Keeps `lineIndex` current for a single line-comment record without rescanning all records.
    private func updateLineIndex(for record: ReviewComment, removed: Bool) {
        guard record.anchorLines != nil else { return }
        let bucketKey = Self.indexKey(record.repositoryPath, record.filePath)
        var bucket = lineIndex[bucketKey] ?? []
        bucket.removeAll { $0.contentHash == record.contentHash }
        if !removed { bucket.append(record) }
        lineIndex[bucketKey] = bucket.isEmpty ? nil : bucket
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
            records = decoded
        }
    }

    /// Debounced write so rapid typing doesn't thrash the disk.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = records
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
