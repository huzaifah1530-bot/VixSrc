// X25519 + HKDF-SHA256 + ChaCha20-Poly1305, byte-compatible with CryptoKit.
import {
  createHmac, createPrivateKey, createPublicKey,
  diffieHellman, generateKeyPairSync, hkdfSync, timingSafeEqual, type KeyObject
} from 'node:crypto'
import { chacha20poly1305 } from '@noble/ciphers/chacha.js'

export interface StaticKey { priv: KeyObject; pub: Buffer; d: Buffer }

export function generateStaticKey(): StaticKey {
  const { privateKey } = generateKeyPairSync('x25519')
  return fromPrivate(privateKey)
}

function fromPrivate(priv: KeyObject): StaticKey {
  const jwk = priv.export({ format: 'jwk' })
  return { priv, pub: Buffer.from(jwk.x!, 'base64url'), d: Buffer.from(jwk.d!, 'base64url') }
}

export function keyFromRaw(d: Buffer, x: Buffer): StaticKey {
  const priv = createPrivateKey({ key: { kty: 'OKP', crv: 'X25519', d: d.toString('base64url'), x: x.toString('base64url') }, format: 'jwk' })
  return fromPrivate(priv)
}

export function dh(priv: KeyObject, peerPub: Buffer): Buffer {
  if (peerPub.length !== 32) throw new Error('bad public key')
  const pub = createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: peerPub.toString('base64url') }, format: 'jwk' })
  return diffieHellman({ privateKey: priv, publicKey: pub })
}

/** Returns [phone→desktop key, desktop→phone key]. */
export function sessionKeys(staticShared: Buffer, ephemeralShared: Buffer, phoneNonce: Buffer, deskNonce: Buffer): [Buffer, Buffer] {
  const out = Buffer.from(hkdfSync('sha256', Buffer.concat([staticShared, ephemeralShared]), Buffer.concat([phoneNonce, deskNonce]), Buffer.from('vixscr-link-v1'), 64))
  return [out.subarray(0, 32), out.subarray(32)]
}

/** HMAC the phone sends on first pairing to prove it scanned the QR code. */
export function pairingProof(code: Buffer, phonePub: Buffer, phoneEph: Buffer, phoneNonce: Buffer): Buffer {
  return createHmac('sha256', code).update(Buffer.concat([Buffer.from('vixscr-pair'), phonePub, phoneEph, phoneNonce])).digest()
}

export function safeEqual(a: Buffer, b: Buffer) {
  return a.length === b.length && timingSafeEqual(a, b)
}

const nonce = (n: bigint) => { const b = Buffer.alloc(12); b.writeBigUInt64BE(n, 4); return b }

/** One direction-pair of counters. Counters never repeat within a session. */
export class SessionCipher {
  private sendN = 0n
  private recvN = 0n
  constructor(private sendKey: Buffer, private recvKey: Buffer) {}

  // Electron's BoringSSL doesn't expose chacha20-poly1305 through
  // createCipheriv, so the AEAD comes from @noble/ciphers (RFC 8439).
  // Output is ciphertext || 16-byte tag, the same layout as CryptoKit's
  // ChaChaPoly.SealedBox ciphertext + tag.
  seal(plain: Buffer): Buffer {
    return Buffer.from(chacha20poly1305(this.sendKey, nonce(this.sendN++)).encrypt(plain))
  }

  open(sealed: Buffer): Buffer {
    if (sealed.length < 16) throw new Error('short frame')
    return Buffer.from(chacha20poly1305(this.recvKey, nonce(this.recvN++)).decrypt(sealed))
  }
}

/** Splits a TCP byte stream into length-prefixed frames. */
export class FrameReader {
  private buf = Buffer.alloc(0)
  constructor(private max = 16 * 1024 * 1024) {}
  push(chunk: Buffer): Buffer[] {
    this.buf = Buffer.concat([this.buf, chunk])
    const out: Buffer[] = []
    while (this.buf.length >= 4) {
      const len = this.buf.readUInt32BE(0)
      if (len > this.max) throw new Error('frame too large')
      if (this.buf.length < 4 + len) break
      out.push(this.buf.subarray(4, 4 + len))
      this.buf = this.buf.subarray(4 + len)
    }
    return out
  }
}

export function frame(payload: Buffer): Buffer {
  const head = Buffer.alloc(4)
  head.writeUInt32BE(payload.length)
  return Buffer.concat([head, payload])
}
