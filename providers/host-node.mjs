// Runs bundle/nuvio-bundle.js in a bare `vm` context (no URL, Buffer, fetch,
// timers...) so tests see the same environment as JavaScriptCore on iOS.
// desktop/src/main/providers/nuvio.ts is the app's copy of this host.
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const utf8 = new TextDecoder('utf-8', { fatal: true })

export async function hostFetch(raw) {
  const req = JSON.parse(raw)
  const headers = new Headers()
  for (const [k, v] of req.headers ?? []) { try { headers.append(k, v) } catch { /* invalid header */ } }
  const res = await fetch(req.url, {
    method: req.method,
    headers,
    body: req.bodyBase64 != null ? Buffer.from(req.bodyBase64, 'base64') : req.body,
    redirect: req.redirect === 'manual' ? 'manual' : req.redirect === 'error' ? 'error' : 'follow',
    signal: AbortSignal.timeout(req.timeout || 20000)
  })
  const bytes = Buffer.from(await res.arrayBuffer())
  const pairs = []
  res.headers.forEach((v, k) => { if (k !== 'set-cookie') pairs.push([k, v]) })
  for (const c of res.headers.getSetCookie()) pairs.push(['set-cookie', c])
  const out = { status: res.status, statusText: res.statusText, url: res.url || req.url, redirected: res.redirected, headers: pairs }
  try { out.text = utf8.decode(bytes) } catch { out.base64 = bytes.toString('base64') }
  return JSON.stringify(out)
}

export function createRuntime(bundlePath, { log = () => {} } = {}) {
  const timers = new Map()
  let nextTimer = 1
  const host = {
    fetch: (raw, cb) => { hostFetch(raw).then(r => cb(null, r), e => cb(String(e?.cause?.message || e?.message || e), null)) },
    setTimeout: (fn, ms) => {
      const id = nextTimer++
      timers.set(id, setTimeout(() => { timers.delete(id); fn() }, ms))
      return id
    },
    clearTimeout: id => { clearTimeout(timers.get(id)); timers.delete(id) },
    log: (level, msg) => log(level, msg)
  }
  const context = vm.createContext({ __velaHost: host })
  vm.runInContext(readFileSync(bundlePath, 'utf8'), context, { filename: 'nuvio-bundle.js' })
  const api = context.__velaNuvio
  return {
    ids: () => [...api.ids()],
    run: (id, tmdbId, type, season, episode, timeoutMs = 45000) => new Promise((resolve, reject) => {
      api.run(id, String(tmdbId), type, season ?? null, episode ?? null, timeoutMs, (err, json) => {
        if (err) reject(new Error(err)); else resolve(JSON.parse(json))
      })
    })
  }
}
