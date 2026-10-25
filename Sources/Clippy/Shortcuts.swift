import Foundation

enum ShortcutError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let why): return why
        }
    }
}

/// Runs the user's Shortcuts through the `shortcuts` command-line tool.
enum ShortcutRunner {
    /// Names of the user's shortcuts, for the settings picker.
    static func list() async -> [String] {
        guard let output = try? await run("/usr/bin/shortcuts", ["list"]) else { return [] }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
    }

    /// Runs a shortcut with the prompt as text input and returns its text output, if any.
    static func run(_ name: String, input: String) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inURL = folder.appendingPathComponent("input.txt")
        let outURL = folder.appendingPathComponent("output.txt")
        try input.write(to: inURL, atomically: true, encoding: .utf8)

        _ = try await run("/usr/bin/shortcuts", ["run", name, "--input-path", inURL.path,
                                                 "--output-path", outURL.path, "--output-type", "public.plain-text"])
        let output = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command off the main thread; throws with its error output if it fails.
    private static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { p in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    var why = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if why.hasPrefix("Error: ") { why.removeFirst(7) }
                    continuation.resume(throwing: ShortcutError.failed(why.isEmpty ? "The shortcut failed." : why))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
