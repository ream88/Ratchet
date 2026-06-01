//
//  ReviewStore.swift
//  Ratchet
//
//  Local persistence for review state, keyed by the *content* of each chunk so that
//  a rewritten chunk is treated as new work. Backed by SwiftData (SQLite); a single
//  shared store serves every window.
//
//  Reads go through in-memory caches (`records` / `lineIndex`) so hot paths — sidebar
//  badges, hunk state preload — stay synchronous and cheap. SwiftData is the durable
//  backing: mutations write through to the model context and a debounced save persists.
//

import Foundation
import Combine
import SwiftData

/// The persisted (SQLite) form of a review record. Mirrors the in-memory `ReviewComment`.
@Model
final class StoredReviewComment {
    /// `repositoryPath + contentHash` — the same composite key used in memory.
    @Attribute(.unique) var key: String
    var repositoryPath: String
    var contentHash: String
    var filePath: String
    var commitSHA: String
    var hunkHeader: String
    var comment: String
    var isReviewed: Bool
    var anchorLines: [String]?
    var createdAt: Date
    var updatedAt: Date

    init(key: String, repositoryPath: String, contentHash: String, filePath: String,
         commitSHA: String, hunkHeader: String, comment: String, isReviewed: Bool,
         anchorLines: [String]?, createdAt: Date, updatedAt: Date) {
        self.key = key
        self.repositoryPath = repositoryPath
        self.contentHash = contentHash
        self.filePath = filePath
        self.commitSHA = commitSHA
        self.hunkHeader = hunkHeader
        self.comment = comment
        self.isReviewed = isReviewed
        self.anchorLines = anchorLines
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()

    /// Records keyed by `repositoryPath + contentHash`.
    @Published private(set) var records: [String: ReviewComment] = [:]

    /// Index of line-range comments by `repositoryPath + filePath`, so re-anchoring lookups
    /// don't scan every record on hot paths (sidebar badges recompute per keystroke).
    private var lineIndex: [String: [ReviewComment]] = [:]

    /// Cache of the SwiftData model objects by key, so writes don't need a fetch.
    private var storedByKey: [String: StoredReviewComment] = [:]

    /// Retained for the store's lifetime — if the container deallocates, its context and all
    /// model instances are invalidated ("destroyed by ModelContext.reset").
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private var saveTask: Task<Void, Never>?

    init(inMemory: Bool = false) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            modelContainer = try ModelContainer(for: StoredReviewComment.self, configurations: configuration)
        } catch {
            // Fall back to an in-memory store so the app still runs if the file store fails.
            modelContainer = try! ModelContainer(
                for: StoredReviewComment.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        modelContext = modelContainer.mainContext

        load()
        migrateLegacyJSONIfNeeded()
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

        let shouldRemove = record.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !record.isReviewed
        if shouldRemove {
            records.removeValue(forKey: key)
        } else {
            records[key] = record
        }
        updateLineIndex(for: record, removed: shouldRemove)
        persist(record, key: key, removed: shouldRemove)
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

    // MARK: Persistence (SwiftData)

    private func persist(_ record: ReviewComment, key: String, removed: Bool) {
        if removed {
            if let model = storedByKey.removeValue(forKey: key) {
                modelContext.delete(model)
            }
        } else if let model = storedByKey[key] {
            model.comment = record.comment
            model.isReviewed = record.isReviewed
            model.commitSHA = record.commitSHA
            model.hunkHeader = record.hunkHeader
            model.anchorLines = record.anchorLines
            model.updatedAt = record.updatedAt
        } else {
            let model = StoredReviewComment(record: record, key: key)
            modelContext.insert(model)
            storedByKey[key] = model
        }
        scheduleSave()
    }

    private func load() {
        guard let stored = try? modelContext.fetch(FetchDescriptor<StoredReviewComment>()) else { return }
        for model in stored {
            storedByKey[model.key] = model
            records[model.key] = ReviewComment(model)
        }
    }

    /// Debounced save so rapid typing doesn't hit the disk on every keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.modelContext.hasChanges else { return }
            try? self.modelContext.save()
        }
    }

    // MARK: One-time migration from the old JSON file

    private func migrateLegacyJSONIfNeeded() {
        guard records.isEmpty else { return }

        let fm = FileManager.default
        let url = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: false))?
            .appendingPathComponent("Ratchet", isDirectory: true)
            .appendingPathComponent("reviews.json")
        guard let url, let data = try? Data(contentsOf: url) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: ReviewComment].self, from: data) {
            for (key, record) in decoded {
                let model = StoredReviewComment(record: record, key: key)
                modelContext.insert(model)
                storedByKey[key] = model
                records[key] = record
            }
            try? modelContext.save()
        }
        // No JSON anymore — drop the legacy file regardless of decode outcome.
        try? fm.removeItem(at: url)
    }
}

// MARK: - Mapping

private extension ReviewComment {
    init(_ model: StoredReviewComment) {
        self.init(
            id: UUID(),
            repositoryPath: model.repositoryPath,
            contentHash: model.contentHash,
            filePath: model.filePath,
            commitSHA: model.commitSHA,
            hunkHeader: model.hunkHeader,
            comment: model.comment,
            isReviewed: model.isReviewed,
            anchorLines: model.anchorLines,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt
        )
    }
}

private extension StoredReviewComment {
    convenience init(record: ReviewComment, key: String) {
        self.init(
            key: key,
            repositoryPath: record.repositoryPath,
            contentHash: record.contentHash,
            filePath: record.filePath,
            commitSHA: record.commitSHA,
            hunkHeader: record.hunkHeader,
            comment: record.comment,
            isReviewed: record.isReviewed,
            anchorLines: record.anchorLines,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }
}
