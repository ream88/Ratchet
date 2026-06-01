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
        // Welcome window — the launch window; reopenable from the Window menu.
        Window("Welcome to Ratchet", id: "welcome") {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 460)
        .defaultPosition(.center)
        .commandsRemoved()

        // One window per repository, keyed by its folder URL.
        WindowGroup(id: "repository", for: URL.self) { $url in
            if let url {
                ContentView(repositoryURL: url)
            } else {
                WelcomeView()
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenRepositoryButton()
            }
            CommandGroup(after: .windowArrangement) {
                WelcomeMenuButton()
            }
        }
    }
}

/// Presents a folder picker and opens the chosen repository in a new window.
struct OpenRepositoryButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Repository…") {
            if let url = WelcomeView.chooseFolder() {
                RecentRepositoriesStore.shared.add(url)
                openWindow(id: "repository", value: url)
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }
}

/// Reopens the welcome window from the Window menu.
struct WelcomeMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Welcome to Ratchet") {
            openWindow(id: "welcome")
        }
        .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}
