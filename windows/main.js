// Windows port of Sources/PowvyNote/main.swift: a black pill at the top-centre of the
// primary screen that expands on hover, plus a tray icon (the way back in, and the only Quit).
const { app, BrowserWindow, Tray, Menu, ipcMain, screen, shell, nativeImage } = require('electron')
const path = require('path')
const { NoteStore } = require('./core')

const dir = process.env.POWVY_DIR || path.join(app.getPath('appData'), 'Powvy Note') // %APPDATA%\Powvy Note
app.setPath('userData', path.join(dir, '.electron')) // keep Chromium's cache out of the notes folder

if (!app.requestSingleInstanceLock()) app.exit() // hands off to the running copy via 'second-instance'

const PILL = { width: 200, height: 24 }
const OPEN = { width: 600, height: 400 }
let win, tray, store
let expanded = false, pinned = false, lastInside = Date.now()

function layout() {
  const size = expanded ? OPEN : PILL
  const b = screen.getPrimaryDisplay().bounds // primary = taskbar display; doesn't hop with focus
  win.setBounds({ x: Math.round(b.x + (b.width - size.width) / 2), y: b.y, ...size })
}

function setExpanded(v) {
  if (v === expanded) return
  expanded = v
  layout()
  win.webContents.send('expanded', v)
}

function inside() {
  const p = screen.getCursorScreenPoint(), r = win.getBounds()
  return p.x >= r.x - 2 && p.x <= r.x + r.width + 2 && p.y >= r.y - 2 && p.y <= r.y + r.height + 2
}

/** Typing (focused) or pinned keeps it open; Esc / ✕ forces it shut. */
function collapse(force) {
  if (!expanded) return
  if (!force && (pinned || inside())) return
  setExpanded(false)
  if (win.isFocused()) win.blur() // hand keystrokes back
}

/** Expand and take focus so it stays open until the user clicks elsewhere or presses Esc. */
function openPanel() {
  setExpanded(true)
  win.show()
  win.focus()
}

function tick() {
  if (inside()) {
    lastInside = Date.now()
    if (!expanded) setExpanded(true)
  } else if (Date.now() - lastInside > 500 && !win.isFocused()) {
    collapse(false)
  }
}

function setUpTray() {
  tray = new Tray(nativeImage.createFromPath(path.join(__dirname, 'tray.png')))
  tray.setToolTip('Powvy Note')
  const menu = () => Menu.buildFromTemplate([
    { label: 'Open Powvy Note', click: openPanel },
    { type: 'separator' },
    {
      label: 'Open at Login', type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin,
      click: i => app.setLoginItemSettings({ openAtLogin: i.checked }),
    },
    { type: 'separator' },
    { label: 'Quit Powvy Note', click: () => { app.isQuitting = true; app.quit() } },
  ])
  tray.on('click', openPanel) // Windows convention: left-click opens, right-click menu
  tray.on('right-click', () => tray.popUpContextMenu(menu()))
}

app.whenReady().then(() => {
  store = new NoteStore(dir)
  if (store.load().length === 0) {
    store.create('# Welcome to Powvy Note\n\n- [ ] Hover the top of the screen to open\n- [ ] Click a note to type\n- [x] Markdown preview with the eye button\n- [ ] Tray icon reopens it any time\n')
  }

  ipcMain.handle('notes:load', () => store.load())
  ipcMain.handle('notes:create', () => store.create())
  ipcMain.handle('notes:save', (_, note) => store.save(note)) // ponytail: write per keystroke; debounce if notes get huge
  ipcMain.handle('notes:delete', (_, note) => store.delete(note))
  ipcMain.on('panel:close', () => collapse(true))
  ipcMain.on('panel:pin', (_, v) => { pinned = v })
  ipcMain.on('open-external', (_, url) => { if (/^https?:\/\//.test(url)) shell.openExternal(url) })

  win = new BrowserWindow({
    ...PILL, frame: false, transparent: true, resizable: false, movable: false,
    minimizable: false, maximizable: false, fullscreenable: false, skipTaskbar: true,
    alwaysOnTop: true, hasShadow: false, show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  })
  win.setAlwaysOnTop(true, 'screen-saver') // above full-screen apps and the taskbar
  win.loadFile('index.html')
  win.once('ready-to-show', () => { layout(); win.showInactive() }) // never steal focus on launch
  win.on('blur', () => collapse(false))
  win.on('close', e => { if (!app.isQuitting) { e.preventDefault(); collapse(true) } }) // Alt+F4 collapses
  win.webContents.on('will-navigate', e => e.preventDefault())
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))

  for (const ev of ['display-added', 'display-removed', 'display-metrics-changed']) screen.on(ev, layout)
  setInterval(tick, 100) // poll the cursor: works without focus, like the Mac version
  setUpTray()
})

// Launching it again from the Start menu while it's running opens the panel.
app.on('second-instance', openPanel)
app.on('window-all-closed', e => e.preventDefault())
