//
//  DiffHunkView.swift
//  Ratchet
//
//  Renders a single diff hunk with colored, line-numbered rows and a comment editor.
//  Lines can be selected (click the gutter; shift-click to extend) to attach a comment
//  to a specific range. A chunk can also be marked reviewed; reviewed chunks collapse.
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

    // Line-range selection + composer state.
    @State private var selectedRange: ClosedRange<Int>?
    @State private var anchorIndex: Int?
    @State private var isComposing = false
    @State private var lineComments: [(range: ClosedRange<Int>, record: ReviewComment)] = []
    @State private var isEditingNote = false
    @FocusState private var composerFocused: Bool
    @FocusState private var noteFocused: Bool

    init(hunk: DiffHunk, document: RepositoryDocument) {
        self.hunk = hunk
        _document = ObservedObject(wrappedValue: document)
        // Preload persisted state so the first frame is already correct — a reviewed (collapsed)
        // hunk renders collapsed immediately instead of rendering every line, then collapsing.
        let reviewed = document.isReviewed(hunk)
        _commentText = State(initialValue: document.commentText(for: hunk))
        _isReviewed = State(initialValue: reviewed)
        _isExpanded = State(initialValue: !reviewed)
        _lineComments = State(initialValue: document.lineComments(for: hunk))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                ForEach(Array(hunk.lines.enumerated()), id: \.element.id) { index, line in
                    lineBlock(index: index, line: line)
                }

                hunkNoteEditor
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
        .onChange(of: hunk.id) {
            // Only fires if SwiftUI reuses this instance for a different hunk; the initial
            // state is already seeded in init, so normal appearance does no extra work.
            commentText = document.commentText(for: hunk)
            let reviewed = document.isReviewed(hunk)
            isReviewed = reviewed
            isExpanded = !reviewed
            selectedRange = nil
            anchorIndex = nil
            isComposing = false
            isEditingNote = false
            refreshLineComments()
        }
        .onChange(of: document.reviewedTick) {
            // A file-level "mark all reviewed" may have changed this chunk; re-sync.
            let reviewedNow = document.isReviewed(hunk)
            if reviewedNow != isReviewed {
                isReviewed = reviewedNow
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded = !reviewedNow }
            }
        }
    }

    // MARK: Line block (row + its inline comments + composer)

    @ViewBuilder
    private func lineBlock(index: Int, line: DiffLine) -> some View {
        DiffLineRow(
            line: line,
            isSelected: selectedRange?.contains(index) ?? false,
            onTap: { handleTap(at: index) },
            onAddComment: { startComment(at: index) }
        )

        ForEach(visibleLineComments(endingAt: index), id: \.record.id) { item in
            LineCommentCard(
                text: Binding(
                    get: { document.commentText(forContentHash: item.record.contentHash) },
                    set: { document.updateLineComment($0, record: item.record, hunk: hunk); refreshLineComments() }
                ),
                rangeLabel: label(for: item.range),
                onDelete: {
                    document.updateLineComment("", record: item.record, hunk: hunk)
                    refreshLineComments()
                }
            )
            .padding(.leading, 60)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
        }

        if let range = selectedRange, range.upperBound == index {
            composerArea(for: range)
                .padding(.leading, 60)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
        }
    }

    // MARK: Header

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

            if hasAnyComment {
                Image(systemName: "text.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .help("Has review notes")
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
                Label(isReviewed ? "Reviewed" : "Mark as reviewed",
                      systemImage: isReviewed ? "checkmark.circle.fill" : "circle")
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
    }

    private var hasAnyComment: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !lineComments.isEmpty
    }

    // MARK: Selection + composer

    private func handleTap(at index: Int) {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        if shiftHeld, let anchor = anchorIndex {
            selectedRange = min(anchor, index)...max(anchor, index)
        } else if selectedRange == index...index {
            selectedRange = nil
            anchorIndex = nil
        } else {
            selectedRange = index...index
            anchorIndex = index
        }
        isComposing = false
    }

    /// Selects a single line and opens its comment composer immediately (the hover "+" button).
    private func startComment(at index: Int) {
        selectedRange = index...index
        anchorIndex = index
        isComposing = true
    }

    private func closeComposer() {
        isComposing = false
        selectedRange = nil
        anchorIndex = nil
        refreshLineComments()
    }

    @ViewBuilder
    private func composerArea(for range: ClosedRange<Int>) -> some View {
        // Bound directly to the store so the comment auto-saves as you type (like the
        // whole-chunk note). No Save button; empty text leaves nothing behind.
        let text = Binding<String>(
            get: { document.commentText(forContentHash: hunk.lineCommentContentHash(forRange: range)) },
            set: { document.setLineComment($0, for: hunk, range: range); refreshLineComments() }
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(label(for: range), systemImage: "text.cursor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { closeComposer() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            if isComposing {
                TextEditor(text: text)
                    .font(.body)
                    .frame(minHeight: 56)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .focused($composerFocused)
                    .onAppear { composerFocused = true }
            } else {
                Button("Add Comment") { isComposing = true }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func refreshLineComments() {
        lineComments = document.lineComments(for: hunk)
    }

    /// Line comments anchored to this row, excluding the range currently open in the composer
    /// (which already shows its own editor, so we avoid rendering a duplicate card).
    private func visibleLineComments(endingAt index: Int) -> [(range: ClosedRange<Int>, record: ReviewComment)] {
        lineComments.filter { item in
            item.range.upperBound == index && !(isComposing && item.range == selectedRange)
        }
    }

    /// A human-friendly "Line N" / "Lines N–M" label using the new-side numbers when present.
    private func label(for range: ClosedRange<Int>) -> String {
        func number(_ i: Int) -> String {
            let line = hunk.lines[i]
            return (line.newLineNumber ?? line.oldLineNumber).map(String.init) ?? "?"
        }
        if range.count == 1 { return "Line \(number(range.lowerBound))" }
        return "Lines \(number(range.lowerBound))–\(number(range.upperBound))"
    }

    // MARK: Whole-chunk note

    @ViewBuilder
    private var hunkNoteEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Note for whole chunk", systemImage: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isEditingNote {
                    Button("Done") { isEditingNote = false }
                        .controlSize(.small)
                }
            }

            // Only build the (heavy, NSTextView-backed) TextEditor while actually editing.
            // Otherwise show lightweight text / a button, so a big commit doesn't instantiate
            // a TextEditor per hunk.
            if isEditingNote {
                TextEditor(text: $commentText)
                    .font(.body)
                    .frame(minHeight: 56)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
                    .focused($noteFocused)
                    .onAppear { noteFocused = true }
                    .onChange(of: commentText) { _, newValue in
                        document.setComment(newValue, for: hunk)
                    }
            } else if commentText.isEmpty {
                Button("Add note") { isEditingNote = true }
                    .controlSize(.small)
            } else {
                Text(commentText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { isEditingNote = true }
            }
        }
    }
}

// MARK: - Inline line comment

private struct LineCommentCard: View {
    @Binding var text: String
    let rangeLabel: String
    let onDelete: () -> Void

    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(rangeLabel, systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isEditing {
                    Button("Done") { isEditing = false }
                        .controlSize(.small)
                } else {
                    Button {
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit comment")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete comment")
            }

            if isEditing {
                // Auto-saves through the binding; no Save button.
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 48)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } else {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Diff line

private struct DiffLineRow: View {
    let line: DiffLine
    var isSelected: Bool = false
    var onTap: () -> Void = {}
    var onAddComment: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            addCommentGutter

            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)

            Text(marker)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(markerColor)

            Text(line.content.isEmpty ? " " : line.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .overlay(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    /// Left gutter holding a "+" that fades in on hover to add a comment on this line.
    private var addCommentGutter: some View {
        Button(action: onAddComment) {
            Image(systemName: "plus.circle.fill")
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .background(Circle().fill(.background))
        }
        .buttonStyle(.plain)
        .frame(width: 24)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .help("Comment on this line")
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
