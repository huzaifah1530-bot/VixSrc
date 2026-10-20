// LAN listener for paired phones. Advertises _vixscr._tcp over Bonjour while
// the app is open, pairs with a QR code, and relays decrypted messages to the
// renderer. Pairing records live in userData, encrypted with safeStorage.
import { app, safeStorage } from 'electron'
import { createServer, type Server, type Socket } from 'node:net'
import { hostname, networkInterfaces } from 'node:os'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { randomBytes, randomUUID } from 'node:crypto'
import { Bonjour, type Service } from 'bonjour-service'
import QRCode from 'qrcode'
import type { LinkEvent, LinkStatus, PairedDevice } from '@shared/link'
import { LINK_PORT, LINK_SERVICE_TYPE, LINK_VERSION, PAIRING_CODE_TTL_MS } from '@shared/link'
import {
  FrameReader, SessionCipher, dh, frame, generateStaticKey, keyFromRaw, pairingProof, safeEqual, sessionKeys, type StaticKey
} from './crypto'

interface StoredPair extends Omit<PairedDevice, 'connected'> { pub: string }
interface Stored { deskId: string; d: string; x: string; pairs: StoredPair[] }

interface Conn {
  socket: Socket
  deviceId: string | null
  cipher: SessionCipher | null
  name: string
}

const storePath = () => join(app.getPath('userData'), 'link.dat')

function loadStore(): Stored {
  try {
    const raw = readFileSync(storePath())
    const json = safeStorage.isEncryptionAvailable() && raw[0] !== 0x7b ? safeStorage.decryptString(raw) : raw.toString('utf8')
    const s = JSON.parse(json) as Stored
    if (s.deskId && s.d && s.x && Array.isArray(s.pairs)) return s
  } catch { /* first run or unreadable: start fresh */ }
  const key = generateStaticKey()
  return { deskId: randomUUID(), d: key.d.toString('base64'), x: key.pub.toString('base64'), pairs: [] }
}

export class LinkServer {
  private store: Stored = loadStore()
  private key: StaticKey
  private server: Server | null = null
  private bonjour: Bonjour | null = null
  private service: Service | null = null
  private conns = new Set<Conn>()
  private pairingCode: { code: Buffer; expiresAt: number } | null = null
  private pairingQr: { qr: string; link: string } | null = null
  private port = 0
  private error: string | null = null

  constructor(private emit: (e: LinkEvent) => void) {
    this.key = keyFromRaw(Buffer.from(this.store.d, 'base64'), Buffer.from(this.store.x, 'base64'))
    if (!existsSync(storePath())) this.save()
  }

  private save() {
    const json = JSON.stringify(this.store)
    try {
      writeFileSync(storePath(), safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(json) : Buffer.from(json, 'utf8'))
    } catch (err) { console.error('link store save failed', err) }
  }

  get deskName() { return hostname() }

  start() {
    const listen = (port: number) => {
      const server = createServer(s => this.accept(s))
      server.on('error', (err: NodeJS.ErrnoException) => {
        if (err.code === 'EADDRINUSE' && port !== 0) { listen(0); return }
        this.error = err.message
        this.pushStatus()
      })
      server.listen(port, '0.0.0.0', () => {
        this.server = server
        this.port = (server.address() as { port: number }).port
        this.advertise()
        this.pushStatus()
      })
    }
    listen(LINK_PORT)
  }

  stop() {
    for (const c of this.conns) c.socket.destroy()
    this.service?.stop?.()
    this.bonjour?.destroy()
    this.server?.close()
  }

  private advertise(attempt = 1) {
    try {
      this.bonjour ??= new Bonjour({}, (err: unknown) => console.error('bonjour:', err))
      const base = `Vela on ${this.deskName}`.slice(0, 55)
      this.service = this.bonjour.publish({
        name: attempt === 1 ? base : `${base} (${attempt})`,
        type: LINK_SERVICE_TYPE,
        protocol: 'tcp',
        port: this.port,
        txt: { id: this.store.deskId, v: String(LINK_VERSION), n: this.deskName }
      })
      // Name taken (another PC with the same name, or a second copy): number it.
      this.service.on('error', (err: Error) => {
        if (attempt < 9 && /already in use/i.test(err.message)) this.advertise(attempt + 1)
        else { this.error = 'Bonjour advertising failed: ' + err.message; this.pushStatus() }
      })
    } catch (err) {
      this.error = 'Bonjour advertising failed: ' + (err as Error).message
    }
  }

  private addresses() {
    return Object.values(networkInterfaces()).flat()
      .filter(i => i && i.family === 'IPv4' && !i.internal)
      .map(i => i!.address)
  }

