import SwiftUI
import PowvyNoteCore
#if os(macOS)
import AppKit
typealias PlatformTextView = NSTextView
#else
import UIKit
typealias PlatformTextView = UITextView
#endif

// Model and views shared by the Mac panel (main.swift) and the iPad app (ios/). Only the text view (NoteEditor),
// the window around it and these few helpers differ per platform.

#if os(macOS)
extension NSTextView {
    var plainText: String { string }
    /// Undoable replace that tells the delegate, like typing does.
    func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }
    func focus() { window?.makeFirstResponder(self) }
}
#else
extension UITextView {
    var plainText: String { text }
    /// Goes through UITextInput, so it is undoable and calls textViewDidChange like typing does.
    func replace(_ range: NSRange, with text: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length), let r = textRange(from: start, to: end) else { return }
        replace(r, withText: text)
    }
    func focus() { becomeFirstResponder() }
}
#endif

extension Model {
    #if os(macOS)
    static let welcome = "# Welcome to Powvy Note\n\n- [ ] Hover the notch to open\n- [ ] Click a note to type\n- [x] Markdown preview with the eye button\n- [ ] Menu bar icon reopens it any time\n"
    #else
    static let welcome = "# Welcome to Powvy Note\n\n- [ ] Tap a note on the left to type\n- [ ] Type [ for tags: To do, Homework, Test…\n- [x] Markdown preview with the eye button\n- [ ] The cloud button syncs with your Mac\n"
    #endif
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    let store: NoteStore
    let cloud: CloudSync
    @Published var showSync = false
    @Published var notes: [Note] = []
    @Published var selected: URL?
    @Published var expanded = false { didSet { if expanded != oldValue { onExpand?(expanded) } } }
    @Published var pinned = false
    @Published var preview = false
    @Published var query = ""
    @Published var tagFilter: String? // sidebar filter: nil = All
    @Published var tagAnchor: Int? // caret offset just after a freshly typed `[` while the tag picker is up
    weak var editor: PlatformTextView?
    var onExpand: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var notchSize = CGSize(width: 200, height: 32)
    static let openSize = CGSize(width: 680, height: 420)

    init(store: NoteStore) {
        self.store = store
        self.cloud = CloudSync(store: store)
        notes = store.load()
        if notes.isEmpty, let n = try? store.create(text: Self.welcome) { notes = [n] }
        ensureWeekIfReady(afterSync: false)
        selected = notes.first?.url
        cloud.onChanges = { [weak self] in
            guard let self else { return }
            self.notes = self.store.load()
            self.ensureWeekIfReady(afterSync: true)
            if !self.notes.contains(where: { $0.url == self.selected }) { self.selected = self.notes.first?.url }
        }
    }

    var current: Note? { notes.first { $0.url == selected } }
    var visible: [Note] { notes.filter { noteMatches($0.text, query: query, tag: tagFilter) } }
    func count(_ tag: String?) -> Int { notes.filter { noteMatches($0.text, query: "", tag: tag) }.count }

    func update(_ text: String) {
        guard let i = notes.firstIndex(where: { $0.url == selected }) else { return }
        notes[i].text = text
        do { try store.save(notes[i]); cloud.changed() }
        catch { cloud.message = "本机保存失败：\(error.localizedDescription)" }
    }

    func newNote() {
        guard let n = try? store.create() else { return }
        cloud.track(n)
        notes.insert(n, at: 0)
        query = ""; tagFilter = nil // so the new note is in the list
        selected = n.url
        preview = false
    }

    /// Makes this week's blank day notes from the "Timetable template" note, unless they already exist.
    /// Runs on launch and every time the panel opens; past weeks are left alone.
    func ensureWeek() {
        guard let template = notes.first(where: { isTimetableTemplate($0.text) }) else { return }
        let have = Set(notes.map(\.title))
        for text in weekNotes(template: template.text, monday: weekStart(Date())).reversed()
        where !have.contains(Note(url: template.url, text: text).title) {
            guard let n = try? store.create(text: text) else { return }
            cloud.track(n)
            notes.insert(n, at: 0)
        }
    }

    /// Signed in to sync: only right after a sync has merged, so a week another device already made arrives first
    /// instead of being made twice. Not signed in: straight away (launch, and each time the panel opens).
    /// ponytail: two devices that are both offline on a Monday can still each make the week; delete the copy.
    func ensureWeekIfReady(afterSync: Bool) { if cloud.signedIn == afterSync { ensureWeek() } }

