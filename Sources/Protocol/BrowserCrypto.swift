import CommonCrypto
import CryptoKit
import Foundation
import Security

/// 协议所需的密码学原语：
/// - 传输密钥 64 字节（前 32 = AES-256 加密，后 32 = HMAC-SHA256），EncString type 2
/// - SPKI DER 解析 → RSA SecKey
/// - RSA-OAEP-SHA1 加密（握手时回传传输密钥）
public enum BrowserCrypto {
    public enum CryptoError: Error, CustomStringConvertible {
        case cryptStatus(Int32)
        case invalidKey
        case invalidData(String)
        case securityFailure(CFError?)
        case macMismatch

        public var description: String {
            switch self {
            case .cryptStatus(let s): return "CommonCrypto 错误码 \(s)"
            case .invalidKey: return "无效的密钥数据"
            case .invalidData(let why): return "无效的数据：\(why)"
            case .securityFailure(let err): return "Security 框架错误：\(String(describing: err))"
            case .macMismatch: return "HMAC 校验失败"
            }
        }
    }

    public static let transportKeyLength = 64 // 32 enc + 32 mac

    // MARK: - 随机数

    public static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw CryptoError.cryptStatus(status) }
        return data
    }

    /// 64 字节传输密钥（前 32 加密、后 32 HMAC）
    public static func generateTransportKey() throws -> Data {
        try randomBytes(transportKeyLength)
    }

    // MARK: - HMAC-SHA256

    public static func hmacSHA256(macKey: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: macKey)))
    }

    // MARK: - AES-256-CBC + PKCS7

    public static func encryptAESCBC(key: Data, iv: Data, plaintext: Data) throws -> Data {
        try ccCrypt(kCCEncrypt, key: key, iv: iv, input: plaintext)
    }

    public static func decryptAESCBC(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        try ccCrypt(kCCDecrypt, key: key, iv: iv, input: ciphertext)
    }

    /// 按新版 EncString（type 2，带 HMAC）加密
    public static func encryptStringSymmetric(transportKey: Data, plaintext: Data) throws -> EncryptedString {
        let encKey = transportKey.prefix(32)
        let macKey = transportKey.suffix(32)
        let iv = try randomBytes(kCCBlockSizeAES128)
        let ciphertext = try encryptAESCBC(key: Data(encKey), iv: iv, plaintext: plaintext)
        var macInput = iv
        macInput.append(ciphertext)
        let mac = hmacSHA256(macKey: Data(macKey), data: macInput)
        return EncryptedString(
            iv: iv.base64EncodedString(),
            mac: mac.base64EncodedString(),
            data: ciphertext.base64EncodedString(),
            encryptionType: 2
        )
    }

    /// 解密并校验 HMAC（type 2）；type 0（无 mac，旧协议）也兼容
    public static func decryptStringSymmetric(key: Data, encrypted: EncryptedString) throws -> Data {
        guard let iv = Data(base64Encoded: encrypted.iv),
              let ciphertext = Data(base64Encoded: encrypted.data) else {
            throw CryptoError.invalidData("base64 解码失败")
        }
        let encKey: Data
        let macKey: Data?
        if key.count == transportKeyLength {
            encKey = key.prefix(32)
            macKey = key.suffix(32)
        } else {
            encKey = key
            macKey = nil
        }

        if encrypted.encryptionType == 2 || (macKey != nil && encrypted.mac != nil) {
            guard let macB64 = encrypted.mac, let expected = Data(base64Encoded: macB64) else {
                throw CryptoError.macMismatch
            }
            var macInput = iv
            macInput.append(ciphertext)
            let actual = hmacSHA256(macKey: Data(macKey!), data: macInput)
            guard actual == expected else { throw CryptoError.macMismatch }
        }

        return try decryptAESCBC(key: encKey, iv: iv, ciphertext: ciphertext)
    }

    private static func ccCrypt(_ operation: Int, key: Data, iv: Data, input: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBuf in
            input.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(operation),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, input.count,
                            outBuf.baseAddress, outBuf.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cryptStatus(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }

    // MARK: - RSA / SPKI

    /// 把 base64(SPKI DER) 的 RSA 公钥解析为 SecKey。
    /// SecKeyCreateWithData 要求 PKCS1 格式，需要剥掉 SPKI 外层的 AlgorithmIdentifier。
    public static func rsaPublicKey(fromSPKIBase64 spkiBase64: String) throws -> SecKey {
        guard let spki = Data(base64Encoded: spkiBase64) else {
            throw CryptoError.invalidData("公钥 base64 解码失败")
        }
        return try rsaPublicKey(fromSPKI: spki)
    }

    public static func rsaPublicKey(fromSPKI spki: Data) throws -> SecKey {
        let outer = try readTLV(spki, at: 0)
        guard outer.tag == 0x30 else { throw CryptoError.invalidKey }
        var cursor = outer.contentStart

        // AlgorithmIdentifier SEQUENCE，跳过
        let alg = try readTLV(spki, at: cursor)
        guard alg.tag == 0x30 else { throw CryptoError.invalidKey }
        cursor = alg.end

        // BIT STRING：首个字节是未用位数（RSA 时为 0），其余是 PKCS1 RSAPublicKey
        let bitString = try readTLV(spki, at: cursor)
        guard bitString.tag == 0x03,
              bitString.contentEnd > bitString.contentStart,
              spki[bitString.contentStart] == 0 else { throw CryptoError.invalidKey }

        let pkcs1 = spki.subdata(
            in: (bitString.contentStart + 1)..<bitString.contentEnd)

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData,
                                             [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                              kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                             &error) else {
            throw CryptoError.securityFailure(error?.takeRetainedValue())
        }
        return key
    }

    /// RSA-OAEP-SHA1 加密（对应 Go 的 rsa.EncryptOAEP(sha1.New(), ...)）
    public static func encryptOAEPSHA1(publicKey: SecKey, message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(
            publicKey, .rsaEncryptionOAEPSHA1, message as CFData, &error) as Data? else {
            throw CryptoError.securityFailure(error?.takeRetainedValue())
        }
        return ciphertext
    }

    // MARK: - DER 辅助

    private struct TLV {
        let tag: UInt8
        let contentStart: Int
        let contentEnd: Int
        var end: Int { contentEnd }
    }

    private static func readTLV(_ data: Data, at offset: Int) throws -> TLV {
        guard offset + 2 <= data.count else { throw CryptoError.invalidKey }
        let tag = data[data.startIndex + offset]
        let firstLen = Int(data[data.startIndex + offset + 1])
        var length = firstLen
        var contentStart = offset + 2
        if firstLen & 0x80 != 0 {
            let byteCount = firstLen & 0x7F
            guard byteCount > 0, offset + 2 + byteCount <= data.count else {
                throw CryptoError.invalidKey
            }
            length = 0
            for i in 0..<byteCount {
                length = length << 8 | Int(data[data.startIndex + offset + 2 + i])
            }
            contentStart = offset + 2 + byteCount
        }
        guard contentStart + length <= data.count else { throw CryptoError.invalidKey }
        return TLV(tag: tag, contentStart: contentStart, contentEnd: contentStart + length)
    }
}
