// `node check.js` — port of Sources/SelfCheck.
const assert = require('assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { title, NoteStore, parseMarkdown, toggleTask } = { ...require('./core'), ...require('./md') }

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

console.log('SelfCheck OK')
