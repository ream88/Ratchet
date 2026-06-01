//
//  WelcomeView.swift
//  Ratchet
//
//  Xcode-style welcome window: actions on the left, recent repositories on the right.
//

import SwiftUI
import AppKit

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var recents = RecentRepositoriesStore.shared

    var body: some View {
        HStack(spacing: 0) {
            actionsPane
                .frame(width: 360)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            Divider()

            recentsPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Fill the whole window (incl. under the hidden title bar) so there are no edge gaps.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    // MARK: Left — branding + actions

    private var actionsPane: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            VStack(spacing: 2) {
                Text("Ratchet")
                    .font(.system(size: 34, weight: .bold))
                Text("Version \(appVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            VStack(spacing: 4) {
                WelcomeAction(title: "Open Repository…", systemImage: "folder", action: openRepository)
            }
            Spacer()
        }
        .padding(28)
    }

    // MARK: Right — recent repositories

    @ViewBuilder
    private var recentsPane: some View {
        if recents.urls.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                Text("No Recent Repositories")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(recents.urls, id: \.self) { url in
                    RecentRow(url: url)
                        .contentShape(Rectangle())
                        .onTapGesture { open(url) }
                        .contextMenu {
                            Button("Remove from Recents") { recents.remove(url) }
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Actions

    private func openRepository() {
        if let url = Self.chooseFolder() { open(url) }
    }

    private func open(_ url: URL) {
        recents.add(url)
        openWindow(id: "repository", value: url)
        dismissWindow(id: "welcome")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository folder to review."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct WelcomeAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecentRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
