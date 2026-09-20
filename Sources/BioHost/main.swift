import Foundation

let usage = """
用法：BioHost <子命令>

  serve                     运行 native messaging 协议主循环（浏览器 manifest 默认调用）
  store-key                 从 stdin 读两行：userId、加密密钥(base64)，写入 Keychain
  list-keys                 列出已存密钥的账户 ID
  remove-key <userId>       删除指定账户的密钥
  test-unlock <userId>      对指定账户做一次完整的生物识别验证读取
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "store-key":
    guard let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) else {
        fail("stdin 不是有效 UTF-8")
    }
    let lines = input.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard lines.count >= 2 else {
        fail("需要两行输入：userId、加密密钥(base64)")
    }
    let userId = lines[0].trimmingCharacters(in: .whitespaces)
    let keyB64 = lines[1].trimmingCharacters(in: .whitespaces)
    guard Data(base64Encoded: keyB64) != nil else {
        fail("加密密钥不是有效的 base64")
    }
    do {
        try SecretStore.store(userId: userId, keyB64: keyB64)
        print("OK")
    } catch {
        fail("写入失败：\(error)")
    }

case "list-keys":
    for userId in SecretStore.listUserIds() {
        print(userId)
    }

case "remove-key":
    guard args.count >= 2 else { fail("缺少 userId 参数") }
    SecretStore.remove(userId: args[1])
    print("OK")

case "test-unlock":
    guard args.count >= 2 else { fail("缺少 userId 参数") }
    do {
        let key = try SecretStore.read(userId: args[1])
        print("OK \(key.count) 字节")
    } catch {
        fail("验证失败：\(error)")
    }

case "--help", "-h":
    print(usage)

default:
    // 无参数（浏览器以 manifest.path 拉起时）或浏览器传入的扩展 origin 参数，都进入协议主循环
    Serve.run()
}
