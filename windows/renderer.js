/* global powvy, title, parseMarkdown, toggleTask, strikeRE, tagRE, tagKinds, splitTags, tagInsertion, opensTagPicker, skipsTagClose, toggleStrike */
const $ = id => document.getElementById(id)
const EYE = '<svg viewBox="0 0 24 24"><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>'
const PENCIL = '<svg viewBox="0 0 24 24"><path d="M4 20h4L19 9l-4-4L4 16z"/></svg>'

let notes = [], selected = null, preview = false, pinned = false
let tagAnchor = null, pendingAnchor = null // caret offset just after a freshly typed `[` while the tag bar is up
const TAG_LABEL = { todo: 'To do', homework: 'Homework', test: 'Test', appointment: 'Appointment', class: 'Class' }
const current = () => notes.find(n => n.file === selected)

const esc = s => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))

/** Inline markdown: tags as chips, then `code`, ~~strike~~, **bold**, *italic*, [link](http…) on escaped text. */
function inline(s) {
  return splitTags(s).map(p => p.type === 'tag'
    ? `<span class="chip k-${p.kind}">${TAG_LABEL[p.kind]}${p.detail ? ' · ' + esc(p.detail) : ''}</span>`
    : format(p.text)).join('')
}

function format(s) {
  return esc(s)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(strikeRE, '<del>$1</del>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>')
    .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2">$1</a>')
}

function renderPreview(text) {
  $('preview').innerHTML = parseMarkdown(text).map(b => {
    switch (b.type) {
      case 'heading': return `<h${b.level}>${inline(b.text)}</h${b.level}>`
      case 'bullet': return `<div>• ${inline(b.text)}</div>`
      case 'task': return `<label class="task"><input type="checkbox" data-line="${b.line}" ${b.done ? 'checked' : ''}><span class="${b.done ? 'done' : ''}">${inline(b.text)}</span></label>`
      case 'quote': return `<blockquote>${inline(b.text)}</blockquote>`
      case 'code': return `<pre>${esc(b.text) || ' '}</pre>`
      case 'text': return `<div>${inline(b.text)}</div>`
      default: return '<div style="height:4px"></div>'
    }
  }).join('')
}

/** Draw the editor text underneath the transparent textarea, with strikes and tags styled. */
function paint() {
  const v = $('editor').value
  $('paint').innerHTML = esc(v).replace(strikeRE, '<del>$&</del>').replace(tagRE, m => `<span class="t k-${m.slice(1).match(/^[a-z]+/i)[0].toLowerCase()}">${m}</span>`) + '\n '
  $('paint').scrollTop = $('editor').scrollTop
}

function setTagAnchor(a) {
  tagAnchor = a
  $('tagbar').hidden = a === null
}

/** Insert through the browser's edit path so Ctrl+Z undoes it. */
function insertText(text, start, end) {
  $('editor').setSelectionRange(start, end)
  document.execCommand('insertText', false, text)
}

function strike() {
  const e = $('editor')
  if (preview || !current()) return
  const r = toggleStrike(e.value, e.selectionStart, e.selectionEnd)
  if (r.text === e.value) return
  insertText(r.text, 0, e.value.length)
  e.setSelectionRange(r.start, r.end)
  e.focus()
}

function insertTag(kind) {
  const a = tagAnchor
  if (a === null) return
  setTagAnchor(null)
  const ins = tagInsertion(kind)
  $('editor').focus()
  insertText(ins.text, a - 1, a)
  $('editor').setSelectionRange(a - 1 + ins.caret, a - 1 + ins.caret)
}

function render() {
  const n = current()
  $('list').replaceChildren(...notes.map(note => {
    const b = document.createElement('button')
    b.textContent = title(note.text)
    b.className = note.file === selected ? 'sel' : ''
    b.onclick = () => { selected = note.file; render() }
    return b
  }))
  $('name').textContent = n ? title(n.text) : ''
  $('toggle').innerHTML = preview ? PENCIL : EYE
  $('pin').classList.toggle('on', pinned)
  $('pin').setAttribute('aria-pressed', pinned)
  $('empty').hidden = !!n
  $('editwrap').hidden = !n || preview
  $('strike').disabled = !n || preview
  $('preview').hidden = !n || !preview
  if (!n) return
  if (preview) renderPreview(n.text)
  else if ($('editor').value !== n.text) { $('editor').value = n.text; setTagAnchor(null) }
  if (!preview) paint()
}

