//
//  ContentView.swift
//  Ratchet
//
//  Three-column layout: branch + commit list, diff/review area, comment summary.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var document: RepositoryDocument

    init(repositoryURL: URL) {
        _document = StateObject(wrappedValue: RepositoryDocument(repositoryURL: repositoryURL))
    }

    var body: some View {
        NavigationSplitView {
            CommitListView(document: document)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            DiffReviewView(document: document)
        }
        .persistWindowFrame("Ratchet.window:\(document.repositoryPath)")
        .task {
            // Only the first appearance should kick off loading.
            if document.commits.isEmpty && document.errorMessage == nil {
                await document.load()
                if document.isValidRepository {
                    RecentRepositoriesStore.shared.add(document.repositoryURL)
                }
            }
        }
        .alert(
            "Git Error",
            isPresented: Binding(
                get: { document.errorMessage != nil },
                set: { if !$0 { document.errorMessage = nil } }
            ),
            presenting: document.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { document.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .navigationTitle(document.selectedBranchName ?? document.repositoryName)
        .navigationSubtitle(document.repositoryDisplayPath)
    }
}
