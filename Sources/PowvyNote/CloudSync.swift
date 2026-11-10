import Foundation
import SwiftUI
import Security
import CryptoKit
import PowvyNoteCore

struct CloudUser: Codable { let id: String; let username: String }
private struct CloudSession: Codable { let endpoint: String; let user: CloudUser; let token: String }
private enum SessionKeychain {
    static let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.lucasfeng.powvynote.sync", kSecAttrAccount as String: "cloud"]
    static func read() throws -> Data? {
        var query = key; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }; guard code == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
        return result as? Data
    }
    static func save(_ data: Data) throws {
        let attrs = [kSecValueData as String: data]
        var code = SecItemUpdate(key as CFDictionary, attrs as CFDictionary)
        if code == errSecItemNotFound { var query = key; query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; code = SecItemAdd(query as CFDictionary, nil) }
        guard code == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
    }
    static func delete() throws { let code = SecItemDelete(key as CFDictionary); guard code == errSecSuccess || code == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) } }
}

@MainActor final class CloudSync: ObservableObject {
    @Published var message = "仅保存在这台 Mac / Local only"
    @Published var username = ""
    @Published var endpoint = "https://powvy-note.zhixuanlucasfeng.workers.dev"
    @Published var signedIn = false
    @Published var running = false
    @Published var needsLogin = false
    @Published var unlinked = 0
    var onChanges: (() -> Void)?
    private let store: NoteStore
    private var session: CloudSession?
    private var folder: SyncFolder?
    private var timer: Timer?
    private var debounce: Timer?
    init(store: NoteStore) {
        self.store = store
        // Test/preview directories never read the user's Keychain session.
        if ProcessInfo.processInfo.environment["POWVY_DIR"] == nil {
            do { if let data = try SessionKeychain.read() { try attach(JSONDecoder().decode(CloudSession.self, from: data)) } }
            catch { message = "同步未启用：\(error.localizedDescription)" }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in await self?.sync() } }
    }
    private func attach(_ s: CloudSession) throws {
        let namespace = SHA256.hash(data: Data((s.endpoint + "|" + s.user.id).utf8)).map { String(format: "%02x", $0) }.joined()
        let newFolder = try SyncFolder(store: store, namespace: namespace)
        session = s; folder = newFolder; endpoint = s.endpoint; username = s.user.username; signedIn = true; needsLogin = false; unlinked = newFolder.unlinkedCount
        message = unlinked > 0 ? "已登录 · 本机笔记尚未导入" : "已登录 · 等待同步"
    }
    private func request(_ path: String, method: String = "GET", payload: [String: Any]? = nil, endpoint: String? = nil, token: String? = nil) async throws -> (Int, Data) {
        guard let url = URL(string: (endpoint ?? self.endpoint) + "/api/" + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userID = session?.user.id, !["login"].contains(path) { req.setValue(userID, forHTTPHeaderField: "X-Powvy-User") }
        if let t = token ?? session?.token { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        if let payload { req.httpBody = try JSONSerialization.data(withJSONObject: payload) }
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 500, data)
    }
    private func checked(_ result: (Int, Data)) throws -> Data {
        guard (200..<300).contains(result.0) else {
            let json = (try? JSONSerialization.jsonObject(with: result.1)) as? [String: Any]
            throw NSError(domain: "PowvySync", code: result.0, userInfo: [NSLocalizedDescriptionKey: json?["error"] as? String ?? "同步服务暂时不可用"])
        }; return result.1
    }
    func login(endpoint raw: String, username: String, password: String) async {
        guard !running else { return }; running = true; defer { running = false }
        do {
            let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let u = URL(string: base), u.user == nil, u.password == nil, u.query == nil, u.fragment == nil, u.path.isEmpty,
                  u.scheme == "https" || (u.scheme == "http" && ["127.0.0.1", "localhost"].contains(u.host ?? "")) else { throw URLError(.badURL) }
            struct Login: Decodable { let user: CloudUser; let token: String }
            let data = try checked(await request("login", method: "POST", payload: ["username": username, "password": password, "native": true], endpoint: base, token: ""))
            let response = try JSONDecoder().decode(Login.self, from: data)
            let s = CloudSession(endpoint: base, user: response.user, token: response.token)
            if let previous = session, previous.user.id != s.user.id || previous.endpoint != s.endpoint {
                try folder?.scan()
                if !(folder?.pending.isEmpty ?? true) { throw NSError(domain: "PowvySync", code: 409, userInfo: [NSLocalizedDescriptionKey: "原账号还有未同步笔记，请先登录原账号完成同步"]) }
            }
            try attach(s)
            if ProcessInfo.processInfo.environment["POWVY_DIR"] == nil { try SessionKeychain.save(JSONEncoder().encode(s)) }
            Task { await self.sync() }
        } catch { message = error.localizedDescription }
    }
    func importExisting() async {
        guard let folder, !running else { return }
        do { _ = try folder.importExisting(); unlinked = folder.unlinkedCount; await sync() }
        catch { message = "导入失败，原文件保留：\(error.localizedDescription)" }
    }
    func track(_ note: Note) { guard let folder else { return }; do { try folder.track(note); changed() } catch { message = error.localizedDescription } }
    func changed() {
        guard session != nil else { return }
        message = "已保存到本机 · 等待同步"
        debounce?.invalidate(); debounce = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in Task { @MainActor in await self?.sync() } }
    }
    func sync() async {
        guard let folder, let session, !running, !needsLogin else { return }; running = true; defer { running = false }
        do {
            message = "正在同步…"; try folder.scan(); var conflicts = false
            for snapshot in folder.pending {
                let result = try await request("notes/" + snapshot.id, method: "PUT", payload: ["text": snapshot.text, "deleted": snapshot.deleted, "baseVersion": snapshot.version])
                guard self.session?.user.id == session.user.id else { return }
                struct Result: Decodable { let note: RemoteNote? }
                if result.0 == 409 { let remote = try JSONDecoder().decode(Result.self, from: result.1).note; conflicts = try folder.resolveConflict(snapshot, remote: remote) || conflicts }
                else { let response = try JSONDecoder().decode(Result.self, from: checked(result)); guard let note = response.note else { throw URLError(.badServerResponse) }; try folder.accept(snapshot, remote: note) }
            }
            struct Listing: Decodable { let notes: [RemoteNote] }
            let data = try checked(await request("notes")); let incoming = try JSONDecoder().decode(Listing.self, from: data)
            try folder.merge(incoming.notes); unlinked = folder.unlinkedCount; onChanges?()
            message = conflicts ? "发现冲突，已保留副本" : !folder.pending.isEmpty ? "已保存 · 还有更改待同步" : unlinked > 0 ? "云端已同步 · 本机旧笔记尚未导入" : "已同步 / Up to date"
        } catch { if (error as NSError).code == 401 { needsLogin = true }; message = "本机内容保留 · \(error.localizedDescription)" }
    }
    func logout() async {
        guard !running else { return }
        do { try folder?.scan(); if !(folder?.pending.isEmpty ?? true) { message = "还有待同步修改，请同步后再退出"; return }
            let response = try await request("logout", method: "POST", payload: [:]); if response.0 != 401 { _ = try checked(response) }
            if ProcessInfo.processInfo.environment["POWVY_DIR"] == nil { try SessionKeychain.delete() }
            session = nil; folder = nil; signedIn = false; needsLogin = false; username = ""; unlinked = 0; message = "已退出 · 本机笔记保留"
        } catch { message = error.localizedDescription }
    }
}

