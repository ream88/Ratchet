//
//  RepositoryDocument.swift
//  Ratchet
//
//  The view model for a single opened repository window. Owns all git-derived state
//  and bridges hunk comments to the shared ReviewStore.
//

import Foundation
import SwiftUI
import Combine
import AppKit

// TODO: Future improvements
//   - Send comments directly to an AI coding agent (e.g. pipe the exported Markdown).
//   - GitHub/GitLab PR integration (open/review PRs, post comments).
//   - Per-hunk review status (e.g. approved / needs-changes / commented).
//   - Keyboard shortcuts for navigating commits and hunks.
//   - Filtering commits (by author, message, path).
//   - Syntax highlighting inside diff hunks.
//   - Toggle to show only commented / only uncommented hunks.

/// Holds the sidebar's per-commit badges on a *separate* observable object so updating them
/// (which happens on every comment keystroke) re-renders only the sidebar — not the diff view
/// and its hunks, which observe `RepositoryDocument` itself.
@MainActor
final class CommitBadgeStore: ObservableObject {
    @Published var badges: [String: CommitBadge] = [:]
}

/// A pending offer to apply a just-made review action to every identical hunk in the commit.
struct BatchSuggestion: Identifiable {
    enum Kind {
        case review
        case comment(String)
    }

    let id = UUID()
    let kind: Kind
    let targets: [DiffHunk]
    var count: Int { targets.count }
}

@MainActor
final class RepositoryDocument: ObservableObject {
    let repositoryURL: URL
    let store: ReviewStore
    let badges = CommitBadgeStore()
    let mcpServer: RatchetMCPServer

    @Published var branches: [GitBranch] = []
    @Published var selectedBranchName: String?
    @Published var commits: [GitCommit] = []
    @Published var selectedCommit: GitCommit?
    @Published var diffFiles: [DiffFile] = []

    @Published var isLoadingCommits = false
    @Published var isLoadingDiff = false
    @Published var errorMessage: String?
    @Published private(set) var isValidRepository = false

    /// The base branch the selected branch is compared against (e.g. `main`), if found.
    @Published private(set) var baseBranchName: String?

    /// SHAs of commits in the selected branch that are ahead of (not yet in) the base branch.
    @Published private(set) var commitsAheadOfBase: Set<String> = []

    /// Each loaded commit's parsed hunks, cached as commits are opened so the sidebar can
    /// show review/comment badges without re-diffing every commit up front.
    @Published private(set) var hunksByCommit: [String: [DiffHunk]] = [:]

    /// Bumped whenever a chunk's reviewed flag changes. Hunk views watch this to re-sync
    /// their local state after a file-level "mark all reviewed" — without re-rendering on
    /// every comment keystroke (which would be costly for large diffs).
    @Published private(set) var reviewedTick = 0

    /// A pending "the same change appears N more times — apply to all?" prompt, raised when
    /// the user reviews or notes a hunk that has identical siblings elsewhere in this commit.
    @Published var batchSuggestion: BatchSuggestion?

    /// Signatures the user answered "Just this one" for — suppresses re-asking for the same
    /// change within the current commit. Cleared when a different commit is selected.
    private var dismissedSignatures: Set<String> = []

    private let git: GitService

    var repositoryPath: String { repositoryURL.path(percentEncoded: false) }
    var repositoryName: String { repositoryURL.lastPathComponent }

