// Vela provider runtime.
//
// Gives the vendored Nuvio providers the environment they expect (fetch,
// URL, Buffer, atob, TextDecoder, timers, require('cheerio' | 'crypto-js'))
// on top of a bare JavaScript engine. The same bundle runs in a Node `vm`
// context on desktop and in JavaScriptCore on iOS, so a provider that works
// in `npm test` here behaves the same on both apps.
//
// The host must define `globalThis.__velaHost` before this script runs:
//   fetch(requestJson, cb(err, responseJson))  - real HTTP, any headers
//   setTimeout(cb, ms) -> id, clearTimeout(id)
//   log(level, message)
// Bodies cross the bridge as `text` (valid UTF-8) or `base64`.

import { Buffer } from 'buffer'
import cheerio from 'cheerio-without-node-native'
import CryptoJS from 'crypto-js'
import URLPolyfill from 'core-js-pure/actual/url/index.js'
import URLSearchParamsPolyfill from 'core-js-pure/actual/url-search-params/index.js'

const G = globalThis
const host = G.__velaHost
if (!host) throw new Error('Vela provider runtime: __velaHost is missing')

// ── Basic globals ──────────────────────────────────────────────────────
if (typeof G.URL === 'undefined') G.URL = URLPolyfill
if (typeof G.URLSearchParams === 'undefined') G.URLSearchParams = URLSearchParamsPolyfill
if (typeof G.Buffer === 'undefined') G.Buffer = Buffer
// Same globals the Nuvio app's QuickJS runtime sets (JsBindings.kt).
if (typeof G.global === 'undefined') G.global = G
if (typeof G.window === 'undefined') G.window = G
if (typeof G.self === 'undefined') G.self = G
if (typeof G.SCRAPER_SETTINGS === 'undefined') G.SCRAPER_SETTINGS = {}

const fmt = args => args.map(a => {
  if (typeof a === 'string') return a
  if (a instanceof Error) return a.stack || a.message
  try { return JSON.stringify(a) } catch { return String(a) }
}).join(' ')
G.console = {
  log: (...a) => host.log('log', fmt(a)),
  info: (...a) => host.log('info', fmt(a)),
  debug: (...a) => host.log('debug', fmt(a)),
  warn: (...a) => host.log('warn', fmt(a)),
  error: (...a) => host.log('error', fmt(a)),
  trace: (...a) => host.log('debug', fmt(a))
}

if (typeof G.setTimeout === 'undefined') {
  G.setTimeout = (fn, ms, ...args) => host.setTimeout(() => fn(...args), Math.max(0, Number(ms) || 0))
  G.clearTimeout = id => { if (id != null) host.clearTimeout(id) }
  const intervals = new Map()
  let nextInterval = 1
  G.setInterval = (fn, ms, ...args) => {
    const key = nextInterval++
    const tick = () => { intervals.set(key, G.setTimeout(tick, ms)); fn(...args) }
    intervals.set(key, G.setTimeout(tick, ms))
    return key
  }
  G.clearInterval = key => { G.clearTimeout(intervals.get(key)); intervals.delete(key) }
}
if (typeof G.queueMicrotask === 'undefined') G.queueMicrotask = fn => Promise.resolve().then(fn)

if (typeof G.atob === 'undefined') {
  G.atob = s => Buffer.from(String(s).replace(/[\s=]+/g, ''), 'base64').toString('latin1')
  G.btoa = s => {
    s = String(s)
    if (/[^\u0000-\u00ff]/.test(s)) throw new Error('btoa: string contains characters outside Latin-1')
    return Buffer.from(s, 'latin1').toString('base64')
  }
}

const toBytes = v => {
  if (v instanceof Uint8Array) return v
  if (v instanceof ArrayBuffer) return new Uint8Array(v)
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength)
  return new Uint8Array(0)
}
if (typeof G.TextEncoder === 'undefined') {
  G.TextEncoder = class TextEncoder {
    get encoding() { return 'utf-8' }
    encode(s = '') { const b = Buffer.from(String(s), 'utf8'); return new Uint8Array(b.buffer, b.byteOffset, b.length) }
  }
}
if (typeof G.TextDecoder === 'undefined') {
  G.TextDecoder = class TextDecoder {
    constructor(label = 'utf-8') { this.label = String(label).toLowerCase() }
    get encoding() { return this.label }
    decode(v) {
      if (v == null) return ''
      const b = toBytes(v)
      const enc = this.label === 'latin1' || this.label === 'iso-8859-1' ? 'latin1' : this.label.startsWith('utf-16') ? 'utf16le' : 'utf8'
      return Buffer.from(b.buffer, b.byteOffset, b.byteLength).toString(enc)
    }
  }
}