  // ── Status / settings ───────────────────────────────────────────────
  status(): LinkStatus {
    const live = new Set([...this.conns].filter(c => c.cipher && c.deviceId).map(c => c.deviceId!))
    if (this.pairingCode && this.pairingCode.expiresAt < Date.now()) { this.pairingCode = null; this.pairingQr = null }
    return {
      deskId: this.store.deskId,
      deskName: this.deskName,
      listening: !!this.server,
      port: this.port,
      addresses: this.addresses(),
      pairing: this.pairingCode && this.pairingQr ? { ...this.pairingQr, expiresAt: this.pairingCode.expiresAt } : null,
      devices: this.store.pairs.map(({ pub: _p, ...p }) => ({ ...p, connected: live.has(p.deviceId) })),
      error: this.error
    }
  }

  private pushStatus() { this.emit({ type: 'status', status: this.status() }) }

  async startPairing() {
    const code = randomBytes(16)
    this.pairingCode = { code, expiresAt: Date.now() + PAIRING_CODE_TTL_MS }
    const q = new URLSearchParams({
      d: this.store.deskId,
      n: this.deskName,
      k: Buffer.from(this.store.x, 'base64').toString('base64url'),
      c: code.toString('base64url'),
      h: this.addresses().join(','),
      p: String(this.port)
    })
    const link = `vixscr://pair?${q.toString()}`
    const qr = await QRCode.toDataURL(link, { margin: 1, width: 360, errorCorrectionLevel: 'M', color: { dark: '#000000', light: '#ffffff' } })
    this.pairingQr = { qr, link }
    this.pushStatus()
    return this.status()
  }

  cancelPairing() { this.pairingCode = null; this.pairingQr = null; this.pushStatus() }

  update(deviceId: string, patch: Partial<Pick<StoredPair, 'syncEnabled' | 'autoReconnect' | 'lastSync'>>, notifyPeer = true) {
    const p = this.store.pairs.find(x => x.deviceId === deviceId)
    if (!p) return
    if (typeof patch.syncEnabled === 'boolean') p.syncEnabled = patch.syncEnabled
    if (typeof patch.autoReconnect === 'boolean') p.autoReconnect = patch.autoReconnect
    if (typeof patch.lastSync === 'number') p.lastSync = patch.lastSync
    this.save()
    if (notifyPeer && typeof patch.syncEnabled === 'boolean') this.send(deviceId, { t: 'sync-config', enabled: p.syncEnabled })
    this.pushStatus()
  }

  disconnect(deviceId: string) {
    for (const c of this.conns) if (c.deviceId === deviceId) { this.sendTo(c, { t: 'bye' }); c.socket.end() }
  }

  forget(deviceId: string) {
    this.send(deviceId, { t: 'revoke' })
    for (const c of this.conns) if (c.deviceId === deviceId) setTimeout(() => c.socket.destroy(), 200)
    this.store.pairs = this.store.pairs.filter(p => p.deviceId !== deviceId)
    this.save()
    this.pushStatus()
  }

  isSyncEnabled(deviceId: string) { return !!this.store.pairs.find(p => p.deviceId === deviceId)?.syncEnabled }

  /** Sends an app message to one paired phone (or all when id is null). */
  send(deviceId: string | null, msg: Record<string, unknown>) {
    for (const c of this.conns) if (c.cipher && (deviceId === null || c.deviceId === deviceId)) this.sendTo(c, msg)
  }

  private sendTo(c: Conn, msg: Record<string, unknown>) {
    if (c.socket.destroyed) return
    const body = Buffer.from(JSON.stringify(msg), 'utf8')
    c.socket.write(frame(c.cipher ? c.cipher.seal(body) : body))
  }

  // ── Connections ─────────────────────────────────────────────────────
  private accept(socket: Socket) {
    const conn: Conn = { socket, deviceId: null, cipher: null, name: '' }
    this.conns.add(conn)
    socket.setNoDelay(true)
    socket.setKeepAlive(true, 15_000)
    const reader = new FrameReader()
    // Unauthenticated sockets get 10s to finish the handshake.
    const handshakeTimer = setTimeout(() => { if (!conn.cipher) socket.destroy() }, 10_000)

    socket.on('data', (chunk: Buffer) => {
      let frames: Buffer[]
      try { frames = reader.push(chunk) } catch { socket.destroy(); return }
      for (const f of frames) {
        try {
          if (conn.cipher) this.onMessage(conn, JSON.parse(conn.cipher.open(f).toString('utf8')))
          else this.onHandshake(conn, JSON.parse(f.toString('utf8')))
        } catch (err) {
          console.error('link frame rejected:', (err as Error).message)
          socket.destroy()
          return
        }
      }
    })
    const done = () => {
      clearTimeout(handshakeTimer)
      const wasLive = !!conn.cipher
      this.conns.delete(conn)
      if (wasLive && conn.deviceId) {
        const p = this.store.pairs.find(x => x.deviceId === conn.deviceId)
        if (p) { p.lastSeen = Date.now(); this.save() }
      }
      this.pushStatus()
    }
    socket.on('close', done)
    socket.on('error', () => socket.destroy())
  }