    /// Display-only path without a trailing slash. (Keep `repositoryPath` as-is — it keys
    /// all persisted review data.)
    var repositoryDisplayPath: String {
        let path = repositoryPath
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    init(repositoryURL: URL, store: ReviewStore? = nil) {
        self.repositoryURL = repositoryURL
        self.store = store ?? .shared
        self.git = GitService(repositoryURL: repositoryURL)
        self.mcpServer = RatchetMCPServer(repositoryPath: repositoryURL.path(percentEncoded: false))
    }

    // MARK: Loading

    /// Validates the repo and loads branches + the current branch's commits.
    func load() async {
        errorMessage = nil
        do {
            try await git.validateRepository()
            isValidRepository = true

            // Preload persisted badges so every commit shows its status immediately,
            // not only after it's been opened this session.
            badges.badges = store.commitBadges(repositoryPath: repositoryPath)

            async let branchesTask = git.branches()
            async let currentTask = git.currentBranch()
            let (loadedBranches, current) = try await (branchesTask, currentTask)

            branches = loadedBranches
            // Prefer the checked-out branch, then a branch flagged current, then the first.
            let initial = current
                ?? loadedBranches.first(where: { $0.isCurrent })?.name
                ?? loadedBranches.first?.name
            selectedBranchName = initial
            if let initial {
                await loadCommits(branch: initial)
            }
        } catch {
            isValidRepository = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Reloads branches and the selected branch's commits to pick up new work in the repo.
    /// Cached diffs/comments for existing commits stay valid (commit SHAs are immutable).
    func refresh() async {
        guard isValidRepository else { await load(); return }
        errorMessage = nil
        if let loaded = try? await git.branches() { branches = loaded }
        if let branch = selectedBranchName {
            await loadCommits(branch: branch)
            if let selected = selectedCommit, !commits.contains(selected) {
                selectedCommit = nil
                diffFiles = []
            }
        }
    }

    func selectBranch(_ name: String) async {
        guard name != selectedBranchName || commits.isEmpty else { return }
        selectedBranchName = name
        selectedCommit = nil
        diffFiles = []
        await loadCommits(branch: name)
    }

    private func loadCommits(branch: String) async {
        isLoadingCommits = true
        errorMessage = nil
        defer { isLoadingCommits = false }
        do {
            commits = try await git.commits(branch: branch)
            mcpServer.currentBranchCommits = commits
            await loadAheadOfBase(branch: branch)
        } catch {
            commits = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Computes which of the branch's commits aren't yet in the base branch (e.g. `main`).
    /// No-ops when viewing the base branch itself or when no base branch is present.
    private func loadAheadOfBase(branch: String) async {
        guard let base = detectBaseBranch(for: branch) else {
            baseBranchName = nil
            commitsAheadOfBase = []
            return
        }
        baseBranchName = base
        let ahead = (try? await git.commitsAhead(branch: branch, base: base)) ?? []
        commitsAheadOfBase = Set(ahead)
    }

    /// Picks a sensible base branch to compare against — `main`/`master` (local, then remote).
    /// Returns nil when viewing the trunk itself (nothing to be ahead of).
    private func detectBaseBranch(for branch: String) -> String? {
        if branch == "main" || branch == "master" { return nil }
        let names = Set(branches.map(\.name))
        return ["main", "master", "origin/main", "origin/master"].first { names.contains($0) }
    }

    func selectCommit(_ commit: GitCommit) async {
        selectedCommit = commit
        diffFiles = []
        batchSuggestion = nil
        dismissedSignatures = []
        isLoadingDiff = true
        errorMessage = nil
        defer { isLoadingDiff = false }
        do {
            let raw = try await git.diff(forCommit: commit.id)
            // Keep only files with real content changes; binary files count even
            // though they have no textual hunks. This drops mode/metadata-only noise.
            diffFiles = DiffParser.parse(raw).filter { !$0.hunks.isEmpty || $0.isBinary }
            hunksByCommit[commit.id] = diffFiles.flatMap(\.hunks)
            updateBadge(forCommitID: commit.id)
        } catch {
            diffFiles = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Review state

    func reviewTarget(for hunk: DiffHunk) -> ReviewStore.ReviewTarget? {
        guard let sha = selectedCommit?.id else { return nil }
        return ReviewStore.ReviewTarget(
            repositoryPath: repositoryPath,
            commitSHA: sha,
            filePath: hunk.filePath,
            hunkHeader: hunk.header,
            contentHash: hunk.contentHash
        )
    }

    func commentKey(for hunk: DiffHunk) -> String? {
        reviewTarget(for: hunk)?.key
    }

    func commentText(for hunk: DiffHunk) -> String {
        guard let key = commentKey(for: hunk) else { return "" }
        return store.text(forKey: key)
    }

    func setComment(_ text: String, for hunk: DiffHunk) {
        guard let target = reviewTarget(for: hunk) else { return }
        store.setText(text, for: target)
        refreshSelectedCommitBadge()
    }

    func isReviewed(_ hunk: DiffHunk) -> Bool {
        guard let key = commentKey(for: hunk) else { return false }
        return store.isReviewed(forKey: key)
    }

    func setReviewed(_ reviewed: Bool, for hunk: DiffHunk) {
        guard let target = reviewTarget(for: hunk) else { return }
        store.setReviewed(reviewed, for: target)
        reviewedTick += 1
        refreshSelectedCommitBadge()
    }

    /// Marks every chunk in a file reviewed (or not). Drives the sticky file header.
    func setReviewed(_ reviewed: Bool, forFile file: DiffFile) {
        for hunk in file.hunks {
            guard let target = reviewTarget(for: hunk) else { continue }
            store.setReviewed(reviewed, for: target)
        }
        reviewedTick += 1
        refreshSelectedCommitBadge()
    }

    /// (reviewed, total) chunk counts for a file.
    func reviewProgress(forFile file: DiffFile) -> (reviewed: Int, total: Int) {
        (file.hunks.filter { isReviewed($0) }.count, file.hunks.count)
    }

    // MARK: Batch suggestions ("same change, N more times")

    /// Hunks elsewhere in the current commit's diff whose *change* matches `hunk` (ignoring the
    /// file path, so a rename hits every file), excluding `hunk` itself.
    private func identicalHunks(to hunk: DiffHunk) -> [DiffHunk] {
        diffFiles.flatMap(\.hunks).filter {
            $0.id != hunk.id && $0.contentSignature == hunk.contentSignature
        }
    }

    /// Marks a hunk reviewed from its toggle and, if the same change appears in other
    /// not-yet-reviewed hunks, offers to mark them all.
    func markReviewed(_ hunk: DiffHunk) {
        setReviewed(true, for: hunk)
        guard !dismissedSignatures.contains(hunk.contentSignature) else { return }
        let pending = identicalHunks(to: hunk).filter { !isReviewed($0) }
        if !pending.isEmpty {
            batchSuggestion = BatchSuggestion(kind: .review, targets: pending)
        }
    }

    /// Called when a whole-hunk note finishes editing; offers to copy it to identical hunks
    /// that have no note yet (never clobbering a different one).
    func suggestCommentPropagation(from hunk: DiffHunk) {
        guard !dismissedSignatures.contains(hunk.contentSignature) else { return }
        let text = commentText(for: hunk).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pending = identicalHunks(to: hunk).filter {
            commentText(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !pending.isEmpty {
            batchSuggestion = BatchSuggestion(kind: .comment(text), targets: pending)
        }
    }

    /// Applies the pending suggestion to every target, then dismisses it.
    func applyBatchSuggestion() {
        guard let suggestion = batchSuggestion else { return }
        for hunk in suggestion.targets {
            guard let target = reviewTarget(for: hunk) else { continue }
            switch suggestion.kind {
            case .review: store.setReviewed(true, for: target)
            case .comment(let text): store.setText(text, for: target)
            }
        }
        reviewedTick += 1
        refreshSelectedCommitBadge()
        batchSuggestion = nil
    }

    /// Dismisses the pending suggestion and remembers its change so we don't re-ask this commit.
    func dismissBatchSuggestion() {
        for hunk in batchSuggestion?.targets ?? [] {
            dismissedSignatures.insert(hunk.contentSignature)
        }
        batchSuggestion = nil
    }

    // MARK: Line-range comments

    /// Line comments currently anchored within a hunk, paired with their live line range.
    func lineComments(for hunk: DiffHunk) -> [(range: ClosedRange<Int>, record: ReviewComment)] {
        store.lineComments(repositoryPath: repositoryPath, filePath: hunk.filePath)
            .compactMap { record in
                guard let anchor = record.anchorLines,
                      let range = hunk.locate(anchorLines: anchor) else { return nil }
                return (range, record)
            }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Current text of the comment identified by a content hash (line or chunk).
    func commentText(forContentHash hash: String) -> String {
        store.text(forKey: ReviewStore.key(repositoryPath: repositoryPath, contentHash: hash))
    }

    /// Adds or updates a comment on a contiguous range of lines within a hunk.
    func setLineComment(_ text: String, for hunk: DiffHunk, range: ClosedRange<Int>) {
        guard let sha = selectedCommit?.id else { return }
        let target = ReviewStore.ReviewTarget(
            repositoryPath: repositoryPath,
            commitSHA: sha,
            filePath: hunk.filePath,
            hunkHeader: hunk.header,
            contentHash: hunk.lineCommentContentHash(forRange: range),
            anchorLines: hunk.anchorLines(forRange: range)
        )
        store.setText(text, for: target)
        refreshSelectedCommitBadge()
    }

    /// Updates or clears (empty text) an existing line comment, identified by its record.
    func updateLineComment(_ text: String, record: ReviewComment, hunk: DiffHunk) {
        guard let sha = selectedCommit?.id else { return }
        let target = ReviewStore.ReviewTarget(
            repositoryPath: repositoryPath,
            commitSHA: sha,
            filePath: record.filePath,
            hunkHeader: hunk.header,
            contentHash: record.contentHash,
            anchorLines: record.anchorLines
        )
        store.setText(text, for: target)
        refreshSelectedCommitBadge()
    }

    // MARK: Sidebar badges

    /// Recomputes the cached badge for a commit and persists it (keyed by SHA) so it survives
    /// across launches. Only runs when the commit's diff is loaded; otherwise the preloaded,
    /// persisted badge stays as-is.
    func updateBadge(forCommitID id: String) {
        guard let badge = computeBadge(forCommitID: id) else { return }
        badges.badges[id] = badge
        store.setCommitBadge(badge, repositoryPath: repositoryPath, commitSHA: id)
    }

    private func refreshSelectedCommitBadge() {
        if let id = selectedCommit?.id { updateBadge(forCommitID: id) }
    }

    /// nil until the commit's diff is loaded, so the sidebar stays quiet rather than guessing.
    private func computeBadge(forCommitID id: String) -> CommitBadge? {
        guard let hunks = hunksByCommit[id], !hunks.isEmpty else { return nil }
        let fullyReviewed = hunks.allSatisfy {
            store.isReviewed(forKey: ReviewStore.key(repositoryPath: repositoryPath, contentHash: $0.contentHash))
        }
        // A comment auto-resolves when the lines it's anchored to change, so any comment still
        // matching a live chunk counts. (Hashes are precomputed; line lookups are indexed.)
        let hasComments = hunks.contains { hunk in
            let key = ReviewStore.key(repositoryPath: repositoryPath, contentHash: hunk.contentHash)
            if !store.text(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return !lineComments(for: hunk).isEmpty
        }
        return CommitBadge(fullyReviewed: fullyReviewed, hasComments: hasComments)
    }

    // MARK: Commit actions (sidebar context menu / shortcuts)

    /// Marks every hunk of a commit reviewed, loading its diff first if needed.
    func markCommitReviewed(_ commit: GitCommit) async {
        let hunks = await hunks(forCommit: commit)
        for hunk in hunks {
            let target = ReviewStore.ReviewTarget(
                repositoryPath: repositoryPath,
                commitSHA: commit.id,
                filePath: hunk.filePath,
                hunkHeader: hunk.header,
                contentHash: hunk.contentHash
            )
            store.setReviewed(true, for: target)
        }
        reviewedTick += 1
        updateBadge(forCommitID: commit.id)
    }

    /// Copies all of a commit's review comments to the clipboard as Markdown.
    func copyComments(for commit: GitCommit) async {
        _ = await hunks(forCommit: commit)
        if let markdown = commentsMarkdown(for: commit) {
            Self.copyToPasteboard(markdown)
        }
    }

    /// Synchronously builds a commit's review-comment Markdown from already-loaded hunks.
    /// Returns nil if the commit's diff hasn't been parsed yet. Used by ⌘C in the sidebar.
    func commentsMarkdown(for commit: GitCommit) -> String? {
        guard let hunks = hunksByCommit[commit.id] else { return nil }
        let files = Dictionary(grouping: hunks, by: \.filePath)
            .map { DiffFile(id: UUID(), path: $0.key, hunks: $0.value) }
            .sorted { $0.path < $1.path }
        return ExportService.markdown(
            commit: commit,
            repositoryPath: repositoryPath,
            branch: selectedBranchName,
            files: files,
            store: store
        )
    }

    /// Copies the full commit SHA to the clipboard.
    func copySHA(_ commit: GitCommit) {
        Self.copyToPasteboard(commit.id)
    }

    /// Returns a commit's hunks from cache, parsing its diff on demand.
    private func hunks(forCommit commit: GitCommit) async -> [DiffHunk] {
        if let cached = hunksByCommit[commit.id] { return cached }
        guard let raw = try? await git.diff(forCommit: commit.id) else { return [] }
        let hunks = DiffParser.parse(raw).filter { !$0.hunks.isEmpty || $0.isBinary }.flatMap(\.hunks)
        hunksByCommit[commit.id] = hunks
        return hunks
    }

    private static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: Claude Code integration

    /// Writes a `/ratchet` slash command into the repo's `.claude/commands/` so Claude Code
    /// (running in this repo) can pull the review comments via the MCP server. Reveals it in Finder.
    func installClaudeCommand() {
        let dir = repositoryURL.appendingPathComponent(".claude/commands", isDirectory: true)
        let file = dir.appendingPathComponent("ratchet.md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.claudeCommandContent.write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let claudeCommandContent = """
    ---
    description: Pull in Ratchet review comments and address them
    allowed-tools: mcp__ratchet__list_review_comments
    ---

    Call the `list_review_comments` tool from the `ratchet` MCP server to fetch every
    review comment recorded for this repository.

    For each comment:
    1. Open the referenced file and locate the relevant lines.
    2. Make the change the comment asks for, keeping the edit minimal and focused.

    When you're done, give a short summary of what you changed for each comment.

    (Requires Ratchet's MCP server to be running and registered:
    `claude mcp add --transport http ratchet http://127.0.0.1:8765/mcp`)
    """

    // MARK: Export

    func exportMarkdown() {
        guard let commit = selectedCommit else { return }
        let markdown = ExportService.markdown(
            commit: commit,
            repositoryPath: repositoryPath,
            branch: selectedBranchName,
            files: diffFiles,
            store: store
        )
        ExportService.save(markdown: markdown, suggestedName: "review-\(commit.shortSHA).md")
    }

    /// Exports the current branch's review comments into a single Markdown file.
    func exportAllComments() {
        let shas = Set(commits.map(\.id))
        let markdown = ExportService.markdownForAllComments(
            repositoryPath: repositoryPath,
            commits: commits,
            store: store,
            limitToCommits: shas.isEmpty ? nil : shas
        )
        ExportService.save(markdown: markdown, suggestedName: "\(repositoryName)-review-comments.md")
    }

    /// Whether any comment exists on the current branch (drives the export button's enabled state).
    var hasAnyComments: Bool {
        let shas = Set(commits.map(\.id))
        return store.allComments(repositoryPath: repositoryPath).contains { shas.contains($0.commitSHA) }
    }
}
