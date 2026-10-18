// Wire protocol shared with the iOS app (Services/Link). Every frame is a
// 4-byte big-endian length followed by the payload. The handshake frames are
// plain JSON; everything after `hello-ok` is ChaCha20-Poly1305 encrypted.
// Keep this file and ios/.../Services/Link/LinkProtocol.swift in step.

export const LINK_SERVICE_TYPE = 'vixscr' // Bonjour: _vixscr._tcp
export const LINK_VERSION = 1
export const LINK_PORT = 47862
export const PAIRING_CODE_TTL_MS = 5 * 60_000

export interface PairedDevice {
  deviceId: string
  name: string
  syncEnabled: boolean
  autoReconnect: boolean
  pairedAt: number
  lastSeen: number | null
  lastSync: number | null
  connected: boolean
}

export interface LinkStatus {
  deskId: string
  deskName: string
  listening: boolean
  port: number
  addresses: string[]
  pairing: { qr: string; link: string; expiresAt: number } | null
  devices: PairedDevice[]
  error: string | null
}

/** Live playback snapshot the desktop sends to connected phones. */
export interface RemoteState {
  rev: number
  open: boolean
  session: string
  kind: 'tmdb' | 'anime'
  title: string
  subtitle: string | null
  poster: string | null
  itemKey: string | null
  season: number | null
  episode: number | null
  animeEpisode: string | null
  mode: 'idle' | 'loading' | 'native' | 'embed' | 'error'
  playing: boolean
  position: number
  duration: number
  /** Whether the current player reports time and accepts transport control. */
  controllable: boolean
  servers: string[]
  serverIndex: number
  sources: { name: string; audio: string | null; quality: string | null }[]
  sourceIndex: number
  hasNext: boolean
  status: string | null
  error: string | null
}

export type RemoteCommand =
  | { action: 'play-tmdb'; item: unknown; season?: number; episode?: number; episodeTitle?: string | null; server?: string }
  | { action: 'play-anime'; item: unknown; slug: string; episode: string; server?: string }
  | { action: 'toggle' | 'play' | 'pause' | 'next' | 'stop' }
  | { action: 'seek'; to: number }
  | { action: 'skip'; by: number }
  | { action: 'server'; name: string; index?: number }
  | { action: 'source'; index: number }

export type LinkEvent =
  | { type: 'status'; status: LinkStatus }
  | { type: 'message'; deviceId: string; msg: Record<string, unknown> }
  | { type: 'pair-request'; name: string }
  | { type: 'paired'; deviceId: string; name: string }
  | { type: 'connected'; deviceId: string }
  | { type: 'action'; action: 'sync-now' | 'fresh-copy-to' | 'fresh-copy-from'; deviceId: string }
