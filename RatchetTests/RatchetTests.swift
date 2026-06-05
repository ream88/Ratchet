//
//  RatchetTests.swift
//  RatchetTests
//
//  Created by Mario Uher on 01.06.26.
//

import Foundation
import Testing
@testable import Ratchet

@MainActor
struct RatchetTests {

    // MARK: Helpers

    private func makeHunk(filePath: String, additions: [String], id: UUID = UUID()) -> DiffHunk {
        let lines = additions.enumerated().map { index, content in
            DiffLine(id: UUID(), kind: .addition,
                     oldLineNumber: nil, newLineNumber: index + 1, content: content)
        }
        return DiffHunk(id: id, filePath: filePath, header: "@@ -1 +1 @@",
                        oldStartLine: 1, newStartLine: 1, lines: lines)
    }

    private func makeDocument(store: ReviewStore) -> RepositoryDocument {
        let doc = RepositoryDocument(repositoryURL: URL(fileURLWithPath: "/tmp/ratchet-test"),
                                     store: store)
        doc.selectedCommit = GitCommit(id: "sha1", shortSHA: "sha1", title: "t",
                                       author: "a", date: nil, additions: 0, deletions: 0)
        return doc
    }

    // MARK: contentSignature

    @Test func identicalChangesShareSignatureButNotHash() {
        let a = makeHunk(filePath: "A.swift", additions: ["import New"])
        let b = makeHunk(filePath: "B.swift", additions: ["import New"])

        // The same change in different files: same signature (groups duplicates) but
        // different per-file hash (keys distinct persisted review state).
        #expect(a.contentSignature == b.contentSignature)
        #expect(a.contentHash != b.contentHash)
    }

    @Test func differentChangesDifferInSignature() {
        let a = makeHunk(filePath: "A.swift", additions: ["import New"])
        let c = makeHunk(filePath: "A.swift", additions: ["import Other"])
        #expect(a.contentSignature != c.contentSignature)
    }

    /// The real-world case: the same `import OldModule` → `import NewModule` edit in two files
    /// whose *surrounding context differs*. Run through the actual parser, the two hunks must
    /// still share a signature (context excluded) — otherwise the feature misses real renames.
    @Test func crossFileRenameMatchesThroughParser() {
        let rawDiff = """
        diff --git a/Sources/Bar.swift b/Sources/Bar.swift
        index 458ecbf..a0341fb 100644
        --- a/Sources/Bar.swift
        +++ b/Sources/Bar.swift
        @@ -1,5 +1,5 @@
         import SwiftUI
        -import OldModule
        +import NewModule
        \u{0020}
         struct Bar: View {
             var body: some View { Text("hi") }
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        index 9d03fb3..03bd57a 100644
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,5 +1,5 @@
         import Foundation
        -import OldModule
        +import NewModule
        \u{0020}
         final class Foo {
             let value = 1
        """

        let files = DiffParser.parse(rawDiff)
        let hunks = files.flatMap(\.hunks)
        #expect(hunks.count == 2)
        // Same change, different context and different files → equal signature, distinct hash.
        #expect(hunks[0].contentSignature == hunks[1].contentSignature)
        #expect(hunks[0].contentHash != hunks[1].contentHash)
    }

    // MARK: Review propagation

    @Test func markReviewedOffersIdenticalHunksAndAppliesToAll() {
        let store = ReviewStore(inMemory: true)
        let doc = makeDocument(store: store)
        let h1 = makeHunk(filePath: "A.swift", additions: ["import New"])
        let h2 = makeHunk(filePath: "B.swift", additions: ["import New"])
        let h3 = makeHunk(filePath: "C.swift", additions: ["unrelated"])
        doc.diffFiles = [
            DiffFile(id: UUID(), path: "A.swift", hunks: [h1]),
            DiffFile(id: UUID(), path: "B.swift", hunks: [h2]),
            DiffFile(id: UUID(), path: "C.swift", hunks: [h3]),
        ]

        doc.markReviewed(h1)

        // The acted hunk is reviewed immediately; the suggestion offers only the identical one.
        #expect(doc.isReviewed(h1))
        #expect(doc.batchSuggestion?.count == 1)
        #expect(doc.batchSuggestion?.targets.first?.id == h2.id)

        doc.applyBatchSuggestion()
        #expect(doc.isReviewed(h2))
        #expect(!doc.isReviewed(h3))
        #expect(doc.batchSuggestion == nil)
    }

    @Test func justThisOneSuppressesReask() {
        let store = ReviewStore(inMemory: true)
        let doc = makeDocument(store: store)
        let h1 = makeHunk(filePath: "A.swift", additions: ["import New"])
        let h2 = makeHunk(filePath: "B.swift", additions: ["import New"])
        doc.diffFiles = [
            DiffFile(id: UUID(), path: "A.swift", hunks: [h1]),
            DiffFile(id: UUID(), path: "B.swift", hunks: [h2]),
        ]

        doc.markReviewed(h1)
        #expect(doc.batchSuggestion != nil)
        doc.dismissBatchSuggestion()
        #expect(doc.batchSuggestion == nil)

        // Marking the identical sibling must not re-offer the same change this commit.
        doc.markReviewed(h2)
        #expect(doc.batchSuggestion == nil)
        #expect(doc.isReviewed(h2))
    }

    // MARK: Comment propagation

    @Test func commentPropagationOffersUnnotedHunksAndCopiesNote() {
        let store = ReviewStore(inMemory: true)
        let doc = makeDocument(store: store)
        let h1 = makeHunk(filePath: "A.swift", additions: ["import New"])
        let h2 = makeHunk(filePath: "B.swift", additions: ["import New"])
        let h3 = makeHunk(filePath: "C.swift", additions: ["import New"])
        doc.diffFiles = [
            DiffFile(id: UUID(), path: "A.swift", hunks: [h1]),
            DiffFile(id: UUID(), path: "B.swift", hunks: [h2]),
            DiffFile(id: UUID(), path: "C.swift", hunks: [h3]),
        ]

        // h3 already has a (different) note — it must not be clobbered.
        doc.setComment("keep me", for: h3)
        doc.setComment("rename leftover", for: h1)
        doc.suggestCommentPropagation(from: h1)

        #expect(doc.batchSuggestion?.count == 1)
        #expect(doc.batchSuggestion?.targets.first?.id == h2.id)

        doc.applyBatchSuggestion()
        #expect(doc.commentText(for: h2) == "rename leftover")
        #expect(doc.commentText(for: h3) == "keep me")
    }

    // MARK: Uncommitted changes entry

    @Test func uncommittedCommitIsIdentifiedAndCarriesStats() {
        let wip = GitCommit.uncommitted(additions: 12, deletions: 3)
        #expect(wip.isUncommitted)
        #expect(wip.id == GitCommit.uncommittedID)
        #expect(wip.additions == 12)
        #expect(wip.deletions == 3)

        let real = GitCommit(id: "abc123", shortSHA: "abc123", title: "t",
                             author: "a", date: nil, additions: 0, deletions: 0)
        #expect(!real.isUncommitted)
    }

    @Test func commitIdentityIgnoresStatsSoSelectionSurvivesRefresh() {
        // Two working-tree snapshots with different line counts are the same entry, so the
        // sidebar selection (compared by Equatable) persists across a refresh.
        let before = GitCommit.uncommitted(additions: 1, deletions: 0)
        let after = GitCommit.uncommitted(additions: 9, deletions: 4)
        #expect(before == after)
        #expect([before].contains(after))
    }
}
