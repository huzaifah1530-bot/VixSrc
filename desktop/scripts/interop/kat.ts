// Generates known-answer vectors from the desktop crypto so the Swift side
// can prove it produces identical bytes (run by .github/workflows/link-interop.yml).
// Run: npx esbuild scripts/interop/kat.ts --bundle --platform=node --outfile=scripts/interop/kat.cjs && node scripts/interop/kat.cjs > scripts/interop/kat.json
import { createHash } from 'node:crypto'
import { FrameReader, SessionCipher, dh, frame, keyFromRaw, pairingProof, sessionKeys } from '../../src/main/link/crypto'
import { generateKeyPairSync, createPrivateKey } from 'node:crypto'

// Deterministic private scalars; derive the public half via JWK round-trip.
const seed = (label: string) => createHash('sha256').update(label).digest()
function key(label: string) {
  const d = seed(label)
  // Import with a throwaway x, then re-export to get the real public key.
  const tmp = generateKeyPairSync('x25519').publicKey.export({ format: 'jwk' }).x!
  const priv = createPrivateKey({ key: { kty: 'OKP', crv: 'X25519', d: d.toString('base64url'), x: tmp }, format: 'jwk' })
  const { createPublicKey } = require('node:crypto') as typeof import('node:crypto')
  const x = Buffer.from(createPublicKey(priv).export({ format: 'jwk' }).x!, 'base64url')
  return keyFromRaw(d, x)
}

const phone = key('phone-static'), desk = key('desk-static'), phoneEph = key('phone-eph'), deskEph = key('desk-eph')
const nPhone = seed('n-phone').subarray(0, 16), nDesk = seed('n-desk').subarray(0, 16), code = seed('code').subarray(0, 16)

const staticShared = dh(phone.priv, desk.pub)
const ephShared = dh(phoneEph.priv, deskEph.pub)
const [p2d, d2p] = sessionKeys(staticShared, ephShared, nPhone, nDesk)
// Sanity: desktop side computes the same secrets.
if (!dh(desk.priv, phone.pub).equals(staticShared) || !dh(deskEph.priv, phoneEph.pub).equals(ephShared)) throw new Error('dh mismatch')

const phoneCipher = new SessionCipher(p2d, d2p) // phone sends with p2d
const msgs = ['{"t":"hello"}', '{"t":"cmd","id":"x","action":"toggle"}']
const phoneToDesk = msgs.map(m => phoneCipher.seal(Buffer.from(m)).toString('hex'))
const deskCipher = new SessionCipher(d2p, p2d)
const deskToPhone = msgs.map(m => deskCipher.seal(Buffer.from(m)).toString('hex'))
// Round-trip check in Node too.
const check = new SessionCipher(d2p, p2d)
phoneToDesk.forEach((h, i) => { if (check.open(Buffer.from(h, 'hex')).toString() !== msgs[i]) throw new Error('roundtrip') })
new FrameReader().push(frame(Buffer.from('x')))

const hex = (b: Buffer) => b.toString('hex')
console.log(JSON.stringify({
  phonePriv: hex(phone.d), phonePub: hex(phone.pub),
  deskPriv: hex(desk.d), deskPub: hex(desk.pub),
  phoneEphPriv: hex(phoneEph.d), phoneEphPub: hex(phoneEph.pub),
  deskEphPriv: hex(deskEph.d), deskEphPub: hex(deskEph.pub),
  nPhone: hex(nPhone), nDesk: hex(nDesk), code: hex(code),
  staticShared: hex(staticShared), ephShared: hex(ephShared),
  p2d: hex(p2d), d2p: hex(d2p),
  proof: hex(pairingProof(code, phone.pub, phoneEph.pub, nPhone)),
  messages: msgs, phoneToDesk, deskToPhone,
  frame: hex(frame(Buffer.from(msgs[0])))
}, null, 2))