struct SyncSettingsView: View {
    @ObservedObject var sync: CloudSync
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var password = ""
    @State private var importConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Powvy Note · 同步 / Sync").font(.headline); Spacer(); Button("完成") { dismiss() } }
            Text(sync.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if sync.signedIn && !sync.needsLogin {
                Text("已登录：\(sync.username)")
                Button("立即同步 / Sync now") { Task { await sync.sync() } }.disabled(sync.running)
                if sync.unlinked > 0 {
                    Text("本机有 \(sync.unlinked) 篇尚未关联的笔记。导入前会在笔记目录建立备份。")
                    Button("备份并同步本机笔记") { importConfirmation = true }.disabled(sync.running)
                }
                Button("退出登录") { Task { await sync.logout() } }.disabled(sync.running)
            } else {
                TextField("同步网址", text: $sync.endpoint)
                TextField("用户名", text: $user)
                SecureField("密码", text: $password)
                Button("登录 / Sign in") { let secret = password; password = ""; Task { await sync.login(endpoint: sync.endpoint, username: user, password: secret) } }.disabled(sync.running || user.isEmpty || password.isEmpty)
                Text("请先在 iPad 或 iPhone 的私人初始化链接创建账号，再登录同一账号。不会要求邮箱或手机号。登录后再选择是否上传本机已有笔记。").font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
        .onAppear { user = sync.username }
        .confirmationDialog("先备份，再上传现有笔记？", isPresented: $importConfirmation) {
            Button("备份并同步") { Task { await sync.importExisting() } }
        } message: { Text("笔记将保存到你的私人云端账号，并可在登录同一账号的 iPad 和 iPhone 查看。") }
    }
}
