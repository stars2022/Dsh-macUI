import { chmod, mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { randomId } from './crypto.mjs'

const EMPTY = () => ({
  schema: 1,
  cursor: 0,
  vaults: {},
  pairings: {},
  claims: {},
  sync: {},
  frames: [],
})

export class RelayStore {
  constructor(dataDir) {
    this.file = join(dataDir, 'relay-state.json')
    this.data = EMPTY()
    this.tail = Promise.resolve()
  }

  async open() {
    await mkdir(dirname(this.file), { recursive: true, mode: 0o700 })
    try {
      const parsed = JSON.parse(await readFile(this.file, 'utf8'))
      if (parsed?.schema !== 1) throw new Error('unsupported relay state schema')
      this.data = { ...EMPTY(), ...parsed }
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
      await this.persist()
    }
    return this
  }

  async read(fn) {
    await this.tail
    return fn(this.data)
  }

  async change(fn) {
    const task = this.tail.then(async () => {
      const result = fn(this.data)
      await this.persist()
      return result
    })
    this.tail = task.then(() => undefined, () => undefined)
    return task
  }

  nextCursor(data = this.data) {
    data.cursor += 1
    return data.cursor
  }

  async persist() {
    const temporary = `${this.file}.${randomId(6)}.tmp`
    await writeFile(temporary, `${JSON.stringify(this.data)}\n`, { mode: 0o600 })
    await chmod(temporary, 0o600)
    await rename(temporary, this.file)
  }
}
