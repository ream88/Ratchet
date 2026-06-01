//
//  RatchetApp.swift
//  Ratchet
//
//  Created by Mario Uher on 01.06.26.
//

import SwiftUI
import AppKit

@main
struct RatchetApp: App {
    var body: some Scene {
        // One window per repository. The window's value is the repo folder URL;
        // a window with no value shows the welcome screen.
        WindowGroup(id: "repository", for: URL.self) { $url in
            RootView(repositoryURL: url)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenRepositoryButton()
            }
        }
    }
}

/// Presents a folder picker and opens the chosen repository in a new window.
struct OpenRepositoryButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Repository…") {
            if let url = Self.chooseFolder() {
                openWindow(id: "repository", value: url)
            }
        }
        .keyboardShortcut("o", modifiers: .command)
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

/// Routes between the welcome screen and a loaded repository.
struct RootView: View {
    let repositoryURL: URL?

    var body: some View {
        if let repositoryURL {
            ContentView(repositoryURL: repositoryURL)
        } else {
            WelcomeView()
        }
    }
}

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Ratchet")
                .font(.largeTitle.bold())
            Text("Review AI-generated commits and leave notes for your coding agent.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Repository…") {
                if let url = OpenRepositoryButton.chooseFolder() {
                    openWindow(id: "repository", value: url)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 320)
    }
}
