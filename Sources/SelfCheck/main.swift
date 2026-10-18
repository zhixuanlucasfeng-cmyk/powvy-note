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


// Strikethrough: wrap, toggle back, selection follows, whitespace trimmed, caret line minus marker, multi-line
func strike(_ t: String, _ loc: Int, _ len: Int) -> (String, NSRange) { let r = toggleStrike(in: t, range: NSRange(location: loc, length: len)); return (r.text, r.range) }
var (st, sr) = strike("buy milk now", 4, 5)          // "milk " -> trailing space trimmed
check(st == "buy ~~milk~~ now" && sr == NSRange(location: 4, length: 8), "strike: \(st) \(sr)")
(st, sr) = strike(st, sr.location, sr.length)          // selection includes the ~~
check(st == "buy milk now" && sr == NSRange(location: 4, length: 4), "unstrike inner: \(st) \(sr)")
(st, sr) = strike("buy ~~milk~~ now", 6, 4)            // selection is just the struck word
check(st == "buy milk now" && sr == NSRange(location: 4, length: 4), "unstrike outer: \(st) \(sr)")
(st, _) = strike("- [ ] call mum\nnext", 8, 0)         // caret only: whole line minus task box
check(st == "- [ ] ~~call mum~~\nnext", "strike line: \(st)")
(st, _) = strike("# Title", 3, 0)
check(st == "# ~~Title~~", "strike heading: \(st)")
(st, sr) = strike("one\n\ntwo", 0, 8)                  // per line, blank lines skipped
check(st == "~~one~~\n\n~~two~~" && sr == NSRange(location: 0, length: 16), "strike lines: \(st) \(sr)")
(st, _) = strike(st, sr.location, sr.length)
check(st == "one\n\ntwo", "unstrike lines: \(st)")
check(strike("   ", 0, 3).0 == "   ", "strike blank is no-op")
check(strike("你好世界", 2, 2).0 == "你好~~世界~~", "strike CJK")

// Tags
check(splitTags("Read ch.4 [homework] and [test 10/25]!") == [
    .text("Read ch.4 "), .tag(kind: "homework", detail: ""), .text(" and "), .tag(kind: "test", detail: "10/25"), .text("!"),
], "tags: \(splitTags("Read ch.4 [homework] and [test 10/25]!"))")
check(splitTags("[Appointment: Fri 3pm] dentist") == [.tag(kind: "appointment", detail: "Fri 3pm"), .text(" dentist")], "tag colon + case")
check(splitTags("[test](https://x.y) [x] [todos]") == [.text("[test](https://x.y) [x] [todos]")], "links/boxes/unknown untouched")
check(splitTags("[test 1/3 - [ ] x]") == [.text("[test 1/3 - [ ] x]")], "no [ inside a tag")
check(tagInsertion("todo") == ("[todo] ", 7) && tagInsertion("test") == ("[test ]", 6), "insertions")
check(opensTagPicker(in: "note ", at: 5) && !opensTagPicker(in: "a\n- ", at: 4) && opensTagPicker(in: "", at: 0), "picker trigger")
check(skipsTagClose(in: "x [test 10/25]", at: 13) && skipsTagClose(in: "[Appointment ]", at: 13), "hop out of dated tag")
check(!skipsTagClose(in: "x [todo]", at: 7) && !skipsTagClose(in: "[test] y]", at: 8) && !skipsTagClose(in: "[test", at: 5), "no hop elsewhere")

print("SelfCheck OK")
