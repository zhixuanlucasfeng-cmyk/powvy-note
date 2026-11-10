import Foundation
import PowvyNoteCore
@main struct CloudSessionCheck {
    @MainActor static func main() async throws {
        let base = ProcessInfo.processInfo.environment["NOTE_TEST_URL"] ?? "http://localhost:8789"
        guard ["localhost", "127.0.0.1"].contains(URL(string: base)?.host ?? "") else { fatalError("local test only") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("POWVY_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NoteStore(dir: dir), sync = CloudSync(store: store)
        let password = "test-only-password-2026"
        await sync.login(endpoint: base, username: "sync-test", password: password)
        assert(sync.signedIn && !sync.needsLogin)
        try await Task.sleep(for: .seconds(1)); await sync.sync()
        func post(_ path: String, _ values: [String: Any], token: String = "") async throws -> [String: Any] {
            var r = URLRequest(url: URL(string: base + "/api/" + path)!); r.httpMethod = "POST";r.setValue("application/json", forHTTPHeaderField: "Content-Type");r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization");r.httpBody = try JSONSerialization.data(withJSONObject: values)
            let (data,response) = try await URLSession.shared.data(for: r); assert((response as! HTTPURLResponse).statusCode == 200)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        // Same password still rotates the credential hash and invalidates all existing sessions.
        let login = try await post("login", ["username":"sync-test","password":password,"native":true])
        _ = try await post("password", ["oldPassword":password,"password":password], token: login["token"] as! String)
        let n = try store.create(text: "unsynced draft must survive reauthentication")
        sync.track(n);await sync.sync();assert(sync.needsLogin);assert(store.load().contains {$0.text == n.text})
        await sync.login(endpoint: base, username: "sync-test", password: password)
        assert(sync.signedIn && !sync.needsLogin)
        try await Task.sleep(for: .seconds(1));await sync.sync();assert(store.load().contains {$0.text == n.text})
        let again = try await post("login", ["username":"sync-test","password":password,"native":true])
        _ = try await post("password", ["oldPassword":password,"password":password], token: again["token"] as! String)
        await sync.logout();assert(!sync.signedIn)
        print("Mac session check passed: expired login, draft preserved, reauthentication, expired logout; no real Keychain access")
    }
}
