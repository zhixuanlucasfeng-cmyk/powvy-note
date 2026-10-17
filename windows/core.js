// Port of Sources/PowvyNoteCore/Core.swift — keep the two in step.
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

/** One `.md` file per note in `dir`. */
class NoteStore {
  constructor(dir) {
    this.dir = dir
    fs.mkdirSync(dir, { recursive: true })
  }

  /** Newest-modified first. */
  load() {
    return fs.readdirSync(this.dir)
      .filter(f => f.endsWith('.md'))
      .map(f => {
        const file = path.join(this.dir, f)
        return { file, mtime: fs.statSync(file).mtimeMs, text: fs.readFileSync(file, 'utf8') }
      })
      .sort((a, b) => b.mtime - a.mtime)
      .map(({ file, text }) => ({ file, text }))
  }

  create(text = '# New note\n\n') {
    const file = path.join(this.dir, `note-${crypto.randomUUID().slice(0, 8).toUpperCase()}.md`)
    const note = { file, text }
    this.save(note)
    return note
  }

  save(note) {
    this.check(note.file)
    const tmp = note.file + '.tmp'
    fs.writeFileSync(tmp, note.text, 'utf8')
    fs.renameSync(tmp, note.file) // atomic, like Swift's atomically: true
  }

  delete(note) {
    this.check(note.file)
    fs.rmSync(note.file)
  }

  // The renderer hands file paths back over IPC; never touch anything outside the notes folder.
  check(file) {
    if (path.dirname(path.resolve(file)) !== path.resolve(this.dir) || !file.endsWith('.md')) {
      throw new Error(`not a note: ${file}`)
    }
  }
}

module.exports = { NoteStore }
