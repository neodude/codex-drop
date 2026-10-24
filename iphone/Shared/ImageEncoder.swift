import Foundation
import UniformTypeIdentifiers

// Own only app-created files. Provider URLs are copied before their callback ends.
final class ImageFile: Sendable {
    let url: URL
    let byteCount: Int
    init(url: URL, byteCount: Int) { self.url = url; self.byteCount = byteCount }
    deinit { try? FileManager.default.removeItem(at: url) }
    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("codex-drop-image-" + UUID().uuidString)
    }
    static func copy(from source: URL, cancelled: () -> Bool = { false }) throws -> ImageFile {
        let destination = temporaryURL()
        var owned = false
        defer { if !owned { try? FileManager.default.removeItem(at: destination) } }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ReceiverError.message("Could not copy the shared image.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count = 0
        while true {
            if cancelled() { throw CancellationError() }
            try Task.checkCancellation()
            let copied = try autoreleasepool {
                guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { return 0 }
                count += chunk.count
                guard count <= ImageInput.maximumBytes else { throw ImageInput.byteLimitError }
                try output.write(contentsOf: chunk)
                return chunk.count
            }
            if copied == 0 { break }
        }
        guard count > 0 else { throw ImageInput.unreadableError }
        owned = true
        return ImageFile(url: destination, byteCount: count)
    }
    static func stage(_ data: Data) throws -> ImageFile {
        guard !data.isEmpty else { throw ImageInput.unreadableError }
        guard data.count <= ImageInput.maximumBytes else { throw ImageInput.byteLimitError }
        try Task.checkCancellation()
        let url = temporaryURL()
        do { try data.write(to: url); return ImageFile(url: url, byteCount: data.count) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}

// This path validates only byte bounds. The receiver validates the original format.
// It never decodes, renders, strips metadata, rotates, resizes, or re-encodes an image.
enum ImageInput {
    static let maximumBytes = 50 * 1024 * 1024
    static var byteLimitError: ReceiverError { .message("Each image file must be at most 50 MiB.") }
    static var unreadableError: ReceiverError { .message("Could not read the image file supplied by the source app.") }
    static func originalTypeIdentifier(in registeredTypes: [String]) -> String? {
        registeredTypes.first {
            $0 != UTType.image.identifier && $0 != "com.apple.uikit.image" &&
            UTType($0)?.conforms(to: .image) == true
        }
    }
    @concurrent static func originalFile(_ input: ImageFile) async throws -> ImageFile {
        try Task.checkCancellation()
        guard input.byteCount > 0 else { throw unreadableError }
        guard input.byteCount <= maximumBytes else { throw byteLimitError }
        return input
    }
}
