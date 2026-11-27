import Foundation

/// One provider from `meterkat detect --json`: whether this Mac has
/// credentials the companion can read. Never carries a secret.
struct DetectedProvider: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var found: Bool
    /// Where the credentials are, e.g. "macOS Keychain" or "~/.codex/auth.json".
    var source: String?
    /// What to do when they aren't found.
    var hint: String?
    var enabled: Bool
    /// Takes a key from `meterkat config set-key` (OpenRouter, Z.ai, DeepSeek, Copilot).
    var takesKey: Bool
    var savedKey: Bool
}

/// Runs the companion bundled in the app (Resources/meterkat.py, a copy of
/// companion/), so setup works before anything is installed. Config changes
/// go through its CLI, which writes the same config.json the service reads.
enum CompanionCLI {
    enum Failure: LocalizedError {
        case noPython
        case command(String)

        var errorDescription: String? {
            switch self {
            case .noPython: return "Python 3.9 or newer wasn't found. Install the Command Line Tools first."
            case .command(let message): return message
            }
        }
    }

    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private static var resources: URL { Bundle.main.resourceURL! }
    private static var script: URL { resources.appendingPathComponent("meterkat.py") }

    /// The companion version this app carries, from meterkat.py's VERSION line.
    static let bundledVersion: String? = {
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return nil }
        let prefix = "VERSION = \""
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(line.dropFirst(prefix.count).prefix { $0 != "\"" })
    }()

    /// True when `version` is older than the bundled companion.
    static func isOutdated(_ version: String?) -> Bool {
        guard let bundledVersion else { return false }
        guard let version else { return true }
        return bundledVersion.compare(version, options: .numeric) == .orderedDescending
    }

    // MARK: Python

    /// /usr/bin/python3 is only a stub that offers to install the Command
    /// Line Tools until they're installed, so it counts only once they are.
    static func findPython() async -> URL? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        if let tools = try? await run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"]), tools.status == 0 {
            candidates.insert("/usr/bin/python3", at: 0)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let check = "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"
            if let result = try? await run(URL(fileURLWithPath: path), ["-c", check]), result.status == 0 {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Opens Apple's installer for the Command Line Tools, which include Python 3.
    static func installDeveloperTools() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["--install"])
    }

    // MARK: Commands

    static func detect() async throws -> [DetectedProvider] {
        struct Response: Decodable { var providers: [DetectedProvider] }
        let output = try await meterkat(["detect", "--json"])
        do {
            return try JSONDecoder().decode(Response.self, from: Data(output.stdout.utf8)).providers
        } catch {
            throw Failure.command("Unexpected output from meterkat detect")
        }
    }

    static func setEnabled(_ enabled: Bool, provider: String) async throws {
        _ = try await meterkat(["config", enabled ? "enable" : "disable", provider])
    }

    /// The key goes in on stdin, so it never appears in a process list.
    static func saveKey(_ key: String, provider: String) async throws {
        _ = try await meterkat(["config", "set-key", provider], input: key + "\n")
    }

    static func deleteKey(provider: String) async throws {
        _ = try await meterkat(["config", "unset-key", provider])
    }

    /// Does what companion/install.sh does from a checkout: copies the
    /// companion to ~/.local/share/meterkat, links ~/.local/bin/meterkat, and
    /// (re)starts the service at login. Returns the installer's output.
    @discardableResult
    static func install() async throws -> String {
        guard let python = await findPython() else { throw Failure.noPython }
        // install.sh runs `python3` from PATH, so the one found here goes first.
        let path = python.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let output = try await run(URL(fileURLWithPath: "/bin/sh"),
                                   [resources.appendingPathComponent("install.sh").path],
                                   environment: ["PATH": path])
        let log = output.stdout + output.stderr
        guard output.status == 0 else {
            throw Failure.command(log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return log
    }

    private static func meterkat(_ arguments: [String], input: String? = nil) async throws -> Output {
        guard let python = await findPython() else { throw Failure.noPython }
        let output = try await run(python, [script.path] + arguments, input: input)
        guard output.status == 0 else {
            let message = (output.stderr.isEmpty ? output.stdout : output.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.command(message.isEmpty ? "meterkat \(arguments.first ?? "") failed" : message)
        }
        return output
    }

    // MARK: Process

    private static func run(_ executable: URL, _ arguments: [String], input: String? = nil,
                            environment: [String: String] = [:]) async throws -> Output {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            // Python must not write __pycache__ into the signed app bundle.
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env.merge(environment) { _, new in new }
            process.environment = env

            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let stdin = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin

            // stderr drains on its own so neither pipe can fill up and stall the process.
            let errorData = LockedData()
            stderr.fileHandleForReading.readabilityHandler = { errorData.append($0.availableData) }

            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stderr.fileHandleForReading.readabilityHandler = nil
            errorData.append(stderr.fileHandleForReading.readDataToEndOfFile())
            return Output(status: process.terminationStatus,
                          stdout: String(decoding: out, as: UTF8.self),
                          stderr: String(decoding: errorData.value, as: UTF8.self))
        }.value
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
