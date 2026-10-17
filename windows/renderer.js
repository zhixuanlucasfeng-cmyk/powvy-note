/* global powvy, title, parseMarkdown, toggleTask */
const $ = id => document.getElementById(id)
const EYE = '<svg viewBox="0 0 24 24"><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>'
const PENCIL = '<svg viewBox="0 0 24 24"><path d="M4 20h4L19 9l-4-4L4 16z"/></svg>'

let notes = [], selected = null, preview = false, pinned = false
const current = () => notes.find(n => n.file === selected)

const esc = s => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))

/** Inline markdown on already-escaped text: `code`, **bold**, *italic*, [link](http…). */
function inline(s) {
  return esc(s)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
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
  $('editor').hidden = !n || preview
  $('preview').hidden = !n || !preview
  if (!n) return
  if (preview) renderPreview(n.text)
  else if ($('editor').value !== n.text) $('editor').value = n.text
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
$('editor').oninput = e => update(e.target.value)
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
  if (e.key === 'Escape') powvy.close()
  if (e.ctrlKey && e.key.toLowerCase() === 'n') { e.preventDefault(); newNote() }
}

// Pick up edits made outside the app (e.g. in Notepad) each time it opens.
powvy.onExpanded(open => { $('shell').classList.toggle('open', open); if (open) reload() })
reload()
