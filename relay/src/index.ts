// Vela Watch Together relay. One Durable Object per party room.
//
// The relay never sees what anyone is watching: every payload is encrypted
// on the devices with a key that only lives in the invite link (after the
// '#', which browsers never send to a server). The relay only knows opaque
// peer ids and forwards blobs.
//
// Kept cheap for the Workers Free plan:
//  • WebSocket Hibernation API — an idle room costs no duration.
//  • "ping" is answered by setWebSocketAutoResponse, which doesn't wake
//    the room or count as a request.
//  • The latest timeline ("keep") blob is cached in memory/storage so late
//    joiners get it immediately without asking anyone.

export interface Env {
  ROOMS: DurableObjectNamespace
}

const MAX_PEERS = 500
const MAX_MESSAGE = 16 * 1024
const ROOM_ID = /^[A-Za-z0-9_-]{8,32}$/
const PEER_ID = /^[A-Za-z0-9_-]{6,40}$/

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url)
    const parts = url.pathname.split('/').filter(Boolean)

    // wss://…/room/<id>?peer=<peerId>
    if (parts[0] === 'room' && parts[1] && ROOM_ID.test(parts[1])) {
      if (req.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return new Response('Expected WebSocket', { status: 426 })
      const peer = url.searchParams.get('peer') ?? ''
      if (!PEER_ID.test(peer)) return new Response('Bad peer id', { status: 400 })
      const secret = url.searchParams.get('s') ?? ''
      if (secret.length < 16 || secret.length > 128) return new Response('Bad peer secret', { status: 400 })
      return env.ROOMS.get(env.ROOMS.idFromName(parts[1])).fetch(req)
    }

    // https://…/p/<id>#<key> — invite link opened in a browser.
    if (parts[0] === 'p' && parts[1] && ROOM_ID.test(parts[1])) return invitePage(parts[1])

    if (url.pathname === '/') return new Response('Vela Watch Together relay', { headers: { 'content-type': 'text/plain' } })
    return new Response('Not found', { status: 404 })
  }
}

interface Attachment { peer: string; joined: number }

export class Room implements DurableObject {
  private keep: string | null = null
  private loaded = false

  constructor(private state: DurableObjectState) {
    // Keep-alive pings never wake the room.
    state.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'))
  }

  private peers(): { ws: WebSocket; a: Attachment }[] {
    return this.state.getWebSockets().flatMap(ws => {
      const a = ws.deserializeAttachment() as Attachment | null
      return a ? [{ ws, a }] : []
    })
  }

  private async loadKeep() {
    if (this.loaded) return
    this.keep = (await this.state.storage.get<string>('keep')) ?? null
    this.loaded = true
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url)
    const peer = url.searchParams.get('peer')!
    const existing = this.peers()
    if (existing.length >= MAX_PEERS) return new Response('Room is full', { status: 429 })
    await this.loadKeep()

    // A peer id belongs to whoever first used it in this room: later
    // connections must present the same secret. Stops anyone with the link
    // from taking over someone else's id (e.g. the host's) to send as them.
    const digest = await sha256(url.searchParams.get('s')!)
    const known = await this.state.storage.get<string>('p:' + peer)
    if (known && known !== digest) return new Response('Peer id taken', { status: 403 })
    if (!known) await this.state.storage.put('p:' + peer, digest)

    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    // One socket per peer id (a reconnect replaces the old one).
    for (const p of existing) if (p.a.peer === peer) { try { p.ws.close(4000, 'replaced') } catch { /* gone */ } }
    this.state.acceptWebSocket(server)
    server.serializeAttachment({ peer, joined: Date.now() } satisfies Attachment)

    const others = existing.filter(p => p.a.peer !== peer).map(p => ({ peer: p.a.peer, joined: p.a.joined }))
    server.send(JSON.stringify({ sys: 'welcome', you: peer, peers: others, keep: this.keep, now: Date.now() }))
    this.broadcast(JSON.stringify({ sys: 'join', peer, joined: Date.now() }), server)
    return new Response(null, { status: 101, webSocket: client })
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    if (typeof raw !== 'string' || raw.length > MAX_MESSAGE) return
    const from = (ws.deserializeAttachment() as Attachment | null)?.peer
    if (!from) return
    let msg: { d?: unknown; to?: unknown; keep?: unknown; t?: unknown }
    try { msg = JSON.parse(raw) } catch { return }

