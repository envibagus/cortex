import Foundation

// MARK: - LibraryStore
//
// Persists the user's library metadata (favorites + collections) that has no home
// on disk otherwise. Skills/agents/commands/rules themselves stay read-from-disk;
// only the favorite flags and collection membership are stored here, as JSON at
// ~/Library/Application Support/Cortex/library.json. Items are referenced by their
// stable ConfigItem id (the resolved file path).

@MainActor
@Observable
final class LibraryStore {
    struct Collection: Identifiable, Codable, Hashable {
        var id: String
        var name: String
        var icon: String
        var memberIDs: [String]
    }

    private(set) var favorites: Set<String> = []
    private(set) var collections: [Collection] = []

    // MARK: Persistence

    private struct Persisted: Codable {
        var favorites: [String]
        var collections: [Collection]
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cortex", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        favorites = Set(p.favorites)
        collections = p.collections
    }

    private func persist() {
        let payload = Persisted(favorites: Array(favorites), collections: collections)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Favorites

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        persist()
    }

    // MARK: Collections

    @discardableResult
    func createCollection(name: String, icon: String = "rectangle.stack") -> Collection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = Collection(id: UUID().uuidString,
                                    name: trimmed.isEmpty ? "Untitled" : trimmed,
                                    icon: icon, memberIDs: [])
        collections.append(collection)
        persist()
        return collection
    }

    func deleteCollection(_ id: String) {
        collections.removeAll { $0.id == id }
        persist()
    }

    func renameCollection(_ id: String, to name: String) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func isMember(_ itemID: String, of collectionID: String) -> Bool {
        collections.first { $0.id == collectionID }?.memberIDs.contains(itemID) ?? false
    }

    func toggleMember(_ itemID: String, in collectionID: String) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if let j = collections[i].memberIDs.firstIndex(of: itemID) {
            collections[i].memberIDs.remove(at: j)
        } else {
            collections[i].memberIDs.append(itemID)
        }
        persist()
    }

    func collections(containing itemID: String) -> [Collection] {
        collections.filter { $0.memberIDs.contains(itemID) }
    }

    func memberCount(_ id: String) -> Int {
        collections.first { $0.id == id }?.memberIDs.count ?? 0
    }
}