// ── AbortController ────────────────────────────────────────────────────
if (typeof G.AbortController === 'undefined') {
  class AbortSignal {
    constructor() { this.aborted = false; this.reason = undefined; this.onabort = null; this._l = [] }
    addEventListener(type, fn) { if (type === 'abort') this._l.push(fn) }
    removeEventListener(type, fn) { this._l = this._l.filter(f => f !== fn) }
    throwIfAborted() { if (this.aborted) throw this.reason }
    _abort(reason) {
      if (this.aborted) return
      this.aborted = true
      this.reason = reason ?? abortError()
      const ev = { type: 'abort', target: this }
      try { this.onabort && this.onabort(ev) } catch { /* ignore */ }
      for (const fn of this._l) { try { fn(ev) } catch { /* ignore */ } }
    }
    static timeout(ms) { const c = new AbortController(); G.setTimeout(() => c.abort(timeoutError()), ms); return c.signal }
    static abort(reason) { const c = new AbortController(); c.abort(reason); return c.signal }
  }
  class AbortController {
    constructor() { this.signal = new AbortSignal() }
    abort(reason) { this.signal._abort(reason) }
  }
  G.AbortController = AbortController
  G.AbortSignal = AbortSignal
}
function abortError() { const e = new Error('The operation was aborted.'); e.name = 'AbortError'; return e }
function timeoutError() { const e = new Error('The operation timed out.'); e.name = 'TimeoutError'; return e }

// ── fetch ──────────────────────────────────────────────────────────────
class Headers {
  constructor(init) {
    this._m = new Map()
    if (!init) return
    if (init instanceof Headers) init.forEach((v, k) => this.append(k, v))
    else if (Array.isArray(init)) init.forEach(([k, v]) => this.append(k, v))
    else if (typeof init === 'object') Object.keys(init).forEach(k => { if (init[k] != null) this.append(k, init[k]) })
  }
  append(k, v) {
    const key = String(k).toLowerCase()
    const list = this._m.get(key)
    if (list) list.push(String(v)); else this._m.set(key, [String(v)])
  }
  set(k, v) { this._m.set(String(k).toLowerCase(), [String(v)]) }
  get(k) {
    const list = this._m.get(String(k).toLowerCase())
    return list ? list.join(', ') : null
  }
  getSetCookie() { return (this._m.get('set-cookie') || []).slice() }
  has(k) { return this._m.has(String(k).toLowerCase()) }
  delete(k) { this._m.delete(String(k).toLowerCase()) }
  forEach(fn, self) { for (const [k, v] of this.entries()) fn.call(self, v, k, this) }
  *entries() { for (const k of [...this._m.keys()].sort()) yield [k, this.get(k)] }
  *keys() { for (const [k] of this.entries()) yield k }
  *values() { for (const [, v] of this.entries()) yield v }
  [Symbol.iterator]() { return this.entries() }
  /** Raw pairs for the host, keeping every Set-Cookie separate. */
  _pairs() { const out = []; this._m.forEach((list, k) => list.forEach(v => out.push([k, v]))); return out }
}

