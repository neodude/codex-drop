import Foundation
import Darwin

enum ReceiverState: String { case stopped, starting, running, stopping, failed }
enum ReceiverError: Error, LocalizedError {
    case duplicate, externalReceiver, paused, resources, unsafeFile, storageMigration
    var errorDescription: String? {
        switch self {
        case .duplicate: "Codex Drop is already open. Use its menu-bar icon."
        case .externalReceiver: "Another receiver is running. Stop its existing launcher before starting Codex Drop."
        case .paused: "The project’s .receiver-paused flag is set. Remove it only when ready to resume."
        case .resources: "The bundled receiver or configured Python is missing. Rebuild Codex Drop."
        case .storageMigration: "Runtime storage could not be prepared. Close other Codex Drop receivers and inspect the old and Application Support data folders; pairing identities are never merged."
        case .unsafeFile: "Runtime storage must use private, regular files owned by your account."
        }
    }
}
struct ReceiverConfiguration {
    let project: URL
    let resources: URL
    let python: URL
    let data: URL
    static func prepareData(project: URL, resources: URL, python: URL) throws -> URL {
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Drop", isDirectory: true)
        let process = Process()
        process.executableURL = python
        process.arguments = [resources.appendingPathComponent("receiver/runtime_storage.py").path,
            "--legacy", project.appendingPathComponent("receiver-data").path,
            "--destination", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReceiverError.storageMigration }
        return destination
    }
    var log: URL { data.appendingPathComponent("codex-drop.log") }
    var pairing: URL { data.appendingPathComponent("pairing-code.txt") }
    var arguments: [String] { [resources.appendingPathComponent("receiver/lan_receiver.py").path, "--data-dir", data.path] }
}

final class PrivateFile {
    let descriptor: Int32
    init(_ url: URL, lock: Bool = false) throws {
        descriptor = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ReceiverError.unsafeFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else {
            close(descriptor); throw ReceiverError.unsafeFile
        }
        if lock && flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor); throw ReceiverError.duplicate
        }
    }
    deinit { close(descriptor) }
}

// Deliberately no forced termination or automatic restart: an in-flight Paste must settle.
final class ReceiverController {
    let configuration: ReceiverConfiguration
    private let appLock: PrivateFile
    private var logFile: PrivateFile?
    private var process: Process?
    private var startOffset: UInt64 = 0
    private var currentState: ReceiverState = .stopped
    private(set) var detail = "Receiver stopped"
    var isRunning: Bool { process?.isRunning == true }
    var state: ReceiverState { refresh(); return currentState }
    var isReady: Bool { state == .running }
    init(configuration: ReceiverConfiguration) throws {
        self.configuration = configuration
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: configuration.data.path, isDirectory: &isDirectory) {
            let attributes = try FileManager.default.attributesOfItem(atPath: configuration.data.path)
            guard isDirectory.boolValue, attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ReceiverError.unsafeFile }
        } else {
            try FileManager.default.createDirectory(at: configuration.data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(configuration.data.path, 0o700) == 0 else { throw ReceiverError.unsafeFile }
        appLock = try PrivateFile(configuration.data.appendingPathComponent("codex-drop-app.lock"), lock: true)
    }
    func start() throws {
        refresh()
        guard !isRunning else { return }
        if FileManager.default.fileExists(atPath: configuration.project.appendingPathComponent(".receiver-paused").path) { throw ReceiverError.paused }
        guard FileManager.default.isExecutableFile(atPath: configuration.python.path),
              FileManager.default.fileExists(atPath: configuration.arguments[0]) else { throw ReceiverError.resources }
        // Probe the backend's own advisory lock. It still rechecks atomically at startup.
        let receiverLock = try PrivateFile(configuration.data.appendingPathComponent("receiver.lock"))
        guard flock(receiverLock.descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ReceiverError.externalReceiver }
        flock(receiverLock.descriptor, LOCK_UN)
        let log = try PrivateFile(configuration.log)
        startOffset = UInt64(lseek(log.descriptor, 0, SEEK_END))
        let child = Process()
        child.executableURL = configuration.python
        child.arguments = configuration.arguments
        child.currentDirectoryURL = configuration.project
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_DROP_NATIVE_ROOT"] = configuration.resources.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        child.environment = environment
        let output = FileHandle(fileDescriptor: log.descriptor, closeOnDealloc: false)
        child.standardOutput = output; child.standardError = output
        child.standardInput = FileHandle.nullDevice
        do { try child.run() } catch {
            currentState = .failed; detail = "Receiver could not launch; open the log"
            throw error
        }
        process = child; logFile = log
        currentState = .starting; detail = "Starting paired HTTPS receiver…"
    }
    func stop() {
        refresh()
        guard let process, process.isRunning, currentState != .stopping else { return }
        currentState = .stopping; detail = "Stopping — waiting for active delivery…"
        process.terminate()
    }
    func refresh() {
        guard let process else { return }
        if !process.isRunning {
            if currentState == .stopping && process.terminationStatus == 0 {
                currentState = .stopped; detail = "Receiver stopped"
            } else {
                currentState = .failed; detail = "Receiver exited (\(process.terminationStatus)); open the log"
            }
            self.process = nil; logFile = nil
        } else if currentState == .starting,
                  let handle = try? FileHandle(forReadingFrom: configuration.log) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: startOffset)
            // Startup output only; never read queue data or pairing credentials.
            let bytes = (try? handle.read(upToCount: 16384)) ?? Data()
            if String(decoding: bytes, as: UTF8.self).contains("Paired HTTPS receiver listening on port ") {
                currentState = .running; detail = "Receiver running · same Wi-Fi"
            }
        }
    }
}
