import Foundation

public struct Note: Identifiable, Equatable {
    public let url: URL
    public var text: String
    public var id: URL { url }

    public init(url: URL, text: String) { self.url = url; self.text = text }

    public var title: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        return t.isEmpty ? "Untitled" : t
    }
}

/// One `.md` file per note in `dir`.
public final class NoteStore {
    public let dir: URL
    private let fm = FileManager.default

    public init(dir: URL) throws {
        self.dir = dir
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Newest-modified first.
    public func load() -> [Note] {
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return urls.filter { $0.pathExtension == "md" }
            .sorted { mtime($0) > mtime($1) }
            .map { Note(url: $0, text: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
    }

    public func create(text: String = "# New note\n\n") throws -> Note {
        let url = dir.appendingPathComponent("note-\(UUID().uuidString.prefix(8)).md")
        let note = Note(url: url, text: text)
        try save(note)
        return note
    }

    public func save(_ note: Note) throws {
        try note.text.write(to: note.url, atomically: true, encoding: .utf8)
    }

    public func delete(_ note: Note) throws {
        try fm.removeItem(at: note.url)
    }
}

public enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(String)
    case task(done: Bool, text: String, line: Int)
    case quote(String)
    case code(String)
    case text(String)
    case blank
}

/// Line-based block parser; inline styling is left to AttributedString(markdown:).
public func parseMarkdown(_ src: String) -> [MDBlock] {
    var out: [MDBlock] = []
    var inCode = false
    for (i, raw) in src.components(separatedBy: "\n").enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") { inCode.toggle(); continue }
        if inCode { out.append(.code(raw)); continue }
        if line.isEmpty { out.append(.blank); continue }
        if let m = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
            out.append(.heading(level: m.1.count, text: String(m.2)))
        } else if let m = line.firstMatch(of: #/^[-*]\s+\[([ xX])\]\s*(.*)$/#) {
            out.append(.task(done: m.1 != " ", text: String(m.2), line: i))
        } else if let m = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
            out.append(.bullet(String(m.1)))
        } else if let m = line.firstMatch(of: #/^>\s?(.*)$/#) {
            out.append(.quote(String(m.1)))
        } else {
            out.append(.text(line))
        }
    }
    return out
}

/// Flip `[ ]` <-> `[x]` on the given line; anything else is returned unchanged.
public func toggleTask(in src: String, line: Int) -> String {
    var lines = src.components(separatedBy: "\n")
    guard lines.indices.contains(line) else { return src }
    let l = lines[line]
    if let r = l.range(of: "[ ]") {
        lines[line] = l.replacingCharacters(in: r, with: "[x]")
    } else if let r = l.range(of: "[x]") ?? l.range(of: "[X]") {
        lines[line] = l.replacingCharacters(in: r, with: "[ ]")
    }
    return lines.joined(separator: "\n")
}
