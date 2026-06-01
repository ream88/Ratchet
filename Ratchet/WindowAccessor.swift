//
//  WindowAccessor.swift
//  Ratchet
//
//  Bridges to the hosting NSWindow to give it a frame autosave name, so each repository
//  window remembers its size and position across launches.
//

import SwiftUI
import AppKit

struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName(name)
            window.setFrameUsingName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Persists the hosting window's frame under `name` (size + position restoration).
    func persistWindowFrame(_ name: String) -> some View {
        background(WindowFrameAutosave(name: name))
    }
}