function update(text) {
  const n = current()
  if (!n) return
  n.text = text
  powvy.save({ file: n.file, text })
  render()
}

async function reload() {
  notes = await powvy.load()
  if (!current()) selected = notes[0]?.file ?? null
  render()
}

async function newNote() {
  const n = await powvy.create()
  notes.unshift(n)
  selected = n.file
  preview = false
  render()
  $('editor').focus()
}

$('new').onclick = newNote
$('editor').addEventListener('beforeinput', e => {
  const ta = e.target
  if (e.inputType !== 'insertText' || e.data == null) return
  const n = /^[1-9]$/.test(e.data) && +e.data <= tagKinds.length ? +e.data : 0
  if (tagAnchor !== null && n) { e.preventDefault(); insertTag(tagKinds[n - 1]); return }
  pendingAnchor = e.data === '[' && ta.selectionStart === ta.selectionEnd && opensTagPicker(ta.value, ta.selectionStart)
    ? ta.selectionStart + 1 : null
})
$('editor').oninput = e => {
  setTagAnchor(pendingAnchor) // any edit other than a fresh `[` closes the tag bar
  pendingAnchor = null
  update(e.target.value)
}
$('editor').onscroll = () => { $('paint').scrollTop = $('editor').scrollTop }
$('editor').addEventListener('keydown', e => {
  const ta = e.target
  if ((e.key === 'Enter' || e.key === 'Tab') && !e.shiftKey && ta.selectionStart === ta.selectionEnd && skipsTagClose(ta.value, ta.selectionStart)) {
    e.preventDefault() // hop out of `[test 10/25|]`
    const at = ta.selectionStart + 1
    ta.setSelectionRange(at, at)
    if (e.key === 'Enter') insertText('\n', at, at)
  } else if (e.key === 'Tab') {
    e.preventDefault()
    insertText('\t', ta.selectionStart, ta.selectionEnd)
  }
})
document.addEventListener('selectionchange', () => {
  const ta = $('editor')
  if (tagAnchor !== null && (ta.selectionStart !== tagAnchor || ta.selectionEnd !== tagAnchor)) setTagAnchor(null)
})
$('tagbar').onmousedown = e => e.preventDefault() // keep the caret in the editor
$('tagbar').onclick = e => { if (e.target.dataset.kind) insertTag(e.target.dataset.kind) }
$('strike').onmousedown = e => e.preventDefault() // keep the selection
$('strike').onclick = strike
$('toggle').onclick = () => { preview = !preview; render() }
$('pin').onclick = () => { pinned = !pinned; powvy.pin(pinned); render() }
$('trash').onclick = async () => {
  const n = current()
  if (!n) return
  await powvy.remove(n)
  notes = notes.filter(x => x !== n)
  selected = notes[0]?.file ?? null
  render()
}
$('close').onclick = () => powvy.close()
$('preview').onchange = e => { if (e.target.dataset.line) update(toggleTask(current().text, +e.target.dataset.line)) }
$('preview').onclick = e => {
  const a = e.target.closest('a')
  if (a) { e.preventDefault(); powvy.openExternal(a.href) }
}
document.onkeydown = e => {
  if (e.key === 'Escape') { if (tagAnchor !== null) setTagAnchor(null); else powvy.close() }
  if (e.ctrlKey && e.shiftKey && e.key.toLowerCase() === 'x') { e.preventDefault(); strike() }
  if (e.ctrlKey && e.key.toLowerCase() === 'n') { e.preventDefault(); newNote() }
}

// Pick up edits made outside the app (e.g. in Notepad) each time it opens.
powvy.onExpanded(open => { $('shell').classList.toggle('open', open); if (open) reload() })
reload()
