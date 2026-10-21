import Foundation
import Darwin

func lifecycleTests() throws {
    var assertions = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: message, code: 1) }
        assertions += 1
    }
    func wait(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        try check(predicate(), "fixture timed out")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Codex Drop lifecycle \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("private data")
    let resources = root.appendingPathComponent("bundle resources")
    try FileManager.default.createDirectory(at: resources.appendingPathComponent("receiver"), withIntermediateDirectories: true)
    let script = resources.appendingPathComponent("receiver/lan_receiver.py")
    let fixture = """
    trap 'sleep 1; echo fixture-graceful-cleanup-finished; exit 0' TERM
    echo 'Paired HTTPS receiver listening on port 9443.'
    while :; do sleep 0.1; done
    """
    try fixture.write(to: script, atomically: true, encoding: .utf8)
    let config = ReceiverConfiguration(project: root, resources: resources, python: URL(fileURLWithPath: "/bin/sh"), data: data)
    try check(config.arguments == [script.path, "--data-dir", data.path], "paths must remain separate arguments")
    let controller = try ReceiverController(configuration: config)
    let duplicate = try? ReceiverController(configuration: config)
    try check(duplicate == nil, "duplicate application lock")
    let external = try PrivateFile(data.appendingPathComponent("receiver.lock"), lock: true)
    do { try controller.start(); try check(false, "external receiver should refuse start") }
    catch ReceiverError.externalReceiver { assertions += 1 }
    flock(external.descriptor, LOCK_UN)
    try controller.start()
    try wait { controller.isReady }
    try check(controller.isRunning, "receiver started")
    try check((try FileManager.default.attributesOfItem(atPath: config.log.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "log private")
    controller.stop()
    try check(controller.isRunning, "stop waits for graceful cleanup")
    try wait { !controller.isRunning }
    try check(controller.state == .stopped, "clean stopped state")
    let cleanupOutput = try String(contentsOf: config.log, encoding: .utf8)
    try check(cleanupOutput.contains("fixture-graceful-cleanup-finished"), "graceful cleanup must finish before process is released")
    try "exit 7\n".write(to: script, atomically: true, encoding: .utf8)
    try controller.start()
    try wait { !controller.isRunning }
    try check(controller.state == .failed, "unexpected exit visible")
    try Data().write(to: root.appendingPathComponent(".receiver-paused"))
    do { try controller.start(); try check(false, "pause should refuse start") } catch ReceiverError.paused { assertions += 1 }
    let logBytes = try Data(contentsOf: config.log)
    try check(String(decoding: logBytes, as: UTF8.self).contains("Paired HTTPS receiver listening"), "startup failure must preserve previous log")
    let symlinkRoot = root.appendingPathComponent("symlink root")
    try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
    let linkedData = symlinkRoot.appendingPathComponent("linked data")
    try FileManager.default.createSymbolicLink(at: linkedData, withDestinationURL: data)
    let linkedConfiguration = ReceiverConfiguration(project: symlinkRoot, resources: resources, python: config.python, data: linkedData)
    do { _ = try ReceiverController(configuration: linkedConfiguration); try check(false, "symlink data directory must be rejected") }
    catch ReceiverError.unsafeFile { assertions += 1 }
    let unsafeData = root.appendingPathComponent("unsafe log")
    let unsafeConfig = ReceiverConfiguration(project: root, resources: resources, python: config.python, data: unsafeData)
    let unsafeController = try ReceiverController(configuration: unsafeConfig)
    try FileManager.default.createSymbolicLink(at: unsafeConfig.log, withDestinationURL: config.log)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".receiver-paused"))
    do { try unsafeController.start(); try check(false, "symlink log must be rejected") }
    catch ReceiverError.unsafeFile { assertions += 1 }
    print("Mac lifecycle checks passed (\(assertions) assertions); isolated fake process only.")
}
