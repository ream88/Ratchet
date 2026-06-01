//
//  DiffParser.swift
//  Ratchet
//
//  Parses raw unified `git` diff output into structured DiffFile/DiffHunk/DiffLine models.
//

import Foundation

enum DiffParser {

    /// Parses the output of `git show --unified=N` into per-file diffs.
    static func parse(_ rawDiff: String) -> [DiffFile] {
        var files: [DiffFile] = []

        var currentPath: String?
        var currentIsBinary = false
        var currentHunks: [DiffHunk] = []

        // In-progress hunk state.
        var hunkHeader: String?
        var hunkOldStart: Int?
        var hunkNewStart: Int?
        var hunkLines: [DiffLine] = []
        var oldCursor = 0
        var newCursor = 0

        func flushHunk() {
            guard let header = hunkHeader else { return }
            currentHunks.append(DiffHunk(
                id: UUID(),
                filePath: currentPath ?? "",
                header: header,
                oldStartLine: hunkOldStart,
                newStartLine: hunkNewStart,
                lines: hunkLines
            ))
            hunkHeader = nil
            hunkLines = []
        }

        func flushFile() {
            flushHunk()
            guard let path = currentPath else { return }
            files.append(DiffFile(id: UUID(), path: path, hunks: currentHunks, isBinary: currentIsBinary))
            currentPath = nil
            currentIsBinary = false
            currentHunks = []
        }

        // `git show` uses LF line endings; keep empty trailing components so blank context
        // lines (a single space) survive.
        let lines = rawDiff.components(separatedBy: "\n")

        for line in lines {
            if line.hasPrefix("diff --git") {
                flushFile()
                // Provisional path from the "diff --git a/x b/y" line; refined by +++/--- below.
                currentPath = pathFromDiffGitLine(line)
                continue
            }

            if line.hasPrefix("Binary files") {
                currentIsBinary = true
                continue
            }

            // File header lines. Prefer the new-side path; fall back to the old side for deletions.
            if line.hasPrefix("--- ") {
                if let path = path(fromHeaderLine: line, prefix: "--- "), currentPath == nil {
                    currentPath = path
                }
                continue
            }
            if line.hasPrefix("+++ ") {
                if let path = path(fromHeaderLine: line, prefix: "+++ ") {
                    currentPath = path
                }
                continue
            }

            // Skip the remaining metadata lines (index, mode changes, rename info, etc.).
            if line.hasPrefix("index ") || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("deleted file") || line.hasPrefix("new file")
                || line.hasPrefix("rename ") || line.hasPrefix("copy ")
                || line.hasPrefix("similarity ") || line.hasPrefix("dissimilarity ") {
                continue
            }

            if line.hasPrefix("@@") {
                flushHunk()
                hunkHeader = line
                let ranges = parseHunkRanges(line)
                hunkOldStart = ranges.oldStart
                hunkNewStart = ranges.newStart
                oldCursor = ranges.oldStart ?? 0
                newCursor = ranges.newStart ?? 0
                continue
            }

            // Only consume body lines once we're inside a hunk.
            guard hunkHeader != nil else { continue }

            // "\ No newline at end of file" — metadata, not a content line.
            if line.hasPrefix("\\") { continue }

            guard let marker = line.first else {
                // A truly empty string represents an empty context line.
                hunkLines.append(DiffLine(id: UUID(), kind: .context,
                                          oldLineNumber: oldCursor, newLineNumber: newCursor,
                                          content: ""))
                oldCursor += 1
                newCursor += 1
                continue
            }

            let content = String(line.dropFirst())
            switch marker {
            case "+":
                hunkLines.append(DiffLine(id: UUID(), kind: .addition,
                                          oldLineNumber: nil, newLineNumber: newCursor,
                                          content: content))
                newCursor += 1
            case "-":
                hunkLines.append(DiffLine(id: UUID(), kind: .deletion,
                                          oldLineNumber: oldCursor, newLineNumber: nil,
                                          content: content))
                oldCursor += 1
            case " ":
                hunkLines.append(DiffLine(id: UUID(), kind: .context,
                                          oldLineNumber: oldCursor, newLineNumber: newCursor,
                                          content: content))
                oldCursor += 1
                newCursor += 1
            default:
                // Unexpected line; ignore rather than corrupt the hunk.
                continue
            }
        }

        flushFile()
        return files
    }

    // MARK: - Helpers

    /// Extracts the start line numbers from a hunk header `@@ -a,b +c,d @@ ...`.
    private static func parseHunkRanges(_ header: String) -> (oldStart: Int?, newStart: Int?) {
        var oldStart: Int?
        var newStart: Int?
        if let minusRange = header.range(of: "-") {
            oldStart = leadingInt(header[minusRange.upperBound...])
        }
        if let plusRange = header.range(of: "+") {
            newStart = leadingInt(header[plusRange.upperBound...])
        }
        return (oldStart, newStart)
    }

    private static func leadingInt<S: StringProtocol>(_ s: S) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits)
    }

    /// Pulls a file path from a `--- a/path` or `+++ b/path` header line.
    private static func path(fromHeaderLine line: String, prefix: String) -> String? {
        var value = String(line.dropFirst(prefix.count))
        value = value.trimmingCharacters(in: .whitespaces)
        if value == "/dev/null" { return nil }
        // Strip the conventional a/ or b/ prefix.
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        return value.isEmpty ? nil : value
    }

    /// Best-effort path from `diff --git a/foo b/foo` (used until +++/--- refine it).
    private static func pathFromDiffGitLine(_ line: String) -> String? {
        let body = line.dropFirst("diff --git ".count)
        // Take the "b/" side, which is the last whitespace-separated token for non-renames.
        guard let bToken = body.split(separator: " ").last else { return nil }
        var value = String(bToken)
        if value.hasPrefix("b/") || value.hasPrefix("a/") {
            value = String(value.dropFirst(2))
        }
        return value.isEmpty ? nil : value
    }
}
