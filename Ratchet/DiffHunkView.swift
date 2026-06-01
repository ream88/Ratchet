//
//  DiffHunkView.swift
//  Ratchet
//
//  Renders a single diff hunk with colored, line-numbered rows and a comment editor.
//

import SwiftUI

struct DiffHunkView: View {
    let hunk: DiffHunk
    @ObservedObject var document: RepositoryDocument

    // Local mirror of the persisted comment so typing stays responsive and only this
    // view re-renders per keystroke. Synced to the store via onChange.
    @State private var commentText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.12))

            ForEach(hunk.lines) { line in
                DiffLineRow(line: line)
            }

            commentEditor
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.25), lineWidth: 1)
        )
        .task(id: hunk.id) {
            commentText = document.commentText(for: hunk)
        }
    }

    private var commentEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Review note", systemImage: "square.and.pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $commentText)
                .font(.body)
                .frame(minHeight: 56)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )
                .onChange(of: commentText) { _, newValue in
                    document.setComment(newValue, for: hunk)
                }
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)

            Text(marker)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(markerColor)

            Text(line.content.isEmpty ? " " : line.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.12)
        case .deletion: return Color.red.opacity(0.12)
        case .context: return Color.clear
        }
    }
}
