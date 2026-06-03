//
//  DiffStatView.swift
//  Ratchet
//
//  GitHub-style change summary: "+10 -2" next to a five-box bar whose green/red/empty
//  split is proportional to the additions and deletions. Shared by commit rows and hunks.
//

import SwiftUI

struct DiffStatView: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)")
                .foregroundStyle(.green)
            Text("-\(deletions)")
                .foregroundStyle(.red)

            HStack(spacing: 2) {
                let split = boxes
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(for: index, split: split))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .font(.system(.caption, design: .rounded).weight(.semibold))
        .monospacedDigit()
        .fixedSize()
        .help("\(additions) addition\(additions == 1 ? "" : "s"), "
              + "\(deletions) deletion\(deletions == 1 ? "" : "s")")
    }

    /// How many of the five boxes are green vs. red — the rest stay empty. Matches GitHub's
    /// proportional split, guaranteeing a nonzero side gets at least one box.
    private var boxes: (green: Int, red: Int) {
        let total = additions + deletions
        guard total > 5 else { return (additions, deletions) }

        var green = Int((Double(additions) / Double(total) * 5).rounded())
        var red = Int((Double(deletions) / Double(total) * 5).rounded())
        if additions > 0 { green = max(green, 1) }
        if deletions > 0 { red = max(red, 1) }
        while green + red > 5 {
            if green >= red { green -= 1 } else { red -= 1 }
        }
        return (green, red)
    }

    private func color(for index: Int, split: (green: Int, red: Int)) -> Color {
        if index < split.green { return .green }
        if index < split.green + split.red { return .red }
        return Color.secondary.opacity(0.25)
    }
}