    /// Calendar button: no template yet → make one to fill in; otherwise jump to today's timetable note.
    func openTimetable() {
        query = ""; preview = false
        guard notes.contains(where: { isTimetableTemplate($0.text) }) else {
            guard let n = try? store.create(text: timetableTemplateExample) else { return }
            cloud.track(n)
            notes.insert(n, at: 0)
            tagFilter = nil; selected = n.url
            return
        }
        ensureWeek()
        tagFilter = "class"
        let monday = weekStart(Date())
        let today = (Calendar(identifier: .gregorian).component(.weekday, from: Date()) + 5) % 7 // Monday = 0
        let wanted = [dayNoteTitle(weekDays[today], Calendar.current.date(byAdding: .day, value: today, to: monday)!), dayNoteTitle("Monday", monday)]
        selected = (notes.first { $0.title == wanted[0] } ?? notes.first { $0.title == wanted[1] } ?? notes.first { noteTags($0.text).contains("class") })?.url
    }

    /// Strike out (or restore) the selection, or the caret's line. Undoable.
    func strike() {
        guard let tv = editor, !preview else { return }
        let r = toggleStrike(in: tv.plainText, range: tv.selectedRange)
        tv.replace(NSRange(location: 0, length: (tv.plainText as NSString).length), with: r.text)
        tv.selectedRange = r.range
    }

    /// Replace the typed `[` with a tag; caret lands inside the brackets for dated tags.
    func insertTag(_ kind: String) {
        guard let tv = editor, let anchor = tagAnchor else { return }
        let ins = tagInsertion(kind)
        tagAnchor = nil
        tv.replace(NSRange(location: anchor - 1, length: 1), with: ins.text)
        tv.selectedRange = NSRange(location: anchor - 1 + ins.caret, length: 0)
        tv.focus()
    }

    func deleteCurrent() {
        guard let n = current else { return }
        do { try store.delete(n) } catch { cloud.message = error.localizedDescription; return }
        cloud.changed()
        notes.removeAll { $0.url == n.url }
        selected = notes.first?.url
    }
}

// MARK: - Views

struct ExpandedView: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 210)
                .background(Color.white.opacity(0.04))

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(model.current?.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    HStack(spacing: 2) {
                        IconButton("strikethrough", help: "Strike out the selection or line — mark it done (⇧⌘X)") { model.strike() }
                            .disabled(model.preview).opacity(model.preview ? 0.3 : 1)
                        IconButton(model.preview ? "pencil" : "eye", help: "Toggle preview") { model.preview.toggle() }
                        #if os(macOS)
                        IconButton(model.pinned ? "pin.fill" : "pin", help: "Keep open") { model.pinned.toggle() }
                        #endif
                        IconButton("trash", help: "Delete note") { model.deleteCurrent() }
                    }
                    .padding(2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    #if os(macOS)
                    IconButton("xmark", help: "Close (Esc) — quit from the menu bar icon") { model.onClose?() }
                    #endif
                }
                .padding(.horizontal, 14).padding(.vertical, 8)

                if model.current == nil {
                    Spacer(); Text("No notes — create one on the left").foregroundStyle(.secondary); Spacer()
                } else if model.preview {
                    MarkdownView(text: model.current?.text ?? "") { line in
                        model.update(toggleTask(in: model.current?.text ?? "", line: line))
                    }
                } else {
                    NoteEditor(model: model)
                        .padding(.horizontal, 8)
                        .overlay(alignment: .bottom) { if model.tagAnchor != nil { TagPicker(model: model) } }
                }
            }
        }
        .padding(.bottom, 8)
    }
}

/// Search, tag filters with counts, then the (filtered) note list.
struct Sidebar: View {
    @ObservedObject var model: Model
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text("Powvy Note").font(.system(size: 13, weight: .bold))
                Spacer()
                IconButton("icloud", help: "账号与同步 / Account & sync") { model.showSync = true }
                IconButton("calendar", help: "Timetable — a blank one every week; old weeks stay under Class") { model.openTimetable() }
                IconButton("square.and.pencil", help: "New note (⌘N)") { model.newNote() }
                    .keyboardShortcut("n")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search  ⌘F", text: $model.query).textFieldStyle(.plain).focused($searching)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
            .background(Button("") { searching = true }.keyboardShortcut("f").hidden())

