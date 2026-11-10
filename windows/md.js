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
/** `[todo]`, `[homework]`, `[test 10/25]`, `[appointment Fri 3pm]`, `[class Maths 9am]` — not `[test](url)` links. */
const tagRE = /\[(todo|homework|test|appointment|class)(?:[:\s]+([^\[\]\n]*?))?\s*\](?!\()/gi
const tagKinds = ['todo', 'homework', 'test', 'appointment', 'class']
/** Tags that carry a date/time/subject, so the caret is left inside the brackets. */
const detailTagKinds = ['test', 'appointment', 'class']

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
  return detailTagKinds.includes(kind)
    ? { text: `[${kind} ]`, caret: kind.length + 2 }
    : { text: `[${kind}] `, caret: kind.length + 3 }
}

/** Should typing `[` at `at` open the tag picker? Not for task boxes (`- [`). */
function opensTagPicker(src, at) {
  return !/^\s*[-*+]\s*$/.test(src.slice(src.lastIndexOf('\n', at - 1) + 1, at))
}

/** Caret sits just before the `]` of a dated tag being filled in (`[test 10/25|]`): Enter/Tab should hop out. */
function skipsTagClose(src, at) {
  return src[at] === ']' && /\[(test|appointment|class)\b[^[\]]*$/i.test(src.slice(src.lastIndexOf('\n', at - 1) + 1, at))
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

// Sidebar: tag filters, search, preview line — mirrors the same section of Core.swift.
/** Tag kinds used anywhere in the note, in `tagKinds` order. */
function noteTags(text) {
  const used = new Set([...text.matchAll(tagRE)].map(m => m[1].toLowerCase()))
  return tagKinds.filter(k => used.has(k))
}

/** First non-empty line after the title, with list/quote/heading markers stripped. */
function snippet(text) {
  const lines = text.split('\n').map(l => l.trim()).filter(Boolean)
  return lines.length > 1 ? lines[1].replace(/^(#+|[-*+]\s+\[[ xX]\]|[-*+>])\s*/, '') : ''
}

/** Case-insensitive text search plus an optional tag kind. */
function noteMatches(text, query, tag) {
  const q = query.trim().toLowerCase()
  return (!q || text.toLowerCase().includes(q)) && (!tag || noteTags(text).includes(tag))
}

// Weekly timetable — mirrors the same section of Core.swift. The classes live in one "Timetable template" note;
// every week a fresh, blank set of day notes is made from it. Old weeks stay as ordinary notes.
const timetableTemplateTitle = 'Timetable template'
const weekDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const timetableTemplateExample = `# Timetable template

One class per line under its day: time, subject · teacher · room.
Every week a fresh, blank note per day is made from this. Old weeks stay in the list: tap Class, or search a date like "9 Nov".

## Monday
08:00–08:50 Maths · Mr Smith · Room 12
09:00–09:50 English · Ms Lee · Room 3

## Tuesday
08:00–08:50 Science · Dr Khan · Lab 2

## Wednesday

## Thursday

## Friday
`

const isTimetableTemplate = text => title(text).toLowerCase() === timetableTemplateTitle.toLowerCase()

/** Monday 00:00 of the week containing `date`, local time. */
function weekStart(date) {
  const d = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  d.setDate(d.getDate() - (d.getDay() + 6) % 7)
  return d
}

/** "Monday 16 Nov · Timetable" — also how an existing week is recognised, so keep it stable. */
const dayNoteTitle = (day, date) => `${day} ${date.getDate()} ${MONTHS[date.getMonth()]} · Timetable`

/** One blank note per day that has classes, Monday first, for the week starting `monday`. */
function weekNotes(template, monday) {
  const classes = {}
  let day = null
  for (const raw of template.split('\n')) {
    const line = raw.trim()
    if (line.startsWith('## ')) {
      const d = line.slice(3).trim().toLowerCase().replace(/\b\w/g, c => c.toUpperCase())
      day = weekDays.includes(d) ? d : null
    } else if (day && line) (classes[day] ||= []).push(line)
  }
  return weekDays.flatMap((d, i) => {
    if (!classes[d]) return []
    const date = new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + i)
    const blocks = classes[d].map(line => {
      const m = line.match(/^(\d{1,2}[:.]\d{2}(?:\s*[–-]\s*\d{1,2}[:.]\d{2})?)\s+(.+?)(?:\s+·\s+(.*))?$/)
      const time = m ? m[1] : '', rest = m && m[3] ? m[3] : ''
      const subject = (m ? m[2] : line).replace(/\[/g, '(').replace(/]/g, ')')
      const start = time.split(/[–-]/)[0].trim()
      const head = time ? `${time} ${subject}` : subject
      const tag = `[class ${subject}${start ? ' ' + start : ''}]` + (rest ? ' ' + rest : '')
      return `## ${head}\n${tag}\n- In class: \n- Not finished: \n- Homework: \n`
    })
    return [`# ${dayNoteTitle(d, date)}\n\n` + blocks.join('\n')]
  })
}

if (typeof module !== 'undefined') module.exports = { timetableTemplateTitle, weekDays, timetableTemplateExample, isTimetableTemplate, weekStart, dayNoteTitle, weekNotes, noteTags, snippet, noteMatches, title, parseMarkdown, toggleTask, strikeRE, tagRE, tagKinds, splitTags, tagInsertion, opensTagPicker, skipsTagClose, toggleStrike }
