//
//  CommitListView.swift
//  Ratchet
//
//  Left sidebar: branch selector + scrollable commit list.
//

import SwiftUI

struct CommitListView: View {
    @ObservedObject var document: RepositoryDocument

    var body: some View {
        VStack(spacing: 0) {
            branchPicker
                .padding(8)
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
                    CommitRow(commit: commit)
                        .tag(commit)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
        .padding(.vertical, 2)
    }
}
