import CryptoKit
import XCTest

final class ProtocolTests: XCTestCase {
    // 由参考实现（Go，与 bw-bio-handler crypto.go 同算法）生成的互操作向量
    let aesKey = Data("0123456789abcdef0123456789abcdef".utf8)
    let aesIV = Data("0123456789abcdef".utf8)

    /// (明文, Go 参考实现的 AES-256-CBC+PKCS7 密文 base64)
    let goAESVectors: [(String, String)] = [
        ("hello", "MDEyMzQ1Njc4OWFiY2RlZlEHcOOCQ6s7MWKZEgsFwyA="),
        ("exactly16bytes!!", "MDEyMzQ1Njc4OWFiY2RlZuy0Di5DhlajKVsXtoRUAdpFV/UQ8BWycLtCLCwFWlf5"),
        ("the quick brown fox jumps over the lazy dog 中文字符",
         "MDEyMzQ1Njc4OWFiY2RlZjQdpkXuARTmPHHCFjG3RkKirvXgbn0FvQibZYycVU0iRlOUx9E/waaHMd64gNItZ4YACBLTNa57im1M7AXQw48="),
    ]

    func testAESDecryptMatchesGo() throws {
        for (plaintext, cipherB64) in goAESVectors {
            let ct = Data(base64Encoded: cipherB64)!
            let iv = ct.prefix(16)
            let body = ct.suffix(from: 16)
            let decrypted = try BrowserCrypto.decryptAESCBC(
                key: aesKey, iv: Data(iv), ciphertext: Data(body))
            XCTAssertEqual(String(data: decrypted, encoding: .utf8), plaintext)
        }
    }

    func testAESEncryptMatchesGo() throws {
        for (plaintext, cipherB64) in goAESVectors {
            let ct = Data(base64Encoded: cipherB64)!
            // Go 向量前 16 字节是 IV，比较密文体部分
            let body = ct.suffix(from: 16)
            let ciphertext = try BrowserCrypto.encryptAESCBC(
                key: aesKey, iv: aesIV, plaintext: Data(plaintext.utf8))
            XCTAssertEqual(ciphertext, Data(body))
        }
    }

    func testAESRoundtripViaEncryptedString() throws {
        let key = try BrowserCrypto.generateTransportKey()
        XCTAssertEqual(key.count, 64)
        let payload = Data(#"{"command":"getBiometricsStatusForUser","messageId":1}"#.utf8)
        let enc = try BrowserCrypto.encryptStringSymmetric(transportKey: key, plaintext: payload)
        XCTAssertEqual(enc.encryptionType, 2)
        XCTAssertNotNil(enc.mac)
        let decrypted = try BrowserCrypto.decryptStringSymmetric(key: key, encrypted: enc)
        XCTAssertEqual(decrypted, payload)
    }

    func testMacTamperDetection() throws {
        let key = try BrowserCrypto.generateTransportKey()
        let enc = try BrowserCrypto.encryptStringSymmetric(
            transportKey: key, plaintext: Data("hello".utf8))
        let tampered = EncryptedString(iv: enc.iv, mac: enc.mac, data: enc.data, encryptionType: 2)
        // 密文被篡改 → mac 校验失败
        var flipped = Array(tampered.data)
        flipped[0] = flipped[0] == "A" ? "B" : "A"
        let bad = EncryptedString(iv: enc.iv, mac: enc.mac, data: String(flipped), encryptionType: 2)
        XCTAssertThrowsError(try BrowserCrypto.decryptStringSymmetric(key: key, encrypted: bad))
        _ = tampered
    }

    func testHMACVector() throws {
        // 与 Go 标准库一致的 HMAC-SHA256 向量
        let macKey = Data("0123456789abcdef0123456789abcdef".utf8)
        let mac = BrowserCrypto.hmacSHA256(macKey: macKey, data: Data("hello".utf8))
        XCTAssertEqual(mac.base64EncodedString(), "22i0e2PCOX6seFAlscnCEDrgbCiZgjSng7PrZFPRrXA=")
    }

    func testEncryptedStringJSONShape() throws {
        let enc = EncryptedString(iv: "AAAA", mac: "MMMM", data: "BBBB", encryptionType: 2)
        let data = try JSONEncoder().encode(enc)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["encryptionType"] as? Int, 2)
        XCTAssertEqual(dict["iv"] as? String, "AAAA")
        XCTAssertEqual(dict["data"] as? String, "BBBB")
        XCTAssertEqual(dict["mac"] as? String, "MMMM")
        // 扩展解密时取的就是这个字符串，缺了它会在扩展侧抛异常
        XCTAssertEqual(dict["encryptedString"] as? String, "2.AAAA|BBBB|MMMM")
        XCTAssertEqual(
            EncryptedString(iv: "AAAA", data: "BBBB", encryptionType: 0).encryptedString,
            "0.AAAA|BBBB")
    }

