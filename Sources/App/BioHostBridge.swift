import Foundation

/// 调用 bundle 内的 BioHost 二进制执行子命令
enum BioHostBridge {
    static func hostURL() -> URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("BioHost")
    }

    @discardableResult
    static func run(_ subcommand: String, arguments: [String] = [],
                    stdin: String? = nil) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let hostURL = hostURL() else {
            throw BridgeError.hostNotFound
        }
        let process = Process()
        process.executableURL = hostURL
        process.arguments = [subcommand] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdin = stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    enum BridgeError: Error, CustomStringConvertible {
        case hostNotFound

        var description: String {
            switch self {
            case .hostNotFound:
                return "未找到 BioHost 二进制"
            }
        }
    }
}
