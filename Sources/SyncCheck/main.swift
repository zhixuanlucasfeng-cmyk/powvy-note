import Foundation
import PowvyNoteCore
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: dir) }
let store = try NoteStore(dir: dir), sync = try SyncFolder(store: store, namespace: String(repeating: "a", count: 64))
let n = try store.create(text: "original"); assert(sync.pending.isEmpty)
let backup = try sync.importExisting(); assert(FileManager.default.fileExists(atPath: backup.appendingPathComponent(n.url.lastPathComponent).path))
let first = sync.pending[0]
try store.save(Note(url: n.url, text: "typed while uploading"))
try sync.accept(first, remote: RemoteNote(id: first.id, text: "original", version: 1, deleted: false))
assert(sync.pending[0].text == "typed while uploading"); assert(sync.pending[0].version == 1)
let second = sync.pending[0]
try sync.resolveConflict(second, remote: RemoteNote(id: first.id, text: "other device", version: 2, deleted: false))
assert(store.load().contains { $0.text.contains("typed while uploading") })
assert(store.load().contains { $0.text == "other device" })
let reloaded = try SyncFolder(store: store, namespace: String(repeating: "a", count: 64)); assert(reloaded.pending.count == 1)
try reloaded.merge([RemoteNote(id: first.id, text: "", version: 3, deleted: true)])
assert(!store.load().contains { $0.text == "other device" });assert(store.load().contains { $0.text.contains("typed while uploading") })
let isolated = try SyncFolder(store: store, namespace: String(repeating: "b", count: 64)); assert(isolated.pending.isEmpty)
print("Sync checks passed: backup, concurrent edit, conflict, deletion, relaunch, account isolation")

if let base = ProcessInfo.processInfo.environment["NOTE_TEST_URL"] {
    guard let host = URL(string: base)?.host, ["localhost", "127.0.0.1"].contains(host) else { fatalError("Network checks are local-only") }
    func request(_ path: String, method: String = "GET", token: String = "", body: [String: Any]? = nil) async throws -> (Int, Data) {
        var r = URLRequest(url: URL(string: base + "/api/" + path)!); r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); if !token.isEmpty { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: r); return ((response as! HTTPURLResponse).statusCode, data)
    }
    let login = try await request("login", method: "POST", body: ["username": "sync-test", "password": "test-only-password-2026", "native": true])
    assert(login.0 == 200)
    let token = (try JSONSerialization.jsonObject(with: login.1) as! [String: Any])["token"] as! String
    let local = try NoteStore(dir: dir.appendingPathComponent("network")), engine = try SyncFolder(store: local, namespace: String(repeating: "c", count: 64))
    _ = try local.create(text: "Mac network note"); try engine.importExisting(); let snapshot = engine.pending[0]
    let put = try await request("notes/" + snapshot.id, method: "PUT", token: token, body: ["text": snapshot.text, "deleted": false, "baseVersion": 0])
    struct Reply: Decodable { let note: RemoteNote }
    assert(put.0 == 200); try engine.accept(snapshot, remote: JSONDecoder().decode(Reply.self, from: put.1).note)
    let update = try await request("notes/" + snapshot.id, method: "PUT", token: token, body: ["text": "iPhone changed this", "deleted": false, "baseVersion": 1])
    assert(update.0 == 200); let remote = try JSONDecoder().decode(Reply.self, from: update.1).note
    try engine.merge([remote]); assert(local.load().first!.text == "iPhone changed this")
    print("Mac → API → Mac cross-device check passed")
}
