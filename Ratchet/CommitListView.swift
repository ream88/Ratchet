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
        VStack(spacing: 0) {
            branchPicker
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            commitList
        }
    }

    @ViewBuilder
    private var branchPicker: some View {
        if document.branches.isEmpty {
            Text("No branches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("Branch", selection: Binding(
                get: { document.selectedBranchName ?? "" },
                set: { name in
                    Task { await document.selectBranch(name) }
                }
            )) {
                ForEach(document.branches) { branch in
                    Text(branch.name).tag(branch.name)
                }
            }
            .labelsHidden()
        }
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
                    CommitRow(
                        commit: commit,
                        isFullyReviewed: badge?.fullyReviewed == true,
                        hasUnresolvedComments: badge?.hasComments == true
                    )
                    .tag(commit)
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                }
            }
            .listStyle(.inset)
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
                Text(commit.title)
                    .lineLimit(2)
                    .font(.callout.weight(.medium))
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
