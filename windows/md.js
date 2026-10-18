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


// Strikethrough ("done") and bracket tags — mirrors the same section of Sources/PowvyNoteCore/Core.swift.
const strikeRE = /~~(?=\S)(.+?)(?<=\S)~~/g
/** `[todo]`, `[homework]`, `[test 10/25]`, `[appointment Fri 3pm]` — not `[test](url)` links. */
const tagRE = /\[(todo|homework|test|appointment)(?:[:\s]+([^\[\]\n]*?))?\s*\](?!\()/gi
const tagKinds = ['todo', 'homework', 'test', 'appointment']

function splitTags(s) {
  const out = []
  let pos = 0
  for (const m of s.matchAll(tagRE)) {
    if (m.index > pos) out.push({ type: 'text', text: s.slice(pos, m.index) })
    out.push({ type: 'tag', kind: m[1].toLowerCase(), detail: m[2] || '' })
    pos = m.index + m[0].length
  }
  if (pos < s.length) out.push({ type: 'text', text: s.slice(pos) })
  return out
}

/** What the tag picker inserts in place of the typed `[`, and where the caret goes (offset into it). */
function tagInsertion(kind) {
  return kind === 'test' || kind === 'appointment'
    ? { text: `[${kind} ]`, caret: kind.length + 2 }
    : { text: `[${kind}] `, caret: kind.length + 3 }
}

/** Should typing `[` at `at` open the tag picker? Not for task boxes (`- [`). */
function opensTagPicker(src, at) {
  return !/^\s*[-*+]\s*$/.test(src.slice(src.lastIndexOf('\n', at - 1) + 1, at))
}

/** Caret sits just before the `]` of a dated tag being filled in (`[test 10/25|]`): Enter/Tab should hop out. */
function skipsTagClose(src, at) {
  return src[at] === ']' && /\[(test|appointment)\b[^[\]]*$/i.test(src.slice(src.lastIndexOf('\n', at - 1) + 1, at))
}

/**
 * Wrap the selection in `~~` to strike it out, or unwrap it if already struck. Empty selection = the
 * caret's line minus its list/heading marker. Goes line by line (markdown strikes can't span lines).
 * Returns { text, start, end } with the new selection.
 */
function toggleStrike(src, start, end) {
  let s = src
  if (start === end) {
    const ls = s.lastIndexOf('\n', start - 1) + 1
    let le = s.indexOf('\n', start)
    if (le < 0) le = s.length
    if (s[le - 1] === '\r') le--
    start = ls + s.slice(ls, le).match(/^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|#{1,6}\s+|>\s?)?/)[0].length
    end = le
  }
  const segs = [] // non-blank piece of each line inside [start, end)
  for (let pos = start; pos < end;) {
    const nl = s.indexOf('\n', pos)
    const lineEnd = nl < 0 ? s.length : nl + 1
    let a = pos, b = Math.min(lineEnd, end)
    while (a < b && /\s/.test(s[a])) a++
    while (b > a && /\s/.test(s[b - 1])) b--
    if (b > a) segs.push([a, b])
    pos = lineEnd
  }
  if (!segs.length) return { text: src, start, end }

  const inner = ([a, b]) => b - a >= 4 && s.startsWith('~~', a) && s.slice(b - 2, b) === '~~'
  const outer = ([a, b]) => a >= 2 && s.slice(a - 2, a) === '~~' && s.slice(b, b + 2) === '~~'
  // Decide everything before editing: 0 = leave, 1 = add ~~, 2 = remove inner ~~, 3 = remove outer ~~.
  const unstrike = inner(segs[0]) || outer(segs[0])
  const ops = segs.map(g => unstrike ? (inner(g) ? 2 : outer(g) ? 3 : 0) : (inner(g) || outer(g) ? 0 : 1))
  const lastEnd = segs[segs.length - 1][1]
  let shift = 0 // net length change at or before lastEnd, so the new selection still covers every segment
  for (let i = segs.length - 1; i >= 0; i--) { // back to front keeps earlier offsets valid
    const [a, b] = segs[i]
    if (ops[i] === 1) { s = s.slice(0, a) + '~~' + s.slice(a, b) + '~~' + s.slice(b); shift += 4 }
    if (ops[i] === 2) { s = s.slice(0, a) + s.slice(a + 2, b - 2) + s.slice(b); shift -= 4 }
    if (ops[i] === 3) { s = s.slice(0, a - 2) + s.slice(a, b) + s.slice(b + 2); shift -= b === lastEnd ? 2 : 4 }
  }
  return { text: s, start: segs[0][0] - (ops[0] === 3 ? 2 : 0), end: lastEnd + shift }
}

if (typeof module !== 'undefined') module.exports = { title, parseMarkdown, toggleTask, strikeRE, tagRE, tagKinds, splitTags, tagInsertion, opensTagPicker, skipsTagClose, toggleStrike }