    // Clock sync: echo the server time so clients can line up timelines.
    if (msg.t === 'time') { ws.send(JSON.stringify({ sys: 'time', now: Date.now(), echo: (msg as { c?: unknown }).c ?? null })); return }
    if (typeof msg.d !== 'string') return

    const out = JSON.stringify({ from, d: msg.d })
    if (msg.keep === true) {
      await this.loadKeep()
      this.keep = out
      await this.state.storage.put('keep', out)
    }
    if (typeof msg.to === 'string') {
      for (const p of this.peers()) if (p.a.peer === msg.to) p.ws.send(out)
    } else {
      this.broadcast(out, ws)
    }
  }

  async webSocketClose(ws: WebSocket, code: number) {
    // Finish the close handshake, or the client sits in "closing" forever.
    try { ws.close(code === 1005 || code === 1006 ? 1000 : code, 'closed') } catch { /* already closed */ }
    this.left(ws)
  }
  async webSocketError(ws: WebSocket) { this.left(ws) }

  private async left(ws: WebSocket) {
    const peer = (ws.deserializeAttachment() as Attachment | null)?.peer
    if (!peer) return
    // A replaced socket for the same peer isn't a leave.
    if (this.peers().some(p => p.a.peer === peer && p.ws !== ws)) return
    this.broadcast(JSON.stringify({ sys: 'leave', peer }), ws)
    // Empty room: forget the cached timeline.
    if (this.peers().filter(p => p.ws !== ws).length === 0) {
      this.keep = null
      await this.state.storage.deleteAll()
    }
  }

  private broadcast(text: string, except?: WebSocket) {
    for (const p of this.peers()) {
      if (p.ws === except) continue
      try { p.ws.send(text) } catch { /* closing */ }
    }
  }
}

async function sha256(text: string): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return btoa(String.fromCharCode(...new Uint8Array(hash)))
}

function invitePage(room: string): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Join a Vela watch party</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#000;color:#fff;font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
.card{max-width:380px;padding:32px;border-radius:24px;background:linear-gradient(135deg,rgba(255,255,255,.16),rgba(255,255,255,.04));border:1px solid rgba(255,255,255,.18);text-align:center}
h1{margin:0 0 8px;font-size:26px;letter-spacing:-.04em}p{color:rgba(255,255,255,.62);line-height:1.5}
.btn{display:inline-block;margin:12px 4px 0;padding:12px 22px;border-radius:999px;background:#fff;color:#000;font:700 15px inherit;text-decoration:none;border:0;cursor:pointer}.btn.ghost{background:rgba(255,255,255,.12);color:#fff;border:1px solid rgba(255,255,255,.25)}</style></head>
<body><div class="card"><h1>Watch together</h1><p>You've been invited to a Vela watch party.</p>
<a class="btn" id="open" href="#">Open in Vela</a>
<button class="btn ghost" id="copy">Copy invite link</button>
<p style="font-size:13px">Needs Vela on your iPhone or PC.</p>
<p style="font-size:13px"><b>Using LiveContainer?</b> Tapping can't open apps inside it. Tap <b>Copy invite link</b>, open Vela, and tap <b>Paste</b> on the banner that appears (or Settings › Watch Together › Paste).</p></div>
<script>const l='vela://party/${room}'+location.hash;document.getElementById('open').href=l;
document.getElementById('copy').onclick=async e=>{try{await navigator.clipboard.writeText(location.href)}catch{const t=document.createElement('textarea');t.value=location.href;document.body.appendChild(t);t.select();document.execCommand('copy');t.remove()}e.target.textContent='Copied — now open Vela'};
location.href=l;</script></body></html>`
  return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } })
}
