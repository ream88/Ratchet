//
//  DiffHunkView.swift
//  Ratchet
//
//  Renders a single diff hunk with colored, line-numbered rows and a comment editor.
//  A chunk can be marked reviewed; reviewed chunks collapse to keep the view light.
//

import SwiftUI

struct DiffHunkView: View {
    let hunk: DiffHunk
    @ObservedObject var document: RepositoryDocument

    // Local mirrors of persisted state so typing/toggling stay responsive and only this
    // view re-renders. Synced to the store via onChange / explicit writes.
    @State private var commentText = ""
    @State private var isReviewed = false
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line)
                }
                commentEditor
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isReviewed ? Color.green.opacity(0.55) : Color.gray.opacity(0.25),
                        lineWidth: 1)
        )
        .opacity(isReviewed && !isExpanded ? 0.7 : 1)
        .task(id: hunk.id) {
            // Load persisted state for this chunk; collapse it if already reviewed.
            commentText = document.commentText(for: hunk)
            isReviewed = document.isReviewed(hunk)
            isExpanded = !isReviewed
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(hunk.header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if commentHasText {
                Image(systemName: "text.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .help("Has a review note")
            }

            Spacer()

            Toggle(isOn: Binding(
                get: { isReviewed },
                set: { newValue in
                    isReviewed = newValue
                    document.setReviewed(newValue, for: hunk)
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded = !newValue }
                }
            )) {
                Label("Reviewed", systemImage: isReviewed ? "checkmark.circle.fill" : "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isReviewed ? Color.green.opacity(0.12) : Color.gray.opacity(0.12))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
    }

    private var commentHasText: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
