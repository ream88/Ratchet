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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Welcome window — the launch window; reopenable from the Window menu.
        Window("Welcome to Ratchet", id: "welcome") {
            WelcomeView()
                .captureWindowOpener()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 460)
        .defaultPosition(.center)
        .commandsRemoved()

        // One window per repository, keyed by its folder URL.
        WindowGroup(id: "repository", for: URL.self) { $url in
            Group {
                if let url {
                    ContentView(repositoryURL: url)
                } else {
                    WelcomeView()
                }
            }
            .captureWindowOpener()
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

/// Holds a reference to SwiftUI's openWindow action so the app delegate can open the
/// welcome window when the app is reopened with no visible windows.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: ((String) -> Void)?
}

private struct WindowOpenerCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { WindowOpener.shared.open = { id in openWindow(id: id) } }
    }
}

extension View {
    func captureWindowOpener() -> some View { modifier(WindowOpenerCapture()) }
}

/// Reopens the welcome window when the app is activated (e.g. dock click) with no windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowOpener.shared.open?("welcome")
        }
        return true
    }
}