    let goSPKI = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtvQNbQJRkklL0MGk0oXdQkBOUvXttdraR8D37FO3i1He8qN5IBpBrfIpXflrCJblo3/3OfciZ0bPeNJ8QpS66pkcw57nYbI6+AgiXXFND3iWfMFHVZ2G8GCGfssBKqoIUCupgj+9XJQhCXSN4ti+ZdETLj4WYdcA2kaVArrXDtZk69JqfFZt0S5aier3Vd68zfO4XSugoySsb7KqGh7NA4r5D1HUwl+TMWmA2PGx5fC3m+fbxZPpdPdRSN+sJsUDiblu63PG/mmT29K4DplZdvR+4g5tXDFXkgx+xaLCaNRlhWI/M1AlnPEpMuzK8UCpksOEYEKtRKZV2y1/J456CQIDAQAB"

    let goPEM = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAtvQNbQJRkklL0MGk0oXdQkBOUvXttdraR8D37FO3i1He8qN5
    IBpBrfIpXflrCJblo3/3OfciZ0bPeNJ8QpS66pkcw57nYbI6+AgiXXFND3iWfMFH
    VZ2G8GCGfssBKqoIUCupgj+9XJQhCXSN4ti+ZdETLj4WYdcA2kaVArrXDtZk69Jq
    fFZt0S5aier3Vd68zfO4XSugoySsb7KqGh7NA4r5D1HUwl+TMWmA2PGx5fC3m+fb
    xZPpdPdRSN+sJsUDiblu63PG/mmT29K4DplZdvR+4g5tXDFXkgx+xaLCaNRlhWI/
    M1AlnPEpMuzK8UCpksOEYEKtRKZV2y1/J456CQIDAQABAoIBABdQZ2uWSY3SQFKU
    cqwPOgBo0HJa+5Vak8lkClP34SJkZvxVn6hbIDaJ7wKWN7ELBa19r6QX3a76g5La
    g9I6QM2HgHZfSA4Xl9MmujZdK1xG2iqAuNXsspbsPgdnWDk3HMMWpU2/UKK9D660
    RyZ6x1yTNZYFfHWwX9/w8ak85Q3zRgTt20ZVDhqBhN/GLB7nT/0+x2qF4QQAS1sV
    IiCDV5Gtt7nZvWUmAGYBZgdSj7ATpw1BwhyMwRjYQj4/UK8qNTsT8DELpOhhKUP1
    lCj81kDNXUMYW/Lji3BfRNfWmRdhSLI/9LSSkMcQ6+h8qNP7/ZZ88xhtk6x0fa0+
    Rys+EHcCgYEA4z5oufUTRvwfMZeFU+BfoCOBYQkjHyPXM1CvbNdZh7DLa/DTXBI3
    PjG2zqcpKfsG7zAHj1oVVuf8Gp56c/rmCogSSGD9QQrHe9UkvlNRQJafYzQCJagy
    kMWw1fnBlQe9a9fqSH9DeJhms4QlWbX83EmVNy33XoXtYHbPF53ZmH8CgYEAzhrZ
    NwNtn6Ze5H1FEp7Rrfm1ISO2+4f/pit1SxijhOW0w6YmlMztwJtI0ac2f7azTuo8
    AGP9DuxFaCesUlGzR5+C+LcB0A4VsqcAH1NeEXBKn22wGsnhvOpI1OsaBpadMBnu
    Ig+1pAhGQdXvuevNUz2rYRgYgx1vjjTPzv3j6XcCgYBovluHW2+HSK8YLL9H6iQp
    rDP2hj+qGtsWzBoQETMzWEprdpX12m+cO04H8wUGVK7dkUXqzZsIc+XAX0wSKZPf
    Rtkmg444bL+GVLibAcxx+Pt+vno+4UhtcrIP7w9LokWtb9iNkhuHerfcBw0wTLJA
    16nvxUBAUXsY+6p5OEkUAQKBgQCoxBNZmNULBZBuSKVmueW4L+DBYh1TmekciDlj
    ZKmBCRcbndG5xpRoQr897U4TBeeNlv/K0hVFQvMSdmoEfiHvZA462qABXYcm4tiW
    zg0Y+nogUhEB3o2Zw74fmuOUwX+1A4abHYH+70eYYTYLZ6qZnsXWm4R22IOgTl5b
    gEo/wQKBgFfL8768ej5/jyjAibpqeu5R/+Yxh5LUdTGhAGsvWZYgWNR2L6Cpl9wh
    JfgEmUGj2JK9gKI5ttvM07SMkRtQZjAKsfM8pNL/v/iupkSKOuRxJMjakyBkhPRo
    PdYrEMKCmZjXAKJUUgbLh9X84g78oaAhxZauXgwR0SRyLpGzTzym
    -----END RSA PRIVATE KEY-----
    """

    let goOAEPCT = "YkjM5YHOor2V7PtvcwB6L82yghBDtkVFwtSORptTJyO+0YSa7jb9jHe0D2K1sbVU10IAn+Ql+aa/1Z4hghb1GmWtVsqMW7Z+7nqJ8vA54y1oc55zd95UMcgJqQdoXWQKcSxT42Q3J8Tn2GKq+sK7tV+C8TGkOEb+xZU/w6LPXyaAtl7ZAHy6W6UVqbIhEafYjSu9x6yG/Yi/t2yhNy+OV+SaMBFJBZumiZ4K72MHPjU0cQeAjjB7GgCu1bpuOkUMCjcJ3W4E09h5cgkU3GoeVYQI5MPqCkJdp2lbLx2ICeiMTccHeg6n8RVyfECxuyKzkhqVqmPAzS9ayA8kaNRy8g=="

    func testSPKIParse() throws {
        let key = try BrowserCrypto.rsaPublicKey(fromSPKIBase64: goSPKI)
        XCTAssertEqual(SecKeyGetBlockSize(key), 256) // RSA-2048
    }

    /// 用 Go 参考实现加密的 OAEP-SHA1 密文验证 Swift 侧私钥解密 —— 证明两侧 OAEP 语义一致
    func testOAEPDecryptGoCiphertext() throws {
        let pemBody = goPEM
            .split(separator: "\n")
            .filter { !$0.contains("-----") }
            .joined()
        let der = Data(base64Encoded: pemBody)!
        var error: Unmanaged<CFError>?
        let privateKey = SecKeyCreateWithData(
            der as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary,
            &error)
        XCTAssertNotNil(privateKey, String(describing: error?.takeRetainedValue()))

        let ct = Data(base64Encoded: goOAEPCT)!
        let plaintext = SecKeyCreateDecryptedData(
            privateKey!, .rsaEncryptionOAEPSHA1, ct as CFData, &error) as Data?
        XCTAssertNotNil(plaintext, String(describing: error?.takeRetainedValue()))
        XCTAssertEqual(String(data: plaintext!, encoding: .utf8),
                       "0123456789abcdef0123456789abcdef")
    }

    func testOAEPShieldRoundtrip() throws {
        let publicKey = try BrowserCrypto.rsaPublicKey(fromSPKIBase64: goSPKI)
        let message = try BrowserCrypto.generateTransportKey()
        let ciphertext = try BrowserCrypto.encryptOAEPSHA1(publicKey: publicKey, message: message)
        XCTAssertEqual(ciphertext.count, 256)
    }

    func testFrameRoundtrip() throws {
        let payload = Data(#"{"command":"connected","appId":"test"}"#.utf8)
        let streamData = NativeMessagingFrame.encode(payload) + NativeMessagingFrame.encode(payload)
        XCTAssertEqual(NativeMessagingFrame.encode(payload)[0], UInt8(payload.count & 0xFF)) // 小端首字节

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(streamData)
        pipe.fileHandleForWriting.closeFile()

        let first = try NativeMessagingFrame.read(from: pipe.fileHandleForReading)
        let second = try NativeMessagingFrame.read(from: pipe.fileHandleForReading)
        XCTAssertEqual(first, payload)
        XCTAssertEqual(second, payload)
    }

    func testIncomingMessageParsing() throws {
        let json = #"{"appId":"ext-id","message":{"command":"setupEncryption","publicKey":"abc"}}"#
        let msg = try JSONDecoder().decode(IncomingMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.appId, "ext-id")
        XCTAssertEqual(msg.message?.objectValue?["command"]?.stringValue, "setupEncryption")

        let encryptedJSON = #"{"appId":"ext-id","message":{"iv":"AAA","mac":"","data":"BBB","encryptionType":0}}"#
        let encMsg = try JSONDecoder().decode(IncomingMessage.self, from: Data(encryptedJSON.utf8))
        XCTAssertNil(encMsg.message?.objectValue?["command"])
    }

    func testOutgoingMessageOmitsNilFields() throws {
        let msg = OutgoingMessage(command: "connected", appId: "host-id")
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["command"] as? String, "connected")
        XCTAssertNil(dict["sharedSecret"])
        XCTAssertNil(dict["message"])
    }

    // MARK: - Bitwarden SDK IPC（Noise 通道）

    private func data(hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// 握手向量：由 Rust snow 0.10（与 Bitwarden 扩展内置的 ipc 实现同款）验证——
    /// 发起方临时私钥固定为 0x11*32，响应方为 0x22*32，snow 能成功读出这条 HandshakeFinish。
    func testNoiseResponderMatchesSnowVector() throws {
        let startFrame = data(hex: "040217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4"
            + "ed194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794")
        XCTAssertEqual(startFrame.count, 65)

        let privateKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32))
        let (finish, responder) = try NoiseNN.Responder.respond(
            startFrame: startFrame, ephemeralPrivate: privateKey)

        XCTAssertEqual(finish.count, 81) // 65 字节公钥 + 16 字节 tag
        XCTAssertEqual(hex(finish),
            "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e4"
            + "73fddb6755f05bd507c3c533fce9c91285548b16c5c22cf3c39251a21d25adcca4")
        XCTAssertEqual(hex(responder.receiveKey),
            "e12fac68aecf624b9b3bb6a4dd96a63e39fff509042d4f17c7857a8fc1d30bd0")
        XCTAssertEqual(hex(responder.sendKey),
            "4a15f70304b93f88acc684be7054cdddfe9603da073403247104fcfcf1edd312")
    }

    /// Noise 的 HKDF 就是 RFC 5869（salt 为空、info 为空）的展开，用公开向量核对
    func testNoiseHKDFMatchesRFC5869Case3() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let outputs = NoiseNN.hkdf(chainingKey: Data(), input: ikm, outputCount: 2)
        // RFC 5869 用例 3 的 L=42，即 T(1) 全长 + T(2) 前 10 字节
        XCTAssertEqual(hex((outputs[0] + outputs[1]).prefix(42)),
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
    }

    /// 应答必须是 forwarded 信封并带 originalSource，否则扩展会按 source=DesktopMain 丢弃
    func testSdkIpcEnvelopeUsesForwardedShape() throws {
        let envelope = SdkIpcEnvelope(
            payload: [1, 2, 3], topic: "RpcResponseMessage", endpoint: "DesktopRenderer")
        let dict = try JSONSerialization.jsonObject(with: envelope.encoded()) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "forwarded-bitwarden-ipc-message")
        XCTAssertEqual(dict["originalSource"] as? String, "DesktopRenderer")
        let message = dict["message"] as! [String: Any]
        XCTAssertEqual(message["payload"] as? [Int], [1, 2, 3])
        XCTAssertEqual(message["topic"] as? String, "RpcResponseMessage")
    }

    func testSdkIpcEnvelopeParseKeepsDestination() {
        let json = #"{"type":"bitwarden-ipc-message","message":{"destination":"DesktopRenderer","payload":[161,110],"topic":null}}"#
        let envelope = SdkIpcEnvelope.parse(data: Data(json.utf8))

        XCTAssertEqual(envelope?.endpoint, "DesktopRenderer")
        XCTAssertEqual(envelope?.payload, [161, 110])
        XCTAssertNil(envelope?.topic)
        XCTAssertNil(SdkIpcEnvelope.parse(data: Data(#"{"command":"connected"}"#.utf8)))
    }
}
