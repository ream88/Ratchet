//
//  CommitListView.swift
//  Ratchet
//
//  Left sidebar: branch selector + scrollable commit list.
//

import SwiftUI

struct CommitListView: View {
    @ObservedObject var document: RepositoryDocument
    // Observed so review-state changes refresh the per-commit "reviewed" badge.
    @ObservedObject private var store: ReviewStore

    init(document: RepositoryDocument) {
        self.document = document
        self.store = document.store
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
                    CommitRow(
                        commit: commit,
                        isFullyReviewed: document.isFullyReviewed(commit) == true,
                        hasUnresolvedComments: document.hasUnresolvedComments(commit)
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

            VStack(alignment: .trailing, spacing: 4) {
                if hasUnresolvedComments {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Has unresolved review comments")
                }
                if isFullyReviewed {
                    reviewedBadge
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var reviewedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
            Text("Reviewed")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.green)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.15), in: Capsule())
        .help("All chunks in this commit are reviewed")
        .fixedSize()
    }
}
