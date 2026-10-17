import Foundation
import PowvyNoteCore

func check(_ ok: Bool, _ msg: String) { if !ok { print("FAIL:", msg); exit(1) } }

// Parser
let md = "# Title\n- [ ] todo\n- [x] done\n- item\n> quote\n```\ncode # not heading\n```\n\nplain **bold**"
let blocks = parseMarkdown(md)
check(blocks == [
    .heading(level: 1, text: "Title"),
    .task(done: false, text: "todo", line: 1),
    .task(done: true, text: "done", line: 2),
    .bullet("item"),
    .quote("quote"),
    .code("code # not heading"),
    .blank,
    .text("plain **bold**"),
], "parse: \(blocks)")

// Task toggle round-trip, out-of-range is a no-op
let toggled = toggleTask(in: md, line: 1)
check(toggled.contains("- [x] todo"), "toggle on")
check(toggleTask(in: toggled, line: 1) == md, "toggle off")
check(toggleTask(in: md, line: 99) == md, "toggle out of range")

// Titles
check(Note(url: URL(fileURLWithPath: "/x.md"), text: "## Hello\nbody").title == "Hello", "title")
check(Note(url: URL(fileURLWithPath: "/x.md"), text: "").title == "Untitled", "empty title")

// Store CRUD in a temp dir
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("powvynote-check-\(UUID())")
let store = try NoteStore(dir: dir)
var a = try store.create(text: "# A")
Thread.sleep(forTimeInterval: 1.1) // mtime resolution
let b = try store.create(text: "# B")
check(store.load().map(\.title) == ["B", "A"], "newest first")
a.text = "# A2"; try store.save(a)
check(store.load().first?.title == "A2", "save bumps to top")
try store.delete(b)
check(store.load().map(\.title) == ["A2"], "delete")
try? FileManager.default.removeItem(at: dir)

print("SelfCheck OK")
