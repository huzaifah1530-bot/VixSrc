import { app, safeStorage } from 'electron'
import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { AccountReply } from '@shared/account'

const endpoint = 'https://vela-account.huzaifah1530.workers.dev/v1/'
interface Session { username: string; token: string; accountKey: string }
const sessionPath = () => join(app.getPath('userData'), 'cloud-account.bin')
let session: Session | null = null

function load(): Session | null {
  if (session) return session
  try {
    if (!safeStorage.isEncryptionAvailable() || !existsSync(sessionPath())) return null
    session = JSON.parse(safeStorage.decryptString(readFileSync(sessionPath()))) as Session
    return session
  } catch { return null }
}

function save(value: Session | null) {
  if (value && !safeStorage.isEncryptionAvailable()) throw new Error('Secure account storage is unavailable on this PC.')
  if (value) writeFileSync(sessionPath(), safeStorage.encryptString(JSON.stringify(value)))
  else if (existsSync(sessionPath())) unlinkSync(sessionPath())
  session = value
}

export const accountStatus = () => ({ username: load()?.username ?? null, accountKey: load()?.accountKey ?? null })

const routes: Record<string, [string, string, boolean]> = {
  register: ['register', 'POST', false], login: ['login', 'POST', false], recover: ['recover', 'POST', false],
  logout: ['session', 'DELETE', true], status: ['session', 'GET', true], devices: ['devices', 'GET', true],
  rename: ['username', 'POST', true], changePin: ['pin', 'POST', true], deleteAccount: ['account', 'DELETE', true],
  download: ['backup/desktop', 'GET', true], upload: ['backup/desktop', 'PUT', true],
  downloadShared: ['backup/shared', 'GET', true], uploadShared: ['backup/shared', 'PUT', true]
}

export async function accountCall(action: string, body?: Record<string, unknown>): Promise<AccountReply> {
  let route = routes[action]
  if (action.startsWith('revoke:') && /^[0-9a-f-]{36}$/.test(action.slice(7))) route = [`devices/${action.slice(7)}`, 'DELETE', true]
  if (!route) return { status: 400, data: { error: { code: 'invalid_request' } } }
  const [path, method, authenticated] = route
  const signedIn = load()
  if (authenticated && !signedIn) return { status: 401, data: { error: { code: 'unauthorized' } } }
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (body) headers['Content-Type'] = 'application/json'
  if (authenticated && signedIn) {
    headers['X-Vela-Username'] = signedIn.username
    headers['X-Vela-Account-Key'] = signedIn.accountKey
    headers.Authorization = `Bearer ${signedIn.token}`
  }
  let response: Response
  try {
    response = await fetch(endpoint + path, { method, headers, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15_000) })
  } catch { return { status: 503, data: { error: { code: 'unavailable' } } } }
  const data = await response.json().catch(() => ({})) as Record<string, any>
  if (response.ok && ['register', 'login', 'recover'].includes(action) && typeof data.token === 'string' && typeof data.accountKey === 'string' && typeof body?.username === 'string') {
    save({ username: body.username.trim().toLowerCase(), token: data.token, accountKey: data.accountKey })
  }
  if (response.ok && action === 'status' && typeof data.username === 'string' && signedIn && data.username !== signedIn.username) save({ ...signedIn, username: data.username })
  if (response.ok && action === 'rename' && typeof data.username === 'string' && signedIn) save({ ...signedIn, username: data.username })
  if (response.ok && ['logout', 'deleteAccount'].includes(action)) save(null)
  if (response.ok && action.startsWith('revoke:') && data.current === true) save(null)
  return { status: response.status, data }
}
