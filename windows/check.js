// `node check.js` — port of Sources/SelfCheck.
const assert = require('assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { title, NoteStore, parseMarkdown, toggleTask, toggleStrike, splitTags, tagInsertion, opensTagPicker, skipsTagClose } = { ...require('./core'), ...require('./md') }

const md = '# Title\n- [ ] todo\n- [x] done\n- item\n> quote\n```\ncode # not heading\n```\n\nplain **bold**'
assert.deepEqual(parseMarkdown(md), [
  { type: 'heading', level: 1, text: 'Title' },
  { type: 'task', done: false, text: 'todo', line: 1 },
  { type: 'task', done: true, text: 'done', line: 2 },
  { type: 'bullet', text: 'item' },
  { type: 'quote', text: 'quote' },
  { type: 'code', text: 'code # not heading' },
  { type: 'blank' },
  { type: 'text', text: 'plain **bold**' },
])

const toggled = toggleTask(md, 1)
assert.ok(toggled.includes('- [x] todo'))
assert.equal(toggleTask(toggled, 1), md)
assert.equal(toggleTask(md, 99), md)

assert.equal(title('## Hello\nbody'), 'Hello')
assert.equal(title(''), 'Untitled')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'powvy-check-'))
const store = new NoteStore(dir)
const a = store.create('# A')
const b = store.create('# B')
fs.utimesSync(a.file, new Date(1000), new Date(1000)) // instead of sleeping for mtime resolution
assert.deepEqual(store.load().map(n => title(n.text)), ['B', 'A'])
a.text = '# A2'; store.save(a)
assert.equal(title(store.load()[0].text), 'A2')
store.delete(b)
assert.deepEqual(store.load().map(n => title(n.text)), ['A2'])
assert.throws(() => store.save({ file: path.join(dir, '..', 'evil.md'), text: 'x' }))
assert.throws(() => store.delete({ file: path.join(dir, 'x.txt') }))
fs.rmSync(dir, { recursive: true })

// Strikethrough + tags: same cases as Sources/SelfCheck
const st = (t, a, b) => toggleStrike(t, a, b)
let r = st('buy milk now', 4, 9)
assert.deepEqual(r, { text: 'buy ~~milk~~ now', start: 4, end: 12 })
r = st(r.text, r.start, r.end)
assert.deepEqual(r, { text: 'buy milk now', start: 4, end: 8 })
assert.deepEqual(st('buy ~~milk~~ now', 6, 10), { text: 'buy milk now', start: 4, end: 8 })
assert.equal(st('- [ ] call mum\nnext', 8, 8).text, '- [ ] ~~call mum~~\nnext')
assert.equal(st('# Title', 3, 3).text, '# ~~Title~~')
r = st('one\n\ntwo', 0, 8)
assert.deepEqual(r, { text: '~~one~~\n\n~~two~~', start: 0, end: 16 })
assert.equal(st(r.text, r.start, r.end).text, 'one\n\ntwo')
assert.equal(st('   ', 0, 3).text, '   ')
assert.equal(st('你好世界', 2, 4).text, '你好~~世界~~')

assert.deepEqual(splitTags('Read ch.4 [homework] and [test 10/25]!'), [
  { type: 'text', text: 'Read ch.4 ' }, { type: 'tag', kind: 'homework', detail: '' },
  { type: 'text', text: ' and ' }, { type: 'tag', kind: 'test', detail: '10/25' }, { type: 'text', text: '!' },
])
assert.deepEqual(splitTags('[Appointment: Fri 3pm] dentist'), [{ type: 'tag', kind: 'appointment', detail: 'Fri 3pm' }, { type: 'text', text: ' dentist' }])
assert.deepEqual(splitTags('[test](https://x.y) [x] [todos]'), [{ type: 'text', text: '[test](https://x.y) [x] [todos]' }])
assert.deepEqual(splitTags('[test 1/3 - [ ] x]'), [{ type: 'text', text: '[test 1/3 - [ ] x]' }])
assert.deepEqual(tagInsertion('todo'), { text: '[todo] ', caret: 7 })
assert.deepEqual(tagInsertion('test'), { text: '[test ]', caret: 6 })
assert.ok(opensTagPicker('note ', 5) && !opensTagPicker('a\n- ', 4) && opensTagPicker('', 0))
assert.ok(skipsTagClose('x [test 10/25]', 13) && skipsTagClose('[Appointment ]', 13))
assert.ok(!skipsTagClose('x [todo]', 7) && !skipsTagClose('[test] y]', 8) && !skipsTagClose('[test', 5))

console.log('SelfCheck OK')