class Response {
  constructor(body, init = {}) {
    this.status = init.status ?? 200
    this.statusText = init.statusText ?? ''
    this.ok = this.status >= 200 && this.status < 300
    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers)
    this.url = init.url ?? ''
    this.redirected = !!init.redirected
    this.type = 'basic'
    this.bodyUsed = false
    this._text = typeof body === 'string' ? body : null
    this._b64 = init._b64 ?? null
    this._bytes = body instanceof Uint8Array ? body : null
  }
  _consume() { this.bodyUsed = true }
  _asText() {
    if (this._text != null) return this._text
    if (this._bytes) return Buffer.from(this._bytes.buffer, this._bytes.byteOffset, this._bytes.byteLength).toString('utf8')
    if (this._b64 != null) return Buffer.from(this._b64, 'base64').toString('utf8')
    return ''
  }
  _asBytes() {
    let b
    if (this._bytes) return this._bytes
    if (this._b64 != null) b = Buffer.from(this._b64, 'base64')
    else b = Buffer.from(this._text ?? '', 'utf8')
    return new Uint8Array(b.buffer, b.byteOffset, b.length)
  }
  text() { this._consume(); return Promise.resolve(this._asText()) }
  // Nuvio's runtime resolves null for empty/invalid JSON instead of throwing.
  json() {
    this._consume()
    const t = this._asText()
    if (!t) return Promise.resolve(null)
    try { return Promise.resolve(JSON.parse(t)) } catch { return Promise.resolve(null) }
  }
  arrayBuffer() {
    this._consume()
    const u = this._asBytes()
    return Promise.resolve(u.buffer.slice(u.byteOffset, u.byteOffset + u.byteLength))
  }
  blob() { return this.arrayBuffer().then(buf => ({ size: buf.byteLength, arrayBuffer: () => Promise.resolve(buf), text: () => Promise.resolve(Buffer.from(buf).toString('utf8')) })) }
  clone() {
    const r = new Response(this._bytes ?? this._text, { status: this.status, statusText: this.statusText, headers: this.headers, url: this.url, redirected: this.redirected, _b64: this._b64 })
    return r
  }
}

function encodeBody(body, headers) {
  if (body == null) return {}
  if (typeof body === 'string') return { body }
  if (body instanceof G.URLSearchParams) {
    if (!headers.has('content-type')) headers.set('content-type', 'application/x-www-form-urlencoded;charset=UTF-8')
    return { body: body.toString() }
  }
  if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
    const b = toBytes(body)
    return { bodyBase64: Buffer.from(b.buffer, b.byteOffset, b.byteLength).toString('base64') }
  }
  if (body && typeof body._velaForm === 'function') {
    const { text, type } = body._velaForm()
    if (!headers.has('content-type')) headers.set('content-type', type)
    return { body: text }
  }
  return { body: String(body) }
}

