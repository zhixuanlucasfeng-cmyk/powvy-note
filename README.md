# Powvy Note

Hover-to-open markdown notes. On a Mac the panel drops out of the notch; on Windows it drops from a small pill at the top of the screen. Every note is a plain `.md` file.

- Hover the top-centre of the screen to open; move away to close. ✕ or Esc closes, the pin keeps it open.
- Markdown preview with clickable task checkboxes.
- **Strike out** a selection (or the caret's line) to mark it done: the S̶ button or ⇧⌘X / Ctrl+Shift+X. Saved as `~~text~~`.
- **Bracket tags**: type `[` and pick To do / Homework / Test / Appointment (click or press 1–4). Dated tags put the caret inside — `[test 10/25]`, `[appointment Fri 3pm]` — and Enter or Tab hops out. Tags are coloured in the editor and shown as chips in the preview.
- Menu bar (Mac) / tray (Windows) icon to reopen, open at login, or quit.
- Notes live in `~/Library/Application Support/Powvy Note/` (Mac) or `%APPDATA%\Powvy Note\` (Windows).

## Build

**macOS 14+** (Swift, AppKit):

```sh
swift run SelfCheck   # tests
sh make-app.sh        # → build/Powvy Note.app + build/PowvyNote.zip (universal, ad-hoc signed)
```

**Windows 10/11** (Electron, cross-builds from a Mac without Wine):

```sh
cd windows
npm install
npm start             # run locally
npm run dist          # tests + dist/PowvyNote-Setup-<version>.exe
```

Neither build is notarized or code-signed, so the first launch shows a Gatekeeper / SmartScreen warning. See `安装说明.txt` and `windows/安装说明-Windows.txt` for the steps.

## License

MIT
