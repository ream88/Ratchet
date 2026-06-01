//
//  GitService.swift
//  Ratchet
//
//  Thin wrapper around the system `git` command-line tool, invoked via Process.
//

import Foundation

enum GitError: LocalizedError {
    case gitNotFound
    case notARepository(String)
    case commandFailed(command: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .gitNotFound:
            return "Could not find the git command-line tool. Install the Xcode Command Line Tools (xcode-select --install) and try again."
        case .notARepository(let path):
            return "“\(path)” is not a Git repository."
        case .commandFailed(let command, let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(command) failed (exit \(status)).\(detail.isEmpty ? "" : "\n\n\(detail)")"
        }
    }
}

/// Runs git commands against a single repository. Stateless aside from the repo URL,
/// so its methods are `nonisolated` and safe to await from the main actor.
struct GitService {
    let repositoryURL: URL

    nonisolated var repositoryPath: String { repositoryURL.path(percentEncoded: false) }

    // MARK: Public API

    /// Throws unless the folder is inside a git work tree.
    nonisolated func validateRepository() async throws {
        let output = try await run(["rev-parse", "--is-inside-work-tree"])
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw GitError.notARepository(repositoryPath)
        }
    }

    /// SHAs reachable from `branch` but not from `base` — i.e. the commits `branch` is ahead by.
    nonisolated func commitsAhead(branch: String, base: String, limit: Int = 2000) async throws -> [String] {
        let output = try await run(["rev-list", "\(base)..\(branch)", "-n", String(limit)])
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The name of the currently checked-out branch, or nil for a detached HEAD.
    nonisolated func currentBranch() async throws -> String? {
        let name = try await run(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty || name == "HEAD") ? nil : name
    }

    /// All local and remote branches.
    nonisolated func branches() async throws -> [GitBranch] {
        // %(HEAD) is "*" for the current branch, refname:short gives a clean name.
        let format = "%(HEAD)%09%(refname:short)"
        let output = try await run(["branch", "--all", "--format=\(format)"])

        var branches: [GitBranch] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.components(separatedBy: "\t")
            guard parts.count == 2 else { continue }
            let isCurrent = parts[0].trimmingCharacters(in: .whitespaces) == "*"
            let name = parts[1].trimmingCharacters(in: .whitespaces)

            // Skip symbolic refs like "origin/HEAD -> origin/main".
            if name.contains("->") || name.isEmpty { continue }

            let isRemote = name.hasPrefix("remotes/") || name.hasPrefix("origin/")
            branches.append(GitBranch(name: name, isCurrent: isCurrent, isRemote: isRemote))
        }
        return branches
    }

    /// Commits reachable from `branch`, newest first. Capped for responsiveness on large repos.
    /// TODO: paginate / load more on scroll instead of a fixed cap.
    nonisolated func commits(branch: String, limit: Int = 300) async throws -> [GitCommit] {
        // Unit separator (US, 0x1f) between fields; record separator (RS, 0x1e) between commits.
        let format = "%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1e"
        let output = try await run([
            "log", branch,
            "--pretty=format:\(format)",
            "-n", String(limit),
        ])

        let formatter = ISO8601DateFormatter()
        var commits: [GitCommit] = []
        for record in output.components(separatedBy: "\u{1e}") {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let fields = trimmed.components(separatedBy: "\u{1f}")
            guard fields.count == 5 else { continue }
            commits.append(GitCommit(
                id: fields[0],
                shortSHA: fields[1],
                title: fields[2],
                author: fields[3],
                date: formatter.date(from: fields[4])
            ))
        }
        return commits
    }

    /// The raw unified diff for a single commit (vs. its first parent), with no commit header.
    /// A small context window keeps the review focused on the changed chunks, not whole files.
    nonisolated func diff(forCommit sha: String, contextLines: Int = 3) async throws -> String {
        return try await run([
            "show",
            "--format=",
            "--unified=\(contextLines)",
            "--no-color",
            sha,
        ])
    }

    // MARK: Process plumbing

    private nonisolated func run(_ arguments: [String]) async throws -> String {
        let gitURL = try Self.resolveGitURL()
        let fullArguments = ["-C", repositoryPath] + arguments

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = gitURL
                process.arguments = fullArguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                // Read both pipes on separate threads so a full pipe buffer can never
                // deadlock the child (large diffs easily exceed the 64KB buffer).
                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                process.waitUntilExit()
                group.wait()

                let stdoutString = String(decoding: outData, as: UTF8.self)
                if process.terminationStatus != 0 {
                    let stderrString = String(decoding: errData, as: UTF8.self)
                    continuation.resume(throwing: GitError.commandFailed(
                        command: arguments.first ?? "",
                        status: process.terminationStatus,
                        message: stderrString
                    ))
                    return
                }
                continuation.resume(returning: stdoutString)
            }
        }
    }

    /// Locates the git binary. GUI apps get a minimal PATH, so we probe known locations.
    private nonisolated static func resolveGitURL() throws -> URL {
        let candidates = [
            "/usr/bin/git",            // Xcode Command Line Tools shim
            "/opt/homebrew/bin/git",   // Apple Silicon Homebrew
            "/usr/local/bin/git",      // Intel Homebrew
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw GitError.gitNotFound
    }
}
