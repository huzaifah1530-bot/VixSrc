import { DurableObject } from 'cloudflare:workers'

interface Env {
  ACCOUNTS: DurableObjectNamespace<Account>
  DIRECTORY: DurableObjectNamespace<Directory>
  AUTH_LIMIT: { limit(input: { key: string }): Promise<{ success: boolean }> }
  PIN_PEPPER: string
}

const encoder = new TextEncoder()
const SESSION_MS = 90 * 24 * 60 * 60 * 1000
const MAX_BODY = 512 * 1024
const usernamePattern = /^[a-z][a-z0-9_]{2,23}$/
const pinPattern = /^(?:\d{4}|\d{6})$/

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      'strict-transport-security': 'max-age=31536000',
      'referrer-policy': 'no-referrer'
    }
  })
}

function error(code: string, status: number): Response {
  return json({ error: { code } }, status)
}

async function body(request: Request): Promise<Record<string, unknown> | null> {
  if (Number(request.headers.get('content-length') ?? 0) > MAX_BODY) return null
  const bytes = await request.arrayBuffer()
  if (bytes.byteLength > MAX_BODY) return null
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes))
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null
  } catch { return null }
}

function random(bytes: number): string {
  const array = crypto.getRandomValues(new Uint8Array(bytes))
  return btoa(String.fromCharCode(...array)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function digest(value: string): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', encoder.encode(value))
  return Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, '0')).join('')
}

async function pinHash(pin: string, salt: string, pepper: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', encoder.encode(`${pepper}:${pin}`), 'PBKDF2', false, ['deriveBits'])
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: encoder.encode(salt), iterations: 100_000 }, key, 256)
  return Array.from(new Uint8Array(bits), b => b.toString(16).padStart(2, '0')).join('')
}

function username(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const normalized = value.trim().toLowerCase()
  return usernamePattern.test(normalized) ? normalized : null
}

function acceptablePin(value: unknown): value is string {
  return typeof value === 'string' && pinPattern.test(value) && !/^(\d)\1+$/.test(value) && !['1234', '4321', '123456', '654321'].includes(value)
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!env.PIN_PEPPER || env.PIN_PEPPER.length < 32) return error('unavailable', 503)
    const url = new URL(request.url)
    if (!url.pathname.startsWith('/v1/')) return error('not_found', 404)
    if (request.method === 'OPTIONS') return error('not_found', 404)
    const action = url.pathname.slice(4)
    if (!['register', 'login', 'recover', 'session', 'username', 'pin', 'devices', 'account'].includes(action) && !action.startsWith('backup/') && !action.startsWith('devices/')) return error('not_found', 404)
    if (['register', 'login', 'recover'].includes(action) && request.method !== 'POST') return error('method_not_allowed', 405)
    let accountName: string | null
    let payload: Record<string, unknown> | null = null
    if (['register', 'login', 'recover'].includes(action)) {
      const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown'
      const limited = await env.AUTH_LIMIT.limit({ key: `${action}:${ip}` })
      if (!limited.success) return error('rate_limited', 429)
      payload = await body(request)
      accountName = username(payload?.username)
    } else {
      accountName = username(request.headers.get('X-Vela-Username'))
    }
    const directKey = !['register', 'login', 'recover'].includes(action) ? request.headers.get('X-Vela-Account-Key') : null
    if (!accountName && !directKey) return error('invalid_request', 400)
    const directory = env.DIRECTORY.get(env.DIRECTORY.idFromName('users'))
    let accountKey: string
    if (directKey && /^[0-9a-f-]{36}$/.test(directKey)) {
      accountKey = directKey
    } else if (action === 'register') {
      if (!acceptablePin(payload?.pin)) return error('invalid_pin', 400)
      const reserve = await directory.fetch(new Request('https://internal/reserve', { method: 'POST', body: JSON.stringify({ username: accountName }) }))
      if (!reserve.ok) return error('username_taken', 409)
      accountKey = (await reserve.json() as { key: string }).key
    } else {
      const lookup = await directory.fetch(new Request('https://internal/resolve', { method: 'POST', body: JSON.stringify({ username: accountName }) }))
      if (!lookup.ok) return error('invalid_credentials', 401)
      accountKey = (await lookup.json() as { key: string }).key
    }
    const id = env.ACCOUNTS.idFromName(accountKey)
    const forwarded = payload
      ? new Request(request.url, { method: request.method, headers: request.headers, body: JSON.stringify(payload) })
      : new Request(request)
    if (accountName) forwarded.headers.set('X-Vela-Normalized-Username', accountName)
    forwarded.headers.set('X-Vela-Account-Key', accountKey)
    const response = await env.ACCOUNTS.get(id).fetch(forwarded)
    if (action === 'register' && !response.ok) {
      await directory.fetch(new Request('https://internal/delete', { method: 'POST', body: JSON.stringify({ username: accountName, key: accountKey }) }))
    }
    if (response.ok && ['register', 'login', 'recover'].includes(action)) {
      return json({ ...await response.json() as Record<string, unknown>, accountKey }, response.status)
    }
    return response
  }
}

