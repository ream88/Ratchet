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

// TODO: Future improvements
//   - Send comments directly to an AI coding agent (e.g. pipe the exported Markdown).
//   - GitHub/GitLab PR integration (open/review PRs, post comments).
//   - Per-hunk review status (e.g. approved / needs-changes / commented).
//   - Keyboard shortcuts for navigating commits and hunks.
//   - Filtering commits (by author, message, path).
//   - Syntax highlighting inside diff hunks.
//   - Toggle to show only commented / only uncommented hunks.

@MainActor
final class RepositoryDocument: ObservableObject {
    let repositoryURL: URL
    let store: ReviewStore

    @Published var branches: [GitBranch] = []
    @Published var selectedBranchName: String?
    @Published var commits: [GitCommit] = []
    @Published var selectedCommit: GitCommit?
    @Published var diffFiles: [DiffFile] = []

    @Published var isLoadingCommits = false
    @Published var isLoadingDiff = false
    @Published var errorMessage: String?
    @Published private(set) var isValidRepository = false

    private let git: GitService

    var repositoryPath: String { repositoryURL.path(percentEncoded: false) }
    var repositoryName: String { repositoryURL.lastPathComponent }

    init(repositoryURL: URL, store: ReviewStore? = nil) {
        self.repositoryURL = repositoryURL
        self.store = store ?? .shared
        self.git = GitService(repositoryURL: repositoryURL)
    }

    // MARK: Loading

    /// Validates the repo and loads branches + the current branch's commits.
    func load() async {
        errorMessage = nil
        do {
            try await git.validateRepository()
            isValidRepository = true

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
        } catch {
            commits = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func selectCommit(_ commit: GitCommit) async {
        selectedCommit = commit
        diffFiles = []
        isLoadingDiff = true
        errorMessage = nil
        defer { isLoadingDiff = false }
        do {
            let raw = try await git.diff(forCommit: commit.id)
            diffFiles = DiffParser.parse(raw)
        } catch {
            diffFiles = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Comments

    func commentKey(for hunk: DiffHunk) -> String? {
        guard let sha = selectedCommit?.id else { return nil }
        return ReviewStore.key(
            repositoryPath: repositoryPath,
            commitSHA: sha,
            filePath: hunk.filePath,
            hunkHeader: hunk.header
        )
    }

    func commentText(for hunk: DiffHunk) -> String {
        guard let key = commentKey(for: hunk) else { return "" }
        return store.text(forKey: key)
    }

    func setComment(_ text: String, for hunk: DiffHunk) {
        guard let key = commentKey(for: hunk), let sha = selectedCommit?.id else { return }
        store.setText(
            text,
            forKey: key,
            repositoryPath: repositoryPath,
            commitSHA: sha,
            filePath: hunk.filePath,
            hunkHeader: hunk.header
        )
    }

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
}
