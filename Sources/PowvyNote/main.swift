import AppKit
import ServiceManagement
import SwiftUI
import PowvyNoteCore

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    let store: NoteStore
    @Published var notes: [Note] = []
    @Published var selected: URL?
    @Published var expanded = false { didSet { if expanded != oldValue { onExpand?(expanded) } } }
    @Published var pinned = false
    @Published var preview = false
    var onExpand: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var notchHeight: CGFloat = 32

    init(store: NoteStore) {
        self.store = store
        notes = store.load()
        if notes.isEmpty, let n = try? store.create(text: "# Welcome to Powvy Note\n\n- [ ] Hover the notch to open\n- [ ] Click a note to type\n- [x] Markdown preview with the eye button\n- [ ] Menu bar icon reopens it any time\n") {
            notes = [n]
        }
        selected = notes.first?.url
    }

    var current: Note? { notes.first { $0.url == selected } }

    var text: Binding<String> {
        Binding(
            get: { self.current?.text ?? "" },
            set: { self.update($0) }
        )
    }

    func update(_ text: String) {
        guard let i = notes.firstIndex(where: { $0.url == selected }) else { return }
        notes[i].text = text
        try? store.save(notes[i]) // ponytail: write per keystroke; debounce if notes get huge
    }

    func newNote() {
        guard let n = try? store.create() else { return }
        notes.insert(n, at: 0)
        selected = n.url
        preview = false
    }

    func deleteCurrent() {
        guard let n = current else { return }
        try? store.delete(n)
        notes.removeAll { $0.url == n.url }
        selected = notes.first?.url
    }
}

// MARK: - Views

struct RootView: View {
    @ObservedObject var model: Model

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: model.expanded ? 18 : 10,
                                   bottomTrailingRadius: model.expanded ? 18 : 10)
                .fill(.black)
            if model.expanded {
                ExpandedView(model: model)
                    .padding(.top, model.notchHeight)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.expanded)
        .preferredColorScheme(.dark)
    }
}

struct ExpandedView: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Powvy Note").font(.headline)
                    Spacer()
                    IconButton("plus", help: "New note (⌘N)") { model.newNote() }
                        .keyboardShortcut("n")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.notes) { n in
                            Button { model.selected = n.url } label: {
                                Text(n.title).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(n.url == model.selected ? Color.white.opacity(0.15) : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: 150)
            .padding(10)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(model.current?.title ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    IconButton(model.preview ? "pencil" : "eye", help: "Toggle preview") { model.preview.toggle() }
                    IconButton(model.pinned ? "pin.fill" : "pin", help: "Keep open") { model.pinned.toggle() }
                    IconButton("trash", help: "Delete note") { model.deleteCurrent() }
                    IconButton("xmark", help: "Close (Esc) — quit from the menu bar icon") { model.onClose?() }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                if model.current == nil {
                    Spacer(); Text("No notes — press +").foregroundStyle(.secondary); Spacer()
                } else if model.preview {
                    MarkdownView(text: model.current?.text ?? "") { line in
                        model.update(toggleTask(in: model.current?.text ?? "", line: line))
                    }
                } else {
                    TextEditor(text: model.text)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 8)
    }
}

struct IconButton: View {
    let icon: String, help: String, action: () -> Void
    init(_ icon: String, help: String, action: @escaping () -> Void) { self.icon = icon; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.plain).help(help)
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
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
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

// MARK: - Window

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true } // clicks in the editor take keystrokes; nonactivating keeps the front app active
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel!
    var model: Model!
    var lastInside = Date()

    func applicationDidFinishLaunching(_ note: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Powvy Note")
        guard let store = try? NoteStore(dir: dir) else { fatalError("cannot create \(dir.path)") }
        model = Model(store: store)

        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        // .transient: hidden during Mission Control (four-finger swipe up) instead of covering it
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: RootView(model: model))

        model.notchHeight = notchSize().height
        model.onExpand = { [weak self] _ in self?.layout(animate: true) }
        model.onClose = { [weak self] in self?.collapseIfIdle(force: true) }
        layout(animate: false)
        panel.orderFrontRegardless()

        // Poll the cursor: tracking areas are unreliable on a non-key, nonactivating panel.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseIfIdle(force: false) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.collapseIfIdle(force: true); return nil } // Esc
            return e
        }
        setUpStatusItem()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animate: false) }
        }
    }

    // MARK: Menu bar item — the way back in after closing, and the only Quit.

    var statusItem: NSStatusItem!
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Powvy Note")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Open Powvy Note", action: #selector(openPanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Powvy Note", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Expand and take focus so it stays open until the user clicks elsewhere or presses Esc.
    @objc func openPanel() {
        model.expanded = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("Powvy Note login item: \(error)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Double-clicking the app (Finder, Spotlight, Launchpad) while it's running opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return false
    }

    // screens[0] is the menu-bar display; NSScreen.main follows focus and would make the panel hop between monitors.
    var screen: NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens[0] }

    /// Real notch on notched Macs; otherwise a pill the height of the menu bar.
    func notchSize() -> CGSize {
        let s = screen
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 {
            return CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        }
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        return CGSize(width: 200, height: menuBar > 0 ? menuBar : 24)
    }

    func layout(animate: Bool) {
        let notch = notchSize()
        let size = model.expanded ? CGSize(width: 600, height: 400) : notch
        let f = screen.frame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        // animator() is async and retargetable; setFrame(animate:) blocks and can stall mid-way
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animate ? 0.18 : 0
            panel.animator().setFrame(frame, display: true)
        }
    }

    func tick() {
        let inside = NSMouseInRect(NSEvent.mouseLocation, panel.frame.insetBy(dx: -2, dy: -2), false)
        if inside {
            lastInside = Date()
            if !model.expanded { model.expanded = true }
        } else if Date().timeIntervalSince(lastInside) > 0.5 && !panel.isKeyWindow {
            collapseIfIdle(force: false)
        }
    }

    /// Typing (key panel) or pinned keeps it open; Esc forces it shut.
    func collapseIfIdle(force: Bool) {
        guard model.expanded else { return }
        if !force && (model.pinned || NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)) { return }
        model.expanded = false
        if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() } // hand keystrokes back
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}