export class Directory extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS names (username TEXT PRIMARY KEY, account_key TEXT NOT NULL)')
  }

  async fetch(request: Request): Promise<Response> {
    const input = await body(request)
    const name = username(input?.username)
    if (!name) return error('invalid_request', 400)
    const sql = this.ctx.storage.sql
    const path = new URL(request.url).pathname
    if (path === '/resolve') {
      const row = sql.exec<{ [key: string]: string; account_key: string }>('SELECT account_key FROM names WHERE username = ?', name).toArray()[0]
      return row ? json({ key: row.account_key }) : error('not_found', 404)
    }
    if (path === '/reserve') {
      if (sql.exec('SELECT 1 FROM names WHERE username = ?', name).toArray().length) return error('username_taken', 409)
      const key = crypto.randomUUID()
      sql.exec('INSERT INTO names (username, account_key) VALUES (?, ?)', name, key)
      return json({ key }, 201)
    }
    const key = input?.key
    if (typeof key !== 'string' || key.length !== 36) return error('invalid_request', 400)
    if (path === '/rename') {
      const next = username(input?.next)
      if (!next) return error('invalid_request', 400)
      if (next === name) return json({ username: name })
      if (sql.exec('SELECT 1 FROM names WHERE username = ?', next).toArray().length) return error('username_taken', 409)
      const result = sql.exec('UPDATE names SET username = ? WHERE username = ? AND account_key = ?', next, name, key)
      return result.rowsWritten ? json({ username: next }) : error('not_found', 404)
    }
    if (path === '/delete') {
      sql.exec('DELETE FROM names WHERE username = ? AND account_key = ?', name, key)
      return json({ ok: true })
    }
    return error('not_found', 404)
  }
}

interface AccountRow {
  [key: string]: string | number
  pin_hash: string
  salt: string
  recovery_hash: string
  failures: number
  locked_until: number
  recovery_failures: number
  recovery_locked_until: number
  username: string
}

interface SessionRow { [key: string]: string | number; token_hash: string; expires_at: number; device_id: string }
interface BackupRow { [key: string]: string | number; revision: number; payload: string }