  private reject(conn: Conn, code: string) {
    this.sendTo(conn, { t: 'error', code })
    conn.socket.end()
  }

  private onHandshake(conn: Conn, m: Record<string, unknown>) {
    const str = (v: unknown, max = 200) => (typeof v === 'string' && v.length <= max ? v : null)
    if (m.t === 'pair-request') {
      // A phone found us over Bonjour and wants to pair: show the QR code.
      const name = str(m.name, 80) ?? 'iPhone'
      this.emit({ type: 'pair-request', name })
      this.sendTo(conn, { t: 'pair-shown', deskId: this.store.deskId, name: this.deskName })
      conn.socket.end()
      return
    }
    if (m.t !== 'hello' || m.v !== LINK_VERSION) { this.reject(conn, 'version'); return }
    const deviceId = str(m.deviceId, 64), name = str(m.name, 80) ?? 'iPhone'
    const pub = Buffer.from(str(m.pub, 64) ?? '', 'base64')
    const eph = Buffer.from(str(m.eph, 64) ?? '', 'base64')
    const nPhone = Buffer.from(str(m.nonce, 64) ?? '', 'base64')
    if (!deviceId || pub.length !== 32 || eph.length !== 32 || nPhone.length !== 16) { this.reject(conn, 'malformed'); return }
    if (m.deskId !== undefined && m.deskId !== this.store.deskId) { this.reject(conn, 'wrong-desktop'); return }

    let pair = this.store.pairs.find(p => p.deviceId === deviceId)
    let firstPairing = false
    if (pair) {
      if (!safeEqual(Buffer.from(pair.pub, 'base64'), pub)) { this.reject(conn, 'unpaired'); return }
      if (m.auto === true && !pair.autoReconnect) { this.reject(conn, 'auto-disabled'); return }
    } else {
      const proof = Buffer.from(str(m.proof, 64) ?? '', 'base64')
      const code = this.pairingCode
      if (!code || code.expiresAt < Date.now()) { this.reject(conn, proof.length ? 'code-expired' : 'unpaired'); return }
      if (!safeEqual(pairingProof(code.code, pub, eph, nPhone), proof)) { this.reject(conn, 'bad-proof'); return }
      this.pairingCode = null
      this.pairingQr = null
      pair = { deviceId, name, pub: pub.toString('base64'), syncEnabled: false, autoReconnect: true, pairedAt: Date.now(), lastSeen: Date.now(), lastSync: null }
      this.store.pairs.push(pair)
      firstPairing = true
    }
    pair.name = name
    pair.lastSeen = Date.now()
    this.save()

    // Static-static + ephemeral-ephemeral X25519, mixed through HKDF.
    const deskEph = generateStaticKey()
    const nDesk = randomBytes(16)
    const [p2d, d2p] = sessionKeys(dh(this.key.priv, pub), dh(deskEph.priv, eph), nPhone, nDesk)
    this.sendTo(conn, { t: 'hello-ok', deskId: this.store.deskId, name: this.deskName, eph: deskEph.pub.toString('base64'), nonce: nDesk.toString('base64') })

    // One live connection per phone.
    for (const c of this.conns) if (c !== conn && c.deviceId === deviceId) c.socket.destroy()
    conn.deviceId = deviceId
    conn.name = name
    conn.cipher = new SessionCipher(d2p, p2d)
    this.sendTo(conn, { t: 'welcome', firstPairing, syncEnabled: pair.syncEnabled, deskName: this.deskName, appVersion: app.getVersion() })
    if (firstPairing) this.emit({ type: 'paired', deviceId, name })
    // Older phones don't send their app version; treat that as unknown.
    this.emit({ type: 'connected', deviceId, name, appVersion: str(m.appVersion, 32) })
    this.pushStatus()
  }

  private onMessage(conn: Conn, m: Record<string, unknown>) {
    if (!conn.deviceId || typeof m.t !== 'string') return
    switch (m.t) {
      case 'ping': this.sendTo(conn, { t: 'pong' }); return
      case 'bye': conn.socket.end(); return
      case 'revoke':
        this.store.pairs = this.store.pairs.filter(p => p.deviceId !== conn.deviceId)
        this.save(); conn.socket.end(); this.pushStatus(); return
      case 'sync-config':
        if (typeof m.enabled === 'boolean') this.update(conn.deviceId, { syncEnabled: m.enabled }, false)
        return
      case 'set-auto':
        if (typeof m.enabled === 'boolean') this.update(conn.deviceId, { autoReconnect: m.enabled }, false)
        return
    }
    // Commands, sync and everything else go to the main window, which validates.
    this.emit({ type: 'message', deviceId: conn.deviceId, msg: m })
  }
}
