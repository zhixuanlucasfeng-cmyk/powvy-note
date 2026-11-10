import Foundation

public struct RemoteNote: Codable {
    public var id: String
    public var text: String
    public var version: Int
    public var deleted: Bool
    public var updated: Double?
    public init(id: String, text: String, version: Int, deleted: Bool, updated: Double? = nil) {
        self.id = id; self.text = text; self.version = version; self.deleted = deleted; self.updated = updated
    }
}
public struct SyncRecord: Codable {
    public var id: String, text: String, mutation: String, filename: String
    public var version: Int
    public var deleted: Bool, dirty: Bool
}
/// Caller serializes operations on the main actor. Only explicitly linked files are scanned.
public final class SyncFolder {
    public let store: NoteStore
    public private(set) var records: [String: SyncRecord] = [:]
    private let stateURL: URL
    private let fm = FileManager.default
    public init(store: NoteStore, namespace: String) throws {
        guard namespace.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SyncError.invalidData }
        self.store = store
        let folder = store.dir.appendingPathComponent(".sync", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        stateURL = folder.appendingPathComponent(namespace + ".json")
        if fm.fileExists(atPath: stateURL.path) { records = try JSONDecoder().decode([String: SyncRecord].self, from: Data(contentsOf: stateURL)) }
        for r in records.values { try validate(r.id); guard URL(fileURLWithPath: r.filename).lastPathComponent == r.filename, r.filename.hasSuffix(".md") else { throw SyncError.invalidData } }
    }
    public enum SyncError: Error { case invalidData }
    private func validate(_ id: String) throws { guard UUID(uuidString: id) != nil else { throw SyncError.invalidData } }
    private func persist() throws { try JSONEncoder().encode(records).write(to: stateURL, options: .atomic) }
    private func path(_ r: SyncRecord) -> URL { store.dir.appendingPathComponent(r.filename) }
    public var pending: [SyncRecord] { records.values.filter { $0.dirty } }
    public var unlinkedCount: Int { store.load().filter { n in !records.values.contains { $0.filename == n.url.lastPathComponent } }.count }
    public func track(_ note: Note) throws {
        if records.values.contains(where: { $0.filename == note.url.lastPathComponent }) { return }
        let id = UUID().uuidString.lowercased()
        records[id] = SyncRecord(id: id, text: note.text, mutation: UUID().uuidString.lowercased(), filename: note.url.lastPathComponent, version: 0, deleted: false, dirty: true)
        try persist()
    }
    /// Backup completes before any existing note is queued for upload.
    @discardableResult public func importExisting() throws -> URL {
        let backup = store.dir.appendingPathComponent("Backups/" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let notes = store.load()
        for n in notes { try fm.copyItem(at: n.url, to: backup.appendingPathComponent(n.url.lastPathComponent)) }
        for n in notes { try track(n) }
        return backup
    }
    public func scan() throws {
        for (id, var r) in records {
            let exists = fm.fileExists(atPath: path(r).path)
            let text = exists ? try String(contentsOf: path(r), encoding: .utf8) : ""
            if r.text != text || r.deleted == exists {
                r.text = text; r.deleted = !exists; r.dirty = true; r.mutation = UUID().uuidString.lowercased(); records[id] = r
            }
        }
        try persist()
    }
    private func install(_ remote: RemoteNote) throws {
        try validate(remote.id)
        let filename = records[remote.id]?.filename ?? "cloud-\(stateURL.deletingPathExtension().lastPathComponent.prefix(12))-\(remote.id).md"
        let r = SyncRecord(id: remote.id, text: remote.text, mutation: UUID().uuidString.lowercased(), filename: filename, version: remote.version, deleted: remote.deleted, dirty: false)
        if remote.deleted {
            if fm.fileExists(atPath: path(r).path) { try store.delete(Note(url: path(r), text: "")) }
        } else { try store.save(Note(url: path(r), text: remote.text)) }
        records[remote.id] = r
        try persist()
    }
    public func accept(_ snapshot: SyncRecord, remote: RemoteNote) throws {
        try scan()
        guard var local = records[snapshot.id] else { return }
        if local.mutation == snapshot.mutation {
            local.version = remote.version; local.dirty = false; records[snapshot.id] = local
        } else { local.version = remote.version; records[snapshot.id] = local }
        try persist()
    }
    /// A stale deletion restores the remote edit; a stale edit becomes a separate local copy.
    @discardableResult public func resolveConflict(_ snapshot: SyncRecord, remote: RemoteNote?) throws -> Bool {
        try scan()
        guard let local = records[snapshot.id], local.mutation == snapshot.mutation else { return false }
        if !snapshot.deleted {
            let id = snapshot.mutation
            try validate(id)
            let text = "# 冲突副本 / Conflict copy\n\n" + snapshot.text
            let copy = SyncRecord(id: id, text: text, mutation: UUID().uuidString.lowercased(), filename: "conflict-\(id).md", version: 0, deleted: false, dirty: true)
            try store.save(Note(url: path(copy), text: text))
            records[id] = copy
            try persist() // Preserve the copy durably before replacing the original.
        }
        if let remote { try install(remote) }
        else { records.removeValue(forKey: snapshot.id); try persist() }
        return true
    }
    public func merge(_ incoming: [RemoteNote]) throws {
        try scan()
        for n in incoming {
            if let local = records[n.id], local.dirty || local.version >= n.version { continue }
            try install(n)
        }
    }
}