function fetchImpl(input, init = {}) {
  return new Promise((resolve, reject) => {
    const req = input && typeof input === 'object' && !(input instanceof G.URL) ? input : null
    const url = String(req ? req.url : input)
    const headers = new Headers(init.headers ?? req?.headers)
    // Nuvio's FetchBridge adds this when a provider sends no User-Agent.
    if (!headers.has('user-agent')) headers.set('user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
    const method = String(init.method ?? req?.method ?? 'GET').toUpperCase()
    const signal = init.signal ?? req?.signal
    if (signal?.aborted) { reject(signal.reason ?? abortError()); return }
    let payload
    try { payload = encodeBody(init.body ?? req?.body, headers) } catch (e) { reject(e); return }
    let done = false
    const finish = (fn, v) => { if (!done) { done = true; fn(v) } }
    signal?.addEventListener?.('abort', () => finish(reject, signal.reason ?? abortError()))
    const request = {
      url, method, headers: headers._pairs(), redirect: init.redirect ?? 'follow',
      timeout: Number(init.timeout) > 0 ? Number(init.timeout) : 20000, ...payload
    }
    host.fetch(JSON.stringify(request), (err, raw) => {
      // Like Nuvio's FetchBridge: network errors resolve as status 0.
      if (err) { finish(resolve, new Response('', { status: 0, statusText: String(err), url })); return }
      try {
        const r = JSON.parse(raw)
        const h = new Headers()
        for (const [k, v] of r.headers ?? []) h.append(k, v)
        finish(resolve, new Response(r.text ?? null, { status: r.status, statusText: r.statusText ?? '', headers: h, url: r.url ?? url, redirected: !!r.redirected, _b64: r.base64 ?? null }))
      } catch (e) { finish(reject, e) }
    })
  })
}

class FormData {
  constructor() { this._f = [] }
  append(k, v) { this._f.push([String(k), String(v)]) }
  set(k, v) { this._f = this._f.filter(([n]) => n !== k); this.append(k, v) }
  get(k) { return this._f.find(([n]) => n === k)?.[1] ?? null }
  _velaForm() {
    const boundary = '----VelaForm' + Math.random().toString(16).slice(2)
    const text = this._f.map(([k, v]) => `--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`).join('') + `--${boundary}--\r\n`
    return { text, type: `multipart/form-data; boundary=${boundary}` }
  }
}

G.fetch = fetchImpl
G.Headers = Headers
G.Response = Response
G.Request = class Request { constructor(url, init = {}) { Object.assign(this, init); this.url = String(url) } }
if (typeof G.FormData === 'undefined') G.FormData = FormData

// ── Module system for providers ────────────────────────────────────────
const modules = {
  'cheerio-without-node-native': cheerio,
  cheerio,
  'crypto-js': CryptoJS,
  buffer: { Buffer },
  url: { URL: G.URL, URLSearchParams: G.URLSearchParams }
}
function requireShim(name) {
  if (Object.prototype.hasOwnProperty.call(modules, name)) return modules[name]
  throw new Error(`Module '${name}' is not available in Vela`)
}
const processShim = { env: {}, platform: 'vela', version: 'v20.0.0', nextTick: (fn, ...a) => Promise.resolve().then(() => fn(...a)) }

const factories = {}
const loaded = {}
const loadErrors = {}

function load(id) {
  if (loaded[id]) return loaded[id]
  if (loadErrors[id]) throw loadErrors[id]
  const factory = factories[id]
  if (!factory) throw new Error(`Unknown provider '${id}'`)
  const module = { exports: {} }
  try {
    factory.call(G, module, module.exports, requireShim, G, processShim)
  } catch (e) {
    loadErrors[id] = e
    throw e
  }
  const exp = module.exports
  if (!exp || typeof exp.getStreams !== 'function') {
    loadErrors[id] = new Error(`Provider '${id}' does not export getStreams`)
    throw loadErrors[id]
  }
  return (loaded[id] = exp)
}

const str = v => (typeof v === 'string' ? v : v == null ? '' : String(v))
const httpUrl = v => typeof v === 'string' && /^https?:\/\//i.test(v.trim())
function cleanHeaders(h) {
  const out = {}
  if (!h || typeof h !== 'object') return out
  for (const k of Object.keys(h)) if (h[k] != null && h[k] !== '') out[k] = str(h[k])
  return out
}

/** Normalises whatever a provider returned into a predictable list. */
function normalize(list) {
  if (!Array.isArray(list)) return []
  const seen = new Set()
  const out = []
  for (const s of list) {
    if (!s || !httpUrl(s.url) || seen.has(s.url)) continue
    seen.add(s.url)
    out.push({
      name: str(s.name).slice(0, 200),
      title: str(s.title).slice(0, 500),
      url: s.url.trim(),
      quality: str(s.quality).slice(0, 40),
      size: str(s.size).slice(0, 40),
      headers: cleanHeaders(s.headers),
      subtitles: Array.isArray(s.subtitles)
        ? s.subtitles.filter(t => t && httpUrl(t.url)).map(t => ({
            url: t.url.trim(), name: str(t.name || t.label || t.lang || t.language).slice(0, 80),
            language: str(t.language || t.lang).slice(0, 20), headers: cleanHeaders(t.headers)
          }))
        : []
    })
  }
  return out
}

G.__velaNuvio = {
  register(id, factory) { factories[id] = factory },
  ids() { return Object.keys(factories) },
  /** cb(error, streamsJson). Never throws; never calls cb twice. */
  run(id, tmdbId, mediaType, season, episode, timeoutMs, cb) {
    let done = false
    const finish = (err, value) => { if (done) return; done = true; G.clearTimeout(timer); cb(err, value) }
    const timer = G.setTimeout(() => finish('Timed out', null), Number(timeoutMs) > 0 ? Number(timeoutMs) : 45000)
    try {
      G.SCRAPER_ID = id
      const mod = load(id)
      // Nuvio passes `undefined` (not null) for movies.
      const s = mediaType === 'tv' && season != null ? Number(season) : undefined
      const e = mediaType === 'tv' && episode != null ? Number(episode) : undefined
      Promise.resolve(mod.getStreams(String(tmdbId), mediaType, s, e))
        .then(list => finish(null, JSON.stringify(normalize(list))))
        .catch(err => finish(str(err && err.message ? err.message : err) || 'Provider failed', null))
    } catch (err) {
      finish(str(err && err.message ? err.message : err) || 'Provider failed', null)
    }
  }
}
