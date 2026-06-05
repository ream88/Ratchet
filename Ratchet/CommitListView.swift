//
//  CommitListView.swift
//  Ratchet
//
//  Left sidebar: branch selector + scrollable commit list.
//

import SwiftUI

struct CommitListView: View {
    @ObservedObject var document: RepositoryDocument
    // Observe only the lightweight badge cache — not the whole review store — so typing a
    // comment doesn't re-render or recompute the commit list on every keystroke.
    @ObservedObject private var badges: CommitBadgeStore

    init(document: RepositoryDocument) {
        self.document = document
        self.badges = document.badges
    }

    var body: some View {
        commitList
    }

    @ViewBuilder
    private var commitList: some View {
        if document.isLoadingCommits {
            VStack {
                ProgressView()
                Text("Loading commits…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if document.commits.isEmpty {
            ContentUnavailableView("No Commits", systemImage: "tray",
                                   description: Text("This branch has no commits to review."))
        } else {
                List(selection: Binding(
                    get: { document.selectedCommit },
                    set: { commit in
                        if let commit { Task { await document.selectCommit(commit) } }
                    }
                )) {
                    ForEach(document.commits) { commit in
                        let badge = badges.badges[commit.id]
                        // Dim commits already in the base branch so the unmerged ones stand out.
                        // The working-tree entry is never "merged".
                        let merged = !commit.isUncommitted
                            && document.baseBranchName != nil
                            && !document.commitsAheadOfBase.contains(commit.id)
                        CommitRow(
                            commit: commit,
                            isFullyReviewed: badge?.fullyReviewed == true,
                            hasUnresolvedComments: badge?.hasComments == true
                        )
                        .opacity(merged ? 0.45 : 1)
                        .tag(commit)
                        .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                        .contextMenu {
                            Button("Mark Commit as Reviewed") {
                                Task { await document.markCommitReviewed(commit) }
                            }
                            Divider()
                            Button("Copy Comments") {
                                Task { await document.copyComments(for: commit) }
                            }
                            .keyboardShortcut("c", modifiers: .command)
                            if !commit.isUncommitted {
                                Button("Copy SHA") {
                                    document.copySHA(commit)
                                }
                                .keyboardShortcut("c", modifiers: [.command, .option])
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // ⌘C copies the selected commit's comments. onCopyCommand ties into the
                // responder chain, so it only fires when the list is focused — it won't
                // hijack ⌘C while a comment editor in the detail pane is focused.
                .onCopyCommand {
                    guard let commit = document.selectedCommit,
                          let markdown = document.commentsMarkdown(for: commit) else { return [] }
                    return [NSItemProvider(object: markdown as NSString)]
                }
                .background {
                    // ⌥⌘C copies the selected commit's SHA (no standard command for this).
                    Button("") {
                        if let commit = document.selectedCommit { document.copySHA(commit) }
                    }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .opacity(0)
                    .accessibilityHidden(true)
                }
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit
    let isFullyReviewed: Bool
    let hasUnresolvedComments: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if commit.isUncommitted {
                        Image(systemName: "pencil.line")
                            .foregroundStyle(.secondary)
                    }
                    Text(commit.title)
                        .lineLimit(2)
                        .font(.callout.weight(.medium))
                }
                if !commit.isUncommitted {
                    HStack(spacing: 6) {
                        Text(commit.shortSHA)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(commit.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DiffStatView(additions: commit.additions, deletions: commit.deletions)
                if let date = commit.date {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if hasUnresolvedComments {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                        .help("Has unresolved review comments")
                }
                if isFullyReviewed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("All hunks in this commit are reviewed")
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 3)
    }
}
