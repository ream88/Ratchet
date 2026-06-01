//
//  RecentRepositoriesStore.swift
//  Ratchet
//
//  Tracks recently opened repositories for the welcome screen. Persisted as a plain
//  list of paths in UserDefaults.
//

import Foundation
import Combine

@MainActor
final class RecentRepositoriesStore: ObservableObject {
    static let shared = RecentRepositoriesStore()

    private let key = "recentRepositoryPaths"
    private let maxCount = 12

    @Published private(set) var paths: [String]

    init() {
        paths = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Recent repositories that still exist on disk, most-recent first.
    var urls: [URL] {
        paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    func add(_ url: URL) {
        let path = url.path(percentEncoded: false)
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
        persist()
    }

    func remove(_ url: URL) {
        paths.removeAll { $0 == url.path(percentEncoded: false) }
        persist()
    }

    func clear() {
        paths = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(paths, forKey: key)
    }
}