export class Account extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS identity (id INTEGER PRIMARY KEY CHECK (id = 1), username TEXT NOT NULL, pin_hash TEXT NOT NULL, salt TEXT NOT NULL, recovery_hash TEXT NOT NULL, failures INTEGER NOT NULL DEFAULT 0, locked_until INTEGER NOT NULL DEFAULT 0, recovery_failures INTEGER NOT NULL DEFAULT 0, recovery_locked_until INTEGER NOT NULL DEFAULT 0)')
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, device_id TEXT NOT NULL, device_name TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL)')
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS backups (kind TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload TEXT NOT NULL)')
  }

  private get identity(): AccountRow | undefined {
    return this.ctx.storage.sql.exec<AccountRow>('SELECT username, pin_hash, salt, recovery_hash, failures, locked_until, recovery_failures, recovery_locked_until FROM identity WHERE id = 1').toArray()[0]
  }

  private async createSession(deviceName: unknown): Promise<{ token: string; expiresAt: number }> {
    const token = random(32)
    const tokenHash = await digest(token)
    const expiresAt = Date.now() + SESSION_MS
    const name = typeof deviceName === 'string' && deviceName.length <= 64 ? deviceName.trim() || 'Vela device' : 'Vela device'
    this.ctx.storage.sql.exec('INSERT INTO sessions (token_hash, device_id, device_name, created_at, expires_at) VALUES (?, ?, ?, ?, ?)', tokenHash, crypto.randomUUID(), name, Date.now(), expiresAt)
    return { token, expiresAt }
  }

  private async authenticate(request: Request): Promise<string | null> {
    const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get('authorization') ?? '')
    if (!match) return null
    const tokenHash = await digest(match[1])
    const row = this.ctx.storage.sql.exec<SessionRow>('SELECT token_hash, expires_at FROM sessions WHERE token_hash = ?', tokenHash).toArray()[0]
    return row && row.expires_at > Date.now() ? tokenHash : null
  }

  async fetch(request: Request): Promise<Response> {
    const action = new URL(request.url).pathname.slice(4)
    if (action === 'register') return this.register(request)
    if (action === 'login') return this.login(request)
    if (action === 'recover') return this.recover(request)
    const tokenHash = await this.authenticate(request)
    if (!tokenHash) return error('unauthorized', 401)
    if (action === 'session' && request.method === 'DELETE') {
      this.ctx.storage.sql.exec('DELETE FROM sessions WHERE token_hash = ?', tokenHash)
      return json({ ok: true })
    }
    if (action === 'session' && request.method === 'GET') return json({ ok: true, username: this.identity?.username })
    if (action === 'devices' && request.method === 'GET') {
      const list = this.ctx.storage.sql.exec<{ [key: string]: string | number; token_hash: string; device_id: string; device_name: string; created_at: number; expires_at: number }>('SELECT token_hash, device_id, device_name, created_at, expires_at FROM sessions WHERE expires_at > ? ORDER BY created_at DESC', Date.now()).toArray()
      return json({ devices: list.map(({ token_hash, ...device }) => ({ ...device, current: token_hash === tokenHash })) })
    }
    if (action.startsWith('devices/') && request.method === 'DELETE') {
      const id = action.slice('devices/'.length)
      if (!/^[0-9a-f-]{36}$/.test(id)) return error('invalid_request', 400)
      const row = this.ctx.storage.sql.exec<{ [key: string]: string; token_hash: string }>('SELECT token_hash FROM sessions WHERE device_id = ?', id).toArray()[0]
      this.ctx.storage.sql.exec('DELETE FROM sessions WHERE device_id = ?', id)
      return json({ ok: true, current: row?.token_hash === tokenHash })
    }
    if (action === 'username' && request.method === 'POST') {
      const input = await body(request)
      const next = username(input?.next)
      if (!next) return error('invalid_request', 400)
      const from = this.identity?.username
      const key = request.headers.get('X-Vela-Account-Key')
      const directory = this.env.DIRECTORY.get(this.env.DIRECTORY.idFromName('users'))
      const changed = await directory.fetch(new Request('https://internal/rename', { method: 'POST', body: JSON.stringify({ username: from, next, key }) }))
      if (changed.ok) this.ctx.storage.sql.exec('UPDATE identity SET username = ? WHERE id = 1', next)
      return changed
    }
    if (action === 'pin' && request.method === 'POST') {
      const input = await body(request)
      if (typeof input?.currentPin !== 'string' || !acceptablePin(input?.newPin)) return error('invalid_request', 400)
      const identity = this.identity
      if (!identity || await pinHash(input.currentPin, identity.salt, this.env.PIN_PEPPER) !== identity.pin_hash) return error('invalid_credentials', 401)
      const salt = random(16)
      const hash = await pinHash(input.newPin, salt, this.env.PIN_PEPPER)
      this.ctx.storage.sql.exec('UPDATE identity SET pin_hash = ?, salt = ?, failures = 0, locked_until = 0 WHERE id = 1', hash, salt)
      return json({ ok: true })
    }
    if (action === 'account' && request.method === 'DELETE') {
      const input = await body(request)
      const identity = this.identity
      if (!identity || typeof input?.pin !== 'string' || await pinHash(input.pin, identity.salt, this.env.PIN_PEPPER) !== identity.pin_hash) return error('invalid_credentials', 401)
      const from = identity.username
      const key = request.headers.get('X-Vela-Account-Key')
      const directory = this.env.DIRECTORY.get(this.env.DIRECTORY.idFromName('users'))
      const removed = await directory.fetch(new Request('https://internal/delete', { method: 'POST', body: JSON.stringify({ username: from, key }) }))
      if (!removed.ok) return error('unavailable', 503)
      this.ctx.storage.sql.exec('DELETE FROM sessions')
      this.ctx.storage.sql.exec('DELETE FROM backups')
      this.ctx.storage.sql.exec('DELETE FROM identity')
      return json({ ok: true })
    }
    const kind = action.slice('backup/'.length)
    if (!action.startsWith('backup/') || !['ios', 'desktop', 'shared'].includes(kind)) return error('not_found', 404)
    if (request.method === 'GET') {
      const row = this.ctx.storage.sql.exec<BackupRow>('SELECT revision, payload FROM backups WHERE kind = ?', kind).toArray()[0]
      return row ? json({ revision: row.revision, payload: JSON.parse(row.payload) }) : error('not_found', 404)
    }
    if (request.method !== 'PUT') return error('method_not_allowed', 405)
    const input = await body(request)
    if (!input || !Number.isSafeInteger(input.baseRevision) || (input.baseRevision as number) < 0 || input.payload === null || typeof input.payload !== 'object' || Array.isArray(input.payload)) return error('invalid_request', 400)
    const encoded = JSON.stringify(input.payload)
    if (encoder.encode(encoded).byteLength > MAX_BODY) return error('too_large', 413)
    const current = this.ctx.storage.sql.exec<BackupRow>('SELECT revision, payload FROM backups WHERE kind = ?', kind).toArray()[0]
    const revision = current?.revision ?? 0
    if (revision !== input.baseRevision) return json({ error: { code: 'conflict' }, revision }, 409)
    const next = revision + 1
    this.ctx.storage.sql.exec('INSERT INTO backups (kind, revision, payload) VALUES (?, ?, ?) ON CONFLICT(kind) DO UPDATE SET revision = excluded.revision, payload = excluded.payload', kind, next, encoded)
    return json({ revision: next })
  }

  private async register(request: Request): Promise<Response> {
    const input = await body(request)
    if (!acceptablePin(input?.pin)) return error('invalid_pin', 400)
    if (this.identity) return error('username_taken', 409)
    const salt = random(16)
    const hash = await pinHash(input.pin, salt, this.env.PIN_PEPPER)
    const recoveryCode = random(24)
    const recoveryHash = await digest(`${this.env.PIN_PEPPER}:${recoveryCode}`)
    // Recheck after the async derivation to prevent concurrent registration.
    if (this.identity) return error('username_taken', 409)
    this.ctx.storage.sql.exec('INSERT INTO identity (id, username, pin_hash, salt, recovery_hash) VALUES (1, ?, ?, ?, ?)', request.headers.get('X-Vela-Normalized-Username'), hash, salt, recoveryHash)
    const session = await this.createSession(input.deviceName)
    return json({ ...session, recoveryCode }, 201)
  }

  private async login(request: Request): Promise<Response> {
    const input = await body(request)
    if (typeof input?.pin !== 'string' || !pinPattern.test(input.pin)) return error('invalid_credentials', 401)
    const initial = this.identity
    if (!initial) return error('invalid_credentials', 401)
    if (initial.locked_until > Date.now()) return error('temporarily_locked', 429)
    const hash = await pinHash(input.pin, initial.salt, this.env.PIN_PEPPER)
    const current = this.identity
    if (!current || current.locked_until > Date.now()) return error('temporarily_locked', 429)
    if (hash !== current.pin_hash) {
      const failures = current.failures + 1
      const lock = failures >= 5 ? Date.now() + Math.min(24 * 60, 15 * 2 ** Math.min(10, Math.floor((failures - 5) / 5))) * 60_000 : 0
      this.ctx.storage.sql.exec('UPDATE identity SET failures = ?, locked_until = ? WHERE id = 1', failures, lock)
      return error(lock ? 'temporarily_locked' : 'invalid_credentials', lock ? 429 : 401)
    }
    this.ctx.storage.sql.exec('UPDATE identity SET failures = 0, locked_until = 0 WHERE id = 1')
    return json(await this.createSession(input.deviceName))
  }

  private async recover(request: Request): Promise<Response> {
    const input = await body(request)
    if (typeof input?.recoveryCode !== 'string' || !/^[A-Za-z0-9_-]{32}$/.test(input.recoveryCode) || !acceptablePin(input.pin)) return error('invalid_recovery', 401)
    const current = this.identity
    if (!current || current.recovery_locked_until > Date.now()) return error('invalid_recovery', 401)
    const recoveryHash = await digest(`${this.env.PIN_PEPPER}:${input.recoveryCode}`)
    if (recoveryHash !== current.recovery_hash) {
      const failures = current.recovery_failures + 1
      const lock = failures >= 5 ? Date.now() + 15 * 60_000 : 0
      this.ctx.storage.sql.exec('UPDATE identity SET recovery_failures = ?, recovery_locked_until = ? WHERE id = 1', failures, lock)
      return error('invalid_recovery', 401)
    }
    const salt = random(16)
    const hash = await pinHash(input.pin, salt, this.env.PIN_PEPPER)
    const replacement = random(24)
    const replacementHash = await digest(`${this.env.PIN_PEPPER}:${replacement}`)
    // Recovery is single use; invalidate every old device session.
    if (this.identity?.recovery_hash !== current.recovery_hash) return error('invalid_recovery', 401)
    this.ctx.storage.sql.exec('UPDATE identity SET pin_hash = ?, salt = ?, recovery_hash = ?, failures = 0, locked_until = 0, recovery_failures = 0, recovery_locked_until = 0 WHERE id = 1', hash, salt, replacementHash)
    this.ctx.storage.sql.exec('DELETE FROM sessions')
    const session = await this.createSession(input.deviceName)
    return json({ ...session, recoveryCode: replacement })
  }
}
