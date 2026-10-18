// Checks the iOS LinkCrypto against vectors produced by the desktop
// (kat.json). Compiled together with ios/.../Services/Link/LinkCrypto.swift.
import Foundation
import CryptoKit

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data {
    var out = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return out
}
var failures = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok  \(name)" : "FAIL \(name)"); if !ok { failures += 1 } }

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "kat.json"
let kat = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
func d(_ k: String) -> Data { unhex(kat[k] as! String) }

let phone = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d("phonePriv"))
let desk = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d("deskPriv"))
let phoneEph = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d("phoneEphPriv"))
let deskEph = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d("deskEphPriv"))
check("phone public key", phone.publicKey.rawRepresentation == d("phonePub"))
check("desk public key", desk.publicKey.rawRepresentation == d("deskPub"))
check("ephemeral public keys", phoneEph.publicKey.rawRepresentation == d("phoneEphPub") && deskEph.publicKey.rawRepresentation == d("deskEphPub"))

let deskPub = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: d("deskPub"))
let deskEphPub = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: d("deskEphPub"))
let staticShared = try! phone.sharedSecretFromKeyAgreement(with: deskPub)
let ephShared = try! phoneEph.sharedSecretFromKeyAgreement(with: deskEphPub)
check("static X25519", LinkCrypto.raw(staticShared) == d("staticShared"))
check("ephemeral X25519", LinkCrypto.raw(ephShared) == d("ephShared"))

let keys = LinkCrypto.sessionKeys(staticShared: staticShared, ephemeralShared: ephShared, phoneNonce: d("nPhone"), deskNonce: d("nDesk"))
check("HKDF phone→desk key", keys.send.withUnsafeBytes { Data($0) } == d("p2d"))
check("HKDF desk→phone key", keys.receive.withUnsafeBytes { Data($0) } == d("d2p"))

let proof = LinkCrypto.pairingProof(code: d("code"), phonePub: d("phonePub"), phoneEph: d("phoneEphPub"), phoneNonce: d("nPhone"))
check("pairing proof HMAC", proof == d("proof"))

let messages = kat["messages"] as! [String]
var cipher = LinkCipher(send: keys.send, receive: keys.receive)
let sent = messages.map { try! cipher.seal(Data($0.utf8)) }
check("ChaCha20-Poly1305 phone→desk bytes", sent.map(hex) == (kat["phoneToDesk"] as! [String]))
let received = (kat["deskToPhone"] as! [String]).map { try? cipher.open(unhex($0)) }
check("ChaCha20-Poly1305 desk→phone opens", received.map { $0.map { String(decoding: $0, as: UTF8.self) } } == messages)
var tampered = LinkCipher(send: keys.send, receive: keys.receive)
var bad = unhex((kat["deskToPhone"] as! [String])[0]); bad[0] ^= 1
check("tampered frame rejected", (try? tampered.open(bad)) == nil)

check("frame encoding", hex(LinkFrameReader.encode(Data(messages[0].utf8))) == kat["frame"] as! String)
var reader = LinkFrameReader()
let framed = LinkFrameReader.encode(Data("a".utf8)) + LinkFrameReader.encode(Data("bc".utf8))
let first = try! reader.push(framed.prefix(3)), rest = try! reader.push(framed.dropFirst(3))
check("frame reader handles split chunks", first.isEmpty && rest.map { String(decoding: $0, as: UTF8.self) } == ["a", "bc"])

let invite = PairingInvite(url: "vixscr://pair?d=abc&n=PC&k=\(Data(d("deskPub")).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))&c=\(d("code").base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))&h=192.168.1.2,10.0.0.5&p=47862")
check("QR invite parses", invite?.publicKey == d("deskPub") && invite?.code == d("code") && invite?.hosts.count == 2 && invite?.port == 47862)

print(failures == 0 ? "\nAll interop checks passed" : "\n\(failures) interop checks FAILED")
exit(failures == 0 ? 0 : 1)
