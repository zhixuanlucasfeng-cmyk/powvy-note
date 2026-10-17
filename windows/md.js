// Pure markdown helpers, shared by core.js (Node) and index.html (renderer).
function title(text) {
  const t = (text.split('\n')[0] || '').replace(/^[#\s]+|[#\s]+$/g, '')
  return t || 'Untitled'
}

/** Line-based block parser. */
function parseMarkdown(src) {
  const out = []
  let inCode = false
  src.split('\n').forEach((raw, i) => {
    const line = raw.trim()
    let m
    if (line.startsWith('```')) { inCode = !inCode; return }
    if (inCode) return out.push({ type: 'code', text: raw })
    if (!line) return out.push({ type: 'blank' })
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) out.push({ type: 'heading', level: m[1].length, text: m[2] })
    else if ((m = line.match(/^[-*]\s+\[([ xX])\]\s*(.*)$/))) out.push({ type: 'task', done: m[1] !== ' ', text: m[2], line: i })
    else if ((m = line.match(/^[-*+]\s+(.*)$/))) out.push({ type: 'bullet', text: m[1] })
    else if ((m = line.match(/^>\s?(.*)$/))) out.push({ type: 'quote', text: m[1] })
    else out.push({ type: 'text', text: line })
  })
  return out
}

/** Flip `[ ]` <-> `[x]` on the given line; anything else is returned unchanged. */
function toggleTask(src, line) {
  const lines = src.split('\n')
  if (line < 0 || line >= lines.length) return src
  const l = lines[line]
  if (l.includes('[ ]')) lines[line] = l.replace('[ ]', '[x]')
  else if (/\[[xX]\]/.test(l)) lines[line] = l.replace(/\[[xX]\]/, '[ ]')
  return lines.join('\n')
}

if (typeof module !== 'undefined') module.exports = { title, parseMarkdown, toggleTask }
