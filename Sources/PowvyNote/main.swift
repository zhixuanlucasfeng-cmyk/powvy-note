import AppKit
import ServiceManagement
import SwiftUI
import PowvyNoteCore

// MARK: - Views

struct RootView: View {
    @ObservedObject var model: Model

    // The window never resizes: only this black shape grows out of the notch. Resizing an NSWindow every
    // frame re-lays out the whole SwiftUI tree, which is what made opening stutter.
    var body: some View {
        let open = model.expanded
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: open ? 18 : 10, bottomTrailingRadius: open ? 18 : 10)
        ZStack(alignment: .top) {
            shape.fill(Color.black) // opaque: windows behind made the text hard to read
            if open {
                ExpandedView(model: model)
                    .padding(.top, model.notchSize.height)
                    .frame(width: Model.openSize.width, height: Model.openSize.height) // fixed: no reflow while growing
                    .transition(.opacity.animation(.easeOut(duration: 0.12).delay(open ? 0.06 : 0)))
            }
        }
        .frame(width: open ? Model.openSize.width : model.notchSize.width,
               height: open ? Model.openSize.height : model.notchSize.height, alignment: .top)
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: open)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showSync) { SyncSettingsView(sync: model.cloud) }
    }
}

/// Plain-text NSTextView (TextEditor can't report the selection) that shows ~~struck~~ text and tags live.
struct NoteEditor: NSViewRepresentable {
    @ObservedObject var model: Model

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.insertionPointColor = .white
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.typingAttributes = Coordinator.base
        tv.textStorage?.delegate = context.coordinator
        model.editor = tv
        DispatchQueue.main.async { // opened from the menu bar: panel is already key, so put the caret in straight away
            if let w = tv.window, w.isKeyWindow, !(w.firstResponder is NSTextView) { w.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        model.editor = tv
        let text = model.current?.text ?? ""
        if tv.string != text { // switched notes or edited elsewhere
            tv.string = text // restyled by the text storage delegate
            tv.undoManager?.removeAllActions()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let model: Model
        var pendingAnchor: Int?
        init(model: Model) { self.model = model }

        static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        static let strikeRE = try! NSRegularExpression(pattern: strikePattern)
        static let tagRE = try! NSRegularExpression(pattern: tagPattern, options: .caseInsensitive)

        static let tagFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        static let tagColors = Tag.color.mapValues { NSColor($0) }

        /// Strikes and tags never span lines, so only the edited paragraph(s) need restyling — typing stays
        /// O(line) instead of re-laying out the whole note on every keystroke.
        func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters) else { return }
            let para = (ts.string as NSString).paragraphRange(for: range)
            ts.setAttributes(Coordinator.base, range: para)
            for m in Coordinator.strikeRE.matches(in: ts.string, range: para) {
                ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
            }
            for m in Coordinator.tagRE.matches(in: ts.string, range: para) {
                let kind = (ts.string as NSString).substring(with: m.range(at: 1)).lowercased()
                ts.addAttributes([.foregroundColor: Coordinator.tagColors[kind] ?? .white, .font: Coordinator.tagFont], range: m.range)
            }
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString s: String?) -> Bool {
            MainActor.assumeIsolated {
                if model.tagAnchor != nil, let s, s.count == 1, let n = Int(s), (1...tagKinds.count).contains(n) {
                    model.insertTag(tagKinds[n - 1])
                    return false
                }
                if s == "\n" || s == "\t", range.length == 0, skipsTagClose(in: tv.string, at: range.location) {
                    let after = NSRange(location: range.location + 1, length: 0)
                    tv.setSelectedRange(after)
                    if s == "\n" { DispatchQueue.main.async { tv.insertText("\n", replacementRange: after) } }
                    return false
                }
                pendingAnchor = s == "[" && range.length == 0 && opensTagPicker(in: tv.string, at: range.location) ? range.location + 1 : nil
                return true
            }
        }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            MainActor.assumeIsolated {
                model.tagAnchor = pendingAnchor // any edit other than a fresh `[` closes the picker
                pendingAnchor = nil
                model.update(tv.string)
                tv.typingAttributes = Coordinator.base // don't inherit strike/tag styling from the previous char
            }
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            MainActor.assumeIsolated {
                if let a = model.tagAnchor, tv.selectedRange() != NSRange(location: a, length: 0) { model.tagAnchor = nil }
            }
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
        let dir = ProcessInfo.processInfo.environment["POWVY_DIR"].map { URL(fileURLWithPath: $0) } // dev/testing
            ?? support.appendingPathComponent("Powvy Note")
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

        model.notchSize = notchSize()
        model.onExpand = { [weak self] open in
            self?.panel.ignoresMouseEvents = !open
            if open { self?.model.ensureWeek() } // a new week starts with blank day notes
        } // collapsed: clicks pass through to the menu bar
        model.onClose = { [weak self] in self?.collapseIfIdle(force: true) }
        layout()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        // Poll the cursor: tracking areas are unreliable on a non-key, nonactivating panel.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseIfIdle(force: false) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // ⇧⌘X strikes. Matched here by exact modifiers: a SwiftUI .keyboardShortcut also fired on plain ⌘X (Cut).
            if e.keyCode == 7, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] {
                self?.model.strike(); return nil
            }
            if e.keyCode == 53 { // Esc: close the tag picker first, then the panel
                if self?.model.tagAnchor != nil { self?.model.tagAnchor = nil } else { self?.collapseIfIdle(force: true) }
                return nil
            }
            return e
        }
        setUpStatusItem()
        setUpEditMenu()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    // MARK: Menu bar item — the way back in after closing, and the only Quit.

    var statusItem: NSStatusItem!
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarLogo()
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Open Powvy Note", action: #selector(openPanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Powvy Note", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Accessory apps show no menu bar, but key equivalents still route through NSApp.mainMenu —
    /// without these items ⌘V/⌘C/⌘X/⌘A/⌘Z do nothing in the editor.
    func setUpEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "Powvy Note") // first item is the app menu
        let editItem = NSMenuItem(); editItem.submenu = edit
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Single-color menu bar logo (the app icon's note hanging from the notch, as a silhouette).
    /// Template image, so macOS tints it white/black like Ollama, ChatGPT, WeChat etc.
    static func menuBarLogo() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 14), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            // notch bite at the top + two text lines
            NSBezierPath(roundedRect: NSRect(x: 6, y: 12.5, width: 6, height: 5), xRadius: 1.8, yRadius: 1.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 8, width: 8, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 4.5, width: 5, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Powvy Note"
        return img
    }

    /// Expand and take focus so it stays open until the user clicks elsewhere or presses Esc.
    @objc func openPanel() {
        model.expanded = true
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [self] in // editor exists once SwiftUI has rendered the open panel
            if let tv = model.editor { panel.makeFirstResponder(tv) } // type/paste straight away
        }
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

    /// The window is always the open size; what's visible is decided by SwiftUI.
    func layout() {
        model.notchSize = notchSize()
        let size = CGSize(width: max(Model.openSize.width, model.notchSize.width), height: Model.openSize.height)
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// The part of the screen that's actually showing: the notch pill, or the open panel.
    var visibleRect: NSRect {
        let size = model.expanded ? Model.openSize : model.notchSize
        let f = screen.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    func tick() {
        let inside = NSMouseInRect(NSEvent.mouseLocation, visibleRect.insetBy(dx: -2, dy: -2), false)
        if inside {
            lastInside = Date()
            if !model.expanded { model.expanded = true }
        } else if Date().timeIntervalSince(lastInside) > 0.5 && !panel.isKeyWindow {
            collapseIfIdle(force: false)
        }
    }

    /// Typing (key panel) or pinned keeps it open; Esc forces it shut.
    func collapseIfIdle(force: Bool) {
        guard model.expanded, !model.showSync else { return }
        if !force && (model.pinned || NSMouseInRect(NSEvent.mouseLocation, visibleRect, false)) { return }
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
    app.setActivationPolicy(.regular) // Dock icon; clicking it opens the panel (applicationShouldHandleReopen)
    app.run()
}
