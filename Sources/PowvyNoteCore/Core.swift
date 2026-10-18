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

// MARK: - Strikethrough ("done") and bracket tags. Mirrored in windows/md.js.

public let strikePattern = #"~~(?=\S)(.+?)(?<=\S)~~"#
/// `[todo]`, `[homework]`, `[test 10/25]`, `[appointment Fri 3pm]`, `[class Maths 9am]` — not `[test](url)` links.
public let tagPattern = #"\[(todo|homework|test|appointment|class)(?:[:\s]+([^\[\]\n]*?))?\s*\](?!\()"#
public let tagKinds = ["todo", "homework", "test", "appointment", "class"]
/// Tags that carry a date/time/subject, so the caret is left inside the brackets.
public let detailTagKinds: Set<String> = ["test", "appointment", "class"]

public enum Inline: Equatable {
    case text(String)
    case tag(kind: String, detail: String)
}

public func splitTags(_ s: String) -> [Inline] {
    let re = try! NSRegularExpression(pattern: tagPattern, options: .caseInsensitive)
    let ns = s as NSString
    var out: [Inline] = [], pos = 0
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        if m.range.location > pos { out.append(.text(ns.substring(with: NSRange(location: pos, length: m.range.location - pos)))) }
        let detail = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
        out.append(.tag(kind: ns.substring(with: m.range(at: 1)).lowercased(), detail: detail))
        pos = NSMaxRange(m.range)
    }
    if pos < ns.length { out.append(.text(ns.substring(from: pos))) }
    return out
}

/// What the tag picker inserts in place of the typed `[`, and where the caret goes (UTF-16 offset into it).
public func tagInsertion(_ kind: String) -> (text: String, caret: Int) {
    detailTagKinds.contains(kind) ? ("[\(kind) ]", kind.utf16.count + 2) : ("[\(kind)] ", kind.utf16.count + 3)
}

/// Should typing `[` at `location` open the tag picker? Not for task boxes (`- [`).
public func opensTagPicker(in src: String, at location: Int) -> Bool {
    let ns = src as NSString
    let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
    let before = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
    return before.range(of: #"^\s*[-*+]\s*$"#, options: .regularExpression) == nil
}

/// Wrap the selection in `~~` to strike it out, or unwrap it if already struck. Empty selection = the
/// caret's line minus its list/heading marker. Goes line by line (markdown strikes can't span lines).
/// Ranges are UTF-16, i.e. NSTextView / JS string offsets. Returns the new text and selection.
public func toggleStrike(in src: String, range: NSRange) -> (text: String, range: NSRange) {
    let s = NSMutableString(string: src)
    var r = range
    if r.length == 0 {
        var line = s.lineRange(for: r)
        while line.length > 0, "\r\n".contains(s.substring(with: NSRange(location: NSMaxRange(line) - 1, length: 1))) { line.length -= 1 }
        let marker = (s.substring(with: line) as NSString).range(of: #"^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|#{1,6}\s+|>\s?)?"#, options: .regularExpression)
        r = NSRange(location: line.location + marker.length, length: line.length - marker.length)
    }
    // Non-blank piece of each line inside r.
    var segs: [NSRange] = []
    var pos = r.location
    let end = NSMaxRange(r)
    while pos < end {
        let line = s.lineRange(for: NSRange(location: pos, length: 0))
        var a = pos, b = min(NSMaxRange(line), end)
        func ch(_ i: Int) -> String { s.substring(with: NSRange(location: i, length: 1)) }
        while a < b, ch(a).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { a += 1 }
        while b > a, ch(b - 1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { b -= 1 }
        if b > a { segs.append(NSRange(location: a, length: b - a)) }
        if NSMaxRange(line) <= pos { break }
        pos = NSMaxRange(line)
    }
    guard !segs.isEmpty else { return (src, range) }

    func inner(_ g: NSRange) -> Bool { g.length >= 4 && s.substring(with: g).hasPrefix("~~") && s.substring(with: g).hasSuffix("~~") }
    func outer(_ g: NSRange) -> Bool {
        g.location >= 2 && NSMaxRange(g) + 2 <= s.length
            && s.substring(with: NSRange(location: g.location - 2, length: 2)) == "~~"
            && s.substring(with: NSRange(location: NSMaxRange(g), length: 2)) == "~~"
    }
    // Decide everything before editing: 0 = leave, 1 = add ~~, 2 = remove inner ~~, 3 = remove outer ~~.
    let unstrike = inner(segs[0]) || outer(segs[0])
    let ops = segs.map { g in unstrike ? (inner(g) ? 2 : outer(g) ? 3 : 0) : (inner(g) || outer(g) ? 0 : 1) }
    let lastEnd = NSMaxRange(segs[segs.count - 1])
    var shift = 0 // net length change at or before lastEnd, so the new selection still covers every segment
    for (g, op) in zip(segs, ops).reversed() { // back to front keeps earlier offsets valid
        switch op {
        case 1: s.insert("~~", at: NSMaxRange(g)); s.insert("~~", at: g.location); shift += 4
        case 2: s.deleteCharacters(in: NSRange(location: NSMaxRange(g) - 2, length: 2))
                s.deleteCharacters(in: NSRange(location: g.location, length: 2)); shift -= 4
        case 3: s.deleteCharacters(in: NSRange(location: NSMaxRange(g), length: 2))
                s.deleteCharacters(in: NSRange(location: g.location - 2, length: 2))
                shift -= NSMaxRange(g) == lastEnd ? 2 : 4
        default: break
        }
    }
    let start = segs[0].location - (ops[0] == 3 ? 2 : 0)
    return (s as String, NSRange(location: start, length: lastEnd + shift - start))
}

/// Caret sits just before the `]` of a dated tag being filled in (`[test 10/25|]`): Enter/Tab should hop out.
public func skipsTagClose(in src: String, at location: Int) -> Bool {
    let ns = src as NSString
    guard location < ns.length, ns.substring(with: NSRange(location: location, length: 1)) == "]" else { return false }
    let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
    let before = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
    return before.range(of: #"\[(test|appointment|class)\b[^\[\]]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
}
