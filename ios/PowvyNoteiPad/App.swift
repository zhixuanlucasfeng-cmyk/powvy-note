import SwiftUI
import PowvyNoteCore

// Powvy Note for iPad: a wall of sticky notes. Same .md notes, tags, weekly timetable and account sync as the Mac app
// (CloudSync.swift is shared from Sources/PowvyNote).

@main
struct PowvyNoteApp: App {
    @StateObject private var model = Model()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Wall(model: model)
                .onChange(of: phase) { _, p in if p == .active { model.reload(); Task { await model.cloud.sync() } } }
        }
    }
}

@MainActor
final class Model: ObservableObject {
    let store: NoteStore
    let cloud: CloudSync
    @Published var notes: [Note] = []
    @Published var query = ""
    @Published var tagFilter: String?
    @Published var open: Note.ID? // the note in the editor sheet
    @Published var showSync = false

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Notes")
        store = try! NoteStore(dir: dir) // ponytail: the app's own Documents folder; failure here means a broken install
        cloud = CloudSync(store: store)
        reload()
        if notes.isEmpty, let n = try? store.create(text: "# Welcome to Powvy Note\n\n- Tap a sticky note to write\n- [ ] Tag buttons sit above the keyboard: To do, Homework, Test…\n- The calendar button makes a blank timetable every week\n- The cloud button syncs with your Mac\n") {
            notes = [n]
        }
        cloud.onChanges = { [weak self] in self?.reload() }
    }

    var visible: [Note] { notes.filter { noteMatches($0.text, query: query, tag: tagFilter) } }
    func count(_ tag: String?) -> Int { notes.filter { noteMatches($0.text, query: "", tag: tag) }.count }
    func reload() { notes = store.load() }

    func text(_ id: Note.ID) -> String { notes.first { $0.id == id }?.text ?? "" }

    func update(_ id: Note.ID, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        do { try store.save(notes[i]); cloud.changed() } catch { cloud.message = "保存失败：\(error.localizedDescription)" }
    }

    func add(_ text: String) -> Note? {
        guard let n = try? store.create(text: text) else { return nil }
        cloud.track(n)
        notes.insert(n, at: 0)
        return n
    }

    func newNote() {
        query = ""; tagFilter = nil
        open = add("# New note\n\n")?.id
    }

    func delete(_ id: Note.ID) {
        guard let n = notes.first(where: { $0.id == id }) else { return }
        do { try store.delete(n); cloud.changed() } catch { cloud.message = error.localizedDescription; return }
        notes.removeAll { $0.id == id }
        if open == id { open = nil }
    }

    /// Calendar button. No template yet → make one to fill in. Otherwise sync first (the Mac may already have made this
    /// week), then add this week's missing blank day notes and open today's. Manual, like the web app, so two devices
    /// don't both make the same week.
    func openTimetable() async {
        query = ""
        guard notes.contains(where: { isTimetableTemplate($0.text) }) else {
            tagFilter = nil
            open = add(timetableTemplateExample)?.id
            return
        }
        await cloud.sync()
        reload()
        guard let template = notes.first(where: { isTimetableTemplate($0.text) }) else { return }
        let monday = weekStart(Date()), have = Set(notes.map(\.title))
        for text in weekNotes(template: template.text, monday: monday).reversed() where !have.contains(Note(url: template.url, text: text).title) {
            _ = add(text)
        }
        tagFilter = "class"
        let today = (Calendar(identifier: .gregorian).component(.weekday, from: Date()) + 5) % 7 // Monday = 0
        let wanted = dayNoteTitle(weekDays[today], Calendar.current.date(byAdding: .day, value: today, to: monday)!)
        open = notes.first { $0.title == wanted }?.id
    }
}

// MARK: - Colours

enum Paper {
    static let tagColor: [String: Color] = [
        "todo": Color(red: 0.94, green: 0.48, blue: 0.13), "homework": Color(red: 0.36, green: 0.62, blue: 1),
        "test": Color(red: 1, green: 0.36, blue: 0.33), "appointment": Color(red: 0.3, green: 0.8, blue: 0.5),
        "class": Color(red: 0.72, green: 0.55, blue: 1),
    ]
    static let label = ["todo": "To do", "homework": "Homework", "test": "Test", "appointment": "Appointment", "class": "Class"]
    /// Sticky-note paper, by the note's first tag; plain notes are classic yellow.
    static func sheet(_ tags: [String]) -> Color {
        switch tags.first {
        case "class": Color(red: 0.90, green: 0.86, blue: 1.00)
        case "homework": Color(red: 0.84, green: 0.91, blue: 1.00)
        case "test": Color(red: 1.00, green: 0.86, blue: 0.86)
        case "todo": Color(red: 1.00, green: 0.89, blue: 0.78)
        case "appointment": Color(red: 0.84, green: 0.96, blue: 0.87)
        default: Color(red: 1.00, green: 0.95, blue: 0.64)
        }
    }
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.11)
    static let wall = Color(red: 0.16, green: 0.15, blue: 0.14)
}

