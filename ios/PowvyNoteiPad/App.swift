import SwiftUI
import UIKit
import PowvyNoteCore

// Powvy Note for iPad: the same sidebar + editor as the Mac panel (Sources/PowvyNote/Shared.swift), full screen,
// with the same account sync (CloudSync.swift). Only the text view below is iPad-specific.

@main
struct PowvyNoteApp: App {
    @StateObject private var model: Model = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Notes")
        return Model(store: try! NoteStore(dir: dir)) // ponytail: the app's own Documents folder; failing here means a broken install
    }()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ExpandedView(model: model)
                .padding(.top, 8)
                .background(Color.black.ignoresSafeArea())
                .preferredColorScheme(.dark)
                .sheet(isPresented: $model.showSync) { SyncSettingsView(sync: model.cloud) }
                .onChange(of: phase) { _, p in
                    guard p == .active else { return }
                    model.notes = model.store.load() // edits from the Files app
                    model.ensureWeekIfReady(afterSync: false)
                    Task { await model.cloud.sync() }
                }
        }
    }
}

/// UITextView version of the Mac NoteEditor: plain text, ~~struck~~ text and tags styled live, `[` opens the tag picker.
struct NoteEditor: UIViewRepresentable {
    @ObservedObject var model: Model

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.textStorage.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.tintColor = .white
        tv.typingAttributes = Coordinator.base
        tv.autocorrectionType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        model.editor = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        model.editor = tv
        let text = model.current?.text ?? ""
        if tv.text != text { // switched notes or synced from elsewhere
            tv.text = text // restyled by the text storage delegate
            tv.undoManager?.removeAllActions()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate {
        let model: Model
        var pendingAnchor: Int?
        init(model: Model) { self.model = model }

        static let size: CGFloat = 16
        static let base: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: UIColor.white]
        static let tagFont = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        static let strikeRE = try! NSRegularExpression(pattern: strikePattern)
        static let tagRE = try! NSRegularExpression(pattern: tagPattern, options: .caseInsensitive)
        static let tagColors = Tag.color.mapValues { UIColor($0) }

        /// Strikes and tags never span lines, so only the edited paragraph(s) are restyled.
        func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorage.EditActions, range: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters) else { return }
            let para = (ts.string as NSString).paragraphRange(for: range)
            ts.setAttributes(Coordinator.base, range: para)
            for m in Coordinator.strikeRE.matches(in: ts.string, range: para) {
                ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: UIColor.secondaryLabel], range: m.range)
            }
            for m in Coordinator.tagRE.matches(in: ts.string, range: para) {
                let kind = (ts.string as NSString).substring(with: m.range(at: 1)).lowercased()
                ts.addAttributes([.foregroundColor: Coordinator.tagColors[kind] ?? .white, .font: Coordinator.tagFont], range: m.range)
            }
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText s: String) -> Bool {
            MainActor.assumeIsolated {
                if model.tagAnchor != nil, s.count == 1, let n = Int(s), (1...tagKinds.count).contains(n) {
                    model.insertTag(tagKinds[n - 1])
                    return false
                }
                if s == "\n" || s == "\t", range.length == 0, skipsTagClose(in: tv.text, at: range.location) {
                    tv.selectedRange = NSRange(location: range.location + 1, length: 0) // hop out of `[test 10/25|]`
                    if s == "\n" { DispatchQueue.main.async { tv.insertText("\n") } }
                    return false
                }
                pendingAnchor = s == "[" && range.length == 0 && opensTagPicker(in: tv.text, at: range.location) ? range.location + 1 : nil
                return true
            }
        }

        func textViewDidChange(_ tv: UITextView) {
            MainActor.assumeIsolated {
                model.tagAnchor = pendingAnchor // any edit other than a fresh `[` closes the picker
                pendingAnchor = nil
                model.update(tv.text)
                tv.typingAttributes = Coordinator.base // don't inherit strike/tag styling from the previous char
            }
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            MainActor.assumeIsolated {
                if let a = model.tagAnchor, tv.selectedRange != NSRange(location: a, length: 0) { model.tagAnchor = nil }
            }
        }
    }
}
