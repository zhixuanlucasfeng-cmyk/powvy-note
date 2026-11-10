# Powvy Note

Hover-to-open markdown notes. On a Mac the panel drops out of the notch; on Windows it drops from a small pill at the top of the screen. Every note is a plain `.md` file.

- Hover the top-centre of the screen to open; move away to close. ✕ or Esc closes, the pin keeps it open.
- Markdown preview with clickable task checkboxes.
- **Strike out** a selection (or the caret's line) to mark it done: the S̶ button or ⇧⌘X / Ctrl+Shift+X. Saved as `~~text~~`.
- **Bracket tags**: type `[` and pick To do / Homework / Test / Appointment / Class (click or press 1–5). Test, Appointment and Class put the caret inside — `[test 10/25]`, `[appointment Fri 3pm]`, `[class Maths 9am]` — and Enter or Tab hops out. Tags are coloured in the editor and shown as chips in the preview.
- Dock + menu bar icon (Mac) / tray (Windows) to reopen, open at login, or quit.
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

## iPad / iPhone + Mac sync (0.4)

The new mobile web app uses a username and password, with no required email or phone. Add it to the Home Screen from Safari. Notes are saved locally while offline and synchronized when the app is open and online; iOS background sync is not guaranteed.

手机端：用私人初始化链接创建账号，保存恢复码，然后在 iPad / iPhone 登录同一账号。**账号尚未创建之前，没有任何本机笔记被上传。**

Mac：安装新版，点击左侧云朵按钮，填写同步网址、用户名和密码。首次导入选择「备份并同步本机笔记」；备份在笔记目录的 `Backups/`。登录后新建的笔记自动同步；未导入的旧笔记仍只在 Mac。删除的本地文件移至 `.trash/`，同步状态在 `.sync/`。会话保存在 Keychain，不保存明文密码。请勿同时运行旧版与新版。

冲突不会静默覆盖：同时编辑会保留「冲突副本」，旧设备的删除不会覆盖另一端的新修改。离线或同步失败时，原稿仍保留在设备。网页账号缓存相互隔离；共享设备退出后应清除网站数据。恢复码或更改密码会使已有登录失效。

### Development / deployment

```sh
npm install
npm run build
npx wrangler d1 execute powvy-note --local --config cloud/wrangler.jsonc --file cloud/schema.sql
# Set a random SETUP_KEY in cloud/.dev.vars (never commit it).
npm run dev
```

`/#setup=<SETUP_KEY>` is a private first-run link. Initialization is limited to one account using a database uniqueness constraint. Never publish this link in a README or repository. For deployment, bind a new D1 database, apply `cloud/schema.sql` remotely and set the `SETUP_KEY` Worker secret before exposing setup. Existing unrelated databases must not be reused.

```sh
npm test
node scripts/check-web.mjs # Local server only; creates a test account.
swift run SelfCheck
swift run SyncCheck
sh make-app.sh
```

API: same-origin HttpOnly browser session; native clients use a Keychain-held bearer session. Passwords use salted PBKDF2-SHA256 (100,000 iterations, Workers runtime limit); passwords should be long and unique. Auth attempts are rate-limited. Recovery codes have 192 bits of randomness and are stored only as hashes. Sessions expire after 30 days. Note writes use optimistic version checks and retain deletion tombstones. Limits: 200KB per note and 1,000 cloud records (including tombstones); export and contact the operator before reaching this limit. This is a personal notes service, not end-to-end encrypted storage.