            VStack(spacing: 1) {
                filter(nil, "All", .white)
                ForEach(tagKinds, id: \.self) { k in
                    if model.count(k) > 0 || model.tagFilter == k { filter(k, Tag.label[k]!, Tag.color[k]!) }
                }
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.visible) { n in row(n) }
                    if model.visible.isEmpty {
                        Text("No matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(6)
                    }
                }
            }
        }
        .padding(10)
    }

    func filter(_ tag: String?, _ label: String, _ color: Color) -> some View {
        let on = model.tagFilter == tag
        return Button { model.tagFilter = tag } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7).opacity(tag == nil ? 0.6 : 1)
                Text(label)
                Spacer()
                Text("\(model.count(tag))").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.white.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func row(_ n: Note) -> some View {
        let on = n.url == model.selected
        let line = snippet(n.text)
        return Button { model.selected = n.url } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(n.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    ForEach(noteTags(n.text), id: \.self) { Circle().fill(Tag.color[$0]!).frame(width: 6, height: 6) }
                }
                Text(line.isEmpty ? "Empty note" : line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let icon: String, help: String, action: () -> Void
    init(_ icon: String, help: String, action: @escaping () -> Void) { self.icon = icon; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: icon).frame(width: 24, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help)
    }
}

struct MarkdownView: View {
    let text: String
    let onToggle: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(parseMarkdown(text).enumerated()), id: \.offset) { _, block in row(block) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .textSelection(.enabled)
        }
    }

    func inline(_ s: String) -> Text {
        var out = AttributedString()
        for part in splitTags(s) {
            switch part {
            case let .text(t):
                // markdown parsing drops edge spaces, which separate text from chips — put them back
                if t.first == " " { out += AttributedString(" ") }
                out += (try? AttributedString(markdown: t)) ?? AttributedString(t) // handles ~~strike~~ too
                if t.count > 1, t.last == " " { out += AttributedString(" ") }
            case let .tag(kind, detail):
                var chip = AttributedString("\u{2009}\(Tag.label[kind] ?? kind)\(detail.isEmpty ? "" : " · " + detail)\u{2009}")
                chip.foregroundColor = .black
                chip.backgroundColor = Tag.color[kind]
                chip.font = .system(size: 12, weight: .semibold)
                out += chip
            }
        }
        return Text(out)
    }

    @ViewBuilder func row(_ b: MDBlock) -> some View {
        switch b {
        case let .heading(level, t):
            inline(t).font(.system(size: [22, 18, 16, 14, 13, 12][level - 1], weight: .bold)).padding(.top, 4)
        case let .bullet(t):
            HStack(alignment: .firstTextBaseline) { Text("•"); inline(t) }
        case let .task(done, t, line):
            HStack(alignment: .firstTextBaseline) {
                Button { onToggle(line) } label: { Image(systemName: done ? "checkmark.square.fill" : "square") }
                    .buttonStyle(.plain)
                inline(t).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
            }
        case let .quote(t):
            inline(t).italic().foregroundStyle(.secondary)
                .padding(.leading, 8).overlay(Rectangle().frame(width: 3).foregroundStyle(.gray), alignment: .leading)
        case let .code(t):
            Text(t).font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.08))
        case let .text(t):
            inline(t)
        case .blank:
            Spacer().frame(height: 4)
        }
    }
}

enum Tag {
    static let label = ["todo": "To do", "homework": "Homework", "test": "Test", "appointment": "Appointment", "class": "Class"]
    static let color: [String: Color] = [
        "todo": Color(red: 0.94, green: 0.48, blue: 0.13), "homework": Color(red: 0.36, green: 0.62, blue: 1),
        "test": Color(red: 1, green: 0.36, blue: 0.33), "appointment": Color(red: 0.3, green: 0.8, blue: 0.5),
        "class": Color(red: 0.72, green: 0.55, blue: 1),
    ]
}

/// Appears after typing `[`: click a tag or press 1–5; Esc or any other key dismisses it.
struct TagPicker: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(tagKinds.enumerated()), id: \.offset) { i, kind in
                Button { model.insertTag(kind) } label: {
                    Text("\(i + 1) \(Tag.label[kind]!)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Tag.color[kind]!))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.15)))
        .padding(.bottom, 4)
    }
}

