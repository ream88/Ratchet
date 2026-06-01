//
//  DiffReviewView.swift
//  Ratchet
//
//  Main content: the selected commit's changed files, their hunks, and per-hunk
//  comment fields. A toggleable inspector summarizes all comments for the commit.
//

import SwiftUI

struct DiffReviewView: View {
    @ObservedObject var document: RepositoryDocument
    @State private var showSummary = false

    var body: some View {
        Group {
            if document.selectedCommit == nil {
                ContentUnavailableView(
                    "Select a Commit",
                    systemImage: "arrow.left",
                    description: Text("Choose a commit from the sidebar to review its changes.")
                )
            } else if document.isLoadingDiff {
                VStack {
                    ProgressView()
                    Text("Loading diff…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                diffContent
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    document.exportMarkdown()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(document.selectedCommit == nil)
                .help("Export review comments as Markdown")

                Button {
                    showSummary.toggle()
                } label: {
                    Label("Summary", systemImage: "sidebar.right")
                }
                .help("Show comment summary")
            }
        }
        .inspector(isPresented: $showSummary) {
            CommentSummaryView(document: document)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        if document.diffFiles.isEmpty {
            ContentUnavailableView(
                "No Changes",
                systemImage: "doc",
                description: Text("This commit has no file changes (or only metadata changes).")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let commit = document.selectedCommit {
                        CommitHeaderView(commit: commit, branch: document.selectedBranchName)
                    }
                    ForEach(document.diffFiles) { file in
                        DiffFileView(file: file, document: document)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct CommitHeaderView: View {
    let commit: GitCommit
    let branch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.title)
                .font(.title3.bold())
            HStack(spacing: 8) {
                Label(commit.shortSHA, systemImage: "number")
                    .font(.system(.caption, design: .monospaced))
                Label(commit.author, systemImage: "person")
                    .font(.caption)
                if let branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiffFileView: View {
    let file: DiffFile
    @ObservedObject var document: RepositoryDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(file.path)
                    .font(.headline)
                    .textSelection(.enabled)
            }

            if file.isBinary {
                Text("Binary file — no textual diff.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else if file.hunks.isEmpty {
                Text("No hunks (file mode or metadata change only).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else {
                ForEach(file.hunks) { hunk in
                    DiffHunkView(hunk: hunk, document: document)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Right inspector: lists every hunk that has a comment for the current commit.
private struct CommentSummaryView: View {
    @ObservedObject var document: RepositoryDocument
    @ObservedObject private var store: ReviewStore

    init(document: RepositoryDocument) {
        self.document = document
        self.store = document.store
    }

    private var commented: [(file: String, header: String, text: String)] {
        guard document.selectedCommit != nil else { return [] }
        var result: [(String, String, String)] = []
        for file in document.diffFiles {
            for hunk in file.hunks {
                guard let key = document.commentKey(for: hunk) else { continue }
                let text = store.text(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append((file.path, hunk.header, text))
                }
            }
        }
        return result
    }

    /// (reviewed, total) hunk counts for the current commit.
    private var reviewProgress: (reviewed: Int, total: Int) {
        var reviewed = 0
        var total = 0
        for file in document.diffFiles {
            for hunk in file.hunks {
                total += 1
                if document.isReviewed(hunk) { reviewed += 1 }
            }
        }
        return (reviewed, total)
    }

    var body: some View {
        let items = commented
        let progress = reviewProgress
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Comments")
                        .font(.headline)
                    Spacer()
                    Text("\(items.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if progress.total > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: progress.reviewed == progress.total
                              ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(progress.reviewed == progress.total ? .green : .secondary)
                        Text("\(progress.reviewed) of \(progress.total) chunks reviewed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    "No Comments Yet",
                    systemImage: "text.bubble",
                    description: Text("Write notes under a hunk and they'll appear here.")
                )
            } else {
                List {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.file)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(item.header)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Text(item.text)
                                .font(.callout)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)

                Divider()
                Button {
                    document.exportMarkdown()
                } label: {
                    Label("Export Markdown", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(12)
            }
        }
    }
}