// MARK: - The wall

struct Wall: View {
    @ObservedObject var model: Model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filters
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 22)], spacing: 22) {
                        ForEach(model.visible) { n in
                            Sticky(note: n).onTapGesture { model.open = n.id }
                                .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { model.delete(n.id) } }
                        }
                    }
                    if model.visible.isEmpty {
                        Text(model.notes.isEmpty ? "No notes yet — tap +" : "No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding(24)
            }
            .background(Paper.wall.ignoresSafeArea())
            .navigationTitle("Powvy Note")
            .searchable(text: $model.query, prompt: "Search notes")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.showSync = true } label: { Image(systemName: model.cloud.signedIn ? "checkmark.icloud" : "icloud") }
                        .accessibilityLabel("Account & sync")
                    Button { Task { await model.openTimetable() } } label: { Image(systemName: "calendar") }
                        .accessibilityLabel("Timetable")
                    Button { model.newNote() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New note").keyboardShortcut("n")
                }
            }
            .refreshable { await model.cloud.sync(); model.reload() }
            .sheet(item: Binding(get: { model.open.map(OpenNote.init) }, set: { model.open = $0?.id })) { o in
                Editor(model: model, id: o.id)
            }
            .sheet(isPresented: $model.showSync) { SyncSettingsView(sync: model.cloud).presentationDetents([.medium, .large]) }
        }
        .preferredColorScheme(.dark)
    }

    var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "All", .white)
                ForEach(tagKinds, id: \.self) { k in
                    if model.count(k) > 0 || model.tagFilter == k { chip(k, Paper.label[k]!, Paper.tagColor[k]!) }
                }
            }
        }
    }

    func chip(_ tag: String?, _ label: String, _ color: Color) -> some View {
        let on = model.tagFilter == tag
        return Button { model.tagFilter = tag } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                Text("\(model.count(tag))").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.white.opacity(0.18) : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

struct OpenNote: Identifiable { let id: Note.ID }

/// One sticky note: paper colour from the first tag, title, the first lines, tag dots. Slight tilt like a real wall.
struct Sticky: View {
    let note: Note

    var body: some View {
        let tags = noteTags(note.text)
        let body = note.text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().prefix(7)
            .map { $0.replacingOccurrences(of: #"^(#+|[-*+]\s+\[[ xX]\]|[-*+>])\s*"#, with: "", options: .regularExpression) }
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title).font(.system(.headline, design: .rounded)).lineLimit(2)
            Text(body.joined(separator: "\n")).font(.system(.subheadline, design: .rounded)).lineLimit(7).opacity(0.75)
            Spacer(minLength: 0)
            HStack(spacing: 5) { ForEach(tags, id: \.self) { Circle().fill(Paper.tagColor[$0]!).frame(width: 9, height: 9) } }
        }
        .foregroundStyle(Paper.ink)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 200, alignment: .topLeading)
        .background(Paper.sheet(tags))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 4)
        .rotationEffect(.degrees(tilt))
        .contentShape(Rectangle())
    }

    /// Stable per note (not random per render), between -1.5° and 1.5°.
    var tilt: Double { Double(note.url.lastPathComponent.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 31 - 15) / 10 }
}

// MARK: - Editor

struct Editor: View {
    @ObservedObject var model: Model
    let id: Note.ID
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Paper.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .background(Paper.sheet(noteTags(text)).ignoresSafeArea())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.sentences)
                .onChange(of: text) { _, t in model.update(id, t) }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) { model.delete(id); dismiss() } label: { Image(systemName: "trash") }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(Note(url: id, text: text).title).font(.headline).foregroundStyle(Paper.ink)
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundStyle(Paper.ink) }
                    ToolbarItemGroup(placement: .keyboard) {
                        ForEach(tagKinds, id: \.self) { k in
                            Button(Paper.label[k]!) { insert(tagInsertion(k).text) }.tint(Paper.tagColor[k]!)
                        }
                        Spacer()
                        Button("☐") { insert("- [ ] ") }
                    }
                }
        }
        .onAppear { text = model.text(id) }
    }

    /// TextEditor has no caret API; append at the end, which is where you're usually writing on a sticky note.
    func insert(_ s: String) { text += (text.hasSuffix("\n") || text.isEmpty ? "" : " ") + s }
}
