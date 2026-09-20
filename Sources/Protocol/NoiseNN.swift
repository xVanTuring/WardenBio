import CryptoKit
import Foundation

/// Noise_NN_P256_AESGCM_SHA256 的响应方实现（对齐 Rust snow crate 的行为）：
/// - 握手：msg1 = 发起方临时公钥（65 字节非压缩）；msg2 = 响应方临时公钥 + 空载荷密文 tag
/// - 传输：AES-256-GCM，nonce = 4 字节零 + u64 大端计数器（从 1 开始），AAD 为空，输出 = 密文 || tag
public enum NoiseNN {
    public enum NoiseError: Swift.Error, CustomStringConvertible {
        case invalidPublicKey
        case handshakeFailed(String)

        public var description: String {
            switch self {
            case .invalidPublicKey: return "无效的 P256 公钥"
            case .handshakeFailed(let why): return "Noise 握手失败：\(why)"
            }
        }
    }

    static let protocolName = "Noise_NN_P256_AESGCM_SHA256"

    // MARK: - 握手

    public struct Responder {
        let receiveKey: Data // i2r
        let sendKey: Data    // r2i

        /// 处理 HandshakeStart 的 noise_frame，返回 HandshakeFinish 的 noise_frame。
        /// `ephemeralPrivate` 只为测试固定临时密钥用，正常握手用随机密钥。
        public static func respond(
            startFrame: Data,
            ephemeralPrivate: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
        ) throws -> (finishFrame: Data, responder: Responder) {
            // InitializeSymmetric：协议名（27 字节）右侧补零到 32 字节作为 h0，ck = h0；
            // 随后 Initialize 会 MixHash(prologue)，本协议 prologue 为空 → h = SHA256(h0)
            var paddedName = Data(protocolName.utf8)
            paddedName.append(Data(repeating: 0, count: 32 - paddedName.count))
            var h = sha256(paddedName)
            var ck = paddedName

            // <- e：读发起方临时公钥（65 字节非压缩）并 MixHash。
            // msg1 的载荷此时无密钥、按明文发送，但 EncryptAndHash 仍要把载荷混进握手哈希
            // （本协议里它恒为空，即再取一次 SHA256），否则后续 AAD 对不上、tag 校验失败。
            guard startFrame.count >= 65, startFrame[startFrame.startIndex] == 0x04 else {
                throw NoiseError.invalidPublicKey
            }
            let initiatorPub = try P256.KeyAgreement.PublicKey(
                x963Representation: startFrame.prefix(65))
            h = sha256(h + startFrame.prefix(65))
            h = sha256(h + startFrame.dropFirst(65))

            // -> e：生成己方临时密钥，MixHash
            let responderPrivate = ephemeralPrivate
            let responderPub = responderPrivate.publicKey.x963Representation
            h = sha256(h + responderPub)

            // -> ee：MixKey 同时更新链式密钥与本轮加密密钥
            let shared = try responderPrivate.sharedSecretFromKeyAgreement(with: initiatorPub)
            let dh = shared.withUnsafeBytes { Data($0) } // 32 字节 x 坐标
            let keys = hkdf(chainingKey: ck, input: dh, outputCount: 2)
            ck = keys[0]
            let tempKey = keys[1]

            // EncryptAndHash(空载荷)：AAD 取当前握手哈希，nonce 0，输出 16 字节 tag
            let sealed = try aesGcmSeal(key: tempKey, nonceCounter: 0, aad: h, plaintext: Data())
            h = sha256(h + sealed)

            // Split：输入为空，用 MixKey 之后的链式密钥
            let split = hkdf(chainingKey: ck, input: Data(), outputCount: 2)
            let responder = Responder(receiveKey: split[0], sendKey: split[1])
            return (responderPub + sealed, responder)
        }
    }

    // MARK: - 传输

    public struct Transport {
        let sendKey: Data
        let receiveKey: Data
        var sendNonce: UInt64 = 0
        var receiveNonce: UInt64 = 0

        public init(responder: Responder) {
            self.sendKey = responder.sendKey
            self.receiveKey = responder.receiveKey
        }

        public mutating func encrypt(_ plaintext: Data) throws -> (sealed: Data, nonce: UInt64) {
            sendNonce += 1
            let sealed = try aesGcmSeal(
                key: sendKey, nonceCounter: sendNonce, aad: Data(), plaintext: plaintext)
            return (sealed, sendNonce)
        }

        public mutating func decrypt(_ ciphertext: Data, nonce: UInt64) throws -> Data {
            // 防重放：nonce 必须严格递增（允许跳过）
            guard nonce > receiveNonce else {
                throw NoiseError.handshakeFailed("nonce 重放")
            }
            let plaintext = try aesGcmOpen(
                key: receiveKey, nonceCounter: nonce, aad: Data(), sealed: ciphertext)
            receiveNonce = nonce
            return plaintext
        }
    }

    // MARK: - 原语

    /// Noise HKDF：使用 HMAC-SHA256 链式推导
    static func hkdf(chainingKey: Data, input: Data, outputCount: Int) -> [Data] {
        let temp = hmac(key: chainingKey, data: input)
        var outputs: [Data] = []
        var prev = Data()
        for i in 1...max(outputCount, 1) {
            var input = prev
            input.append(UInt8(i))
            let out = hmac(key: temp, data: input)
            outputs.append(out)
            prev = out
            if i >= outputCount { break }
        }
        return outputs
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// snow 默认 AES-GCM：nonce = 4 字节零 + u64 大端，输出 = 密文 || 16 字节 tag。
    /// AAD 由调用方给出：握手阶段的空载荷用握手哈希，传输帧用空。
    static func aesGcmSeal(key: Data, nonceCounter: UInt64, aad: Data, plaintext: Data) throws -> Data {
        var nonceBytes = Data(repeating: 0, count: 12)
        withUnsafeBytes(of: nonceCounter.bigEndian) { nonceBytes.replaceSubrange(4..<12, with: $0) }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: nonceBytes),
            authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }

    static func aesGcmOpen(key: Data, nonceCounter: UInt64, aad: Data, sealed: Data) throws -> Data {
        guard sealed.count > 16 else { throw NoiseError.handshakeFailed("密文过短") }
        var nonceBytes = Data(repeating: 0, count: 12)
        withUnsafeBytes(of: nonceCounter.bigEndian) { nonceBytes.replaceSubrange(4..<12, with: $0) }
        let ciphertext = sealed.prefix(sealed.count - 16)
        let tag = sealed.suffix(16)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceBytes),
            ciphertext: ciphertext,
            tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }
}
