import Foundation
import UniformTypeIdentifiers
import ImageIO

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
            throw ReceiverError.message("Could not copy the shared file.")
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

// Translate just UIImage's encoded-data field into an inert secure-coding
// class. Never instantiate UIImage, decode pixels, or allow other object graphs.
@objc(CodexDropArchivedImageBytes) private final class ArchivedImageBytes: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let data: Data
    required init?(coder: NSCoder) {
        guard !coder.containsValue(forKey: "UIImageImages"),
              !coder.containsValue(forKey: "UIAnimationImages"),
              !coder.containsValue(forKey: "UIImageAnimationImages"),
              !coder.containsValue(forKey: "UIImageOrientation") || coder.decodeInteger(forKey: "UIImageOrientation") == 0,
              coder.containsValue(forKey: "UIImageData"),
              let bytes = coder.decodeObject(of: NSData.self, forKey: "UIImageData") as Data?,
              !bytes.isEmpty, bytes.count <= ImageInput.maximumBytes else { return nil }
        data = bytes
        super.init()
    }
    func encode(with coder: NSCoder) {
        coder.failWithError(CocoaError(.coderInvalidValue))
    }
}

// The receiver validates the original format. A known UIImage archive can supply
// its encoded file unchanged; arbitrary archives and separate rotation refuse.
// It never decodes, renders, strips metadata, rotates, resizes, or re-encodes an image.
enum ImageInput {
    static let maximumBytes = 50 * 1024 * 1024
    static var byteLimitError: ReceiverError { .message("Each file must be at most 50 MiB.") }
    static var unreadableError: ReceiverError { .message("Could not read the file supplied by the source app.") }
    static func originalTypeIdentifier(in registeredTypes: [String]) -> String? {
        let concreteTypes = registeredTypes.filter {
            $0 != UTType.image.identifier && $0 != "com.apple.uikit.image" &&
            $0 != UTType.movie.identifier && $0 != UTType.video.identifier &&
            (UTType($0)?.conforms(to: .image) == true || UTType($0)?.conforms(to: .movie) == true)
        }
        // A source may offer several file representations. Keep its ordering
        // among Codex-compatible types rather than requesting an unsupported
        // original when a supported file is already available. No transcoding.
        let supported: Set<UTType> = [.png, .jpeg, .gif, .webP, .mpeg4Movie, .quickTimeMovie]
        return concreteTypes.first { identifier in
            UTType(identifier).map { supported.contains($0) } == true
        } ?? concreteTypes.first
    }
    // Metadata-only diagnostics: never render pixels or include filenames,
    // paths, image metadata values, or arbitrary file contents in the result.
    static func formatDiagnostic(of image: ImageFile, requestedType: String?, offeredTypes: [String]) -> String {
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
        let detected: String
        if let source = CGImageSourceCreateWithURL(image.url as CFURL, options),
           let type = CGImageSourceGetType(source) as String? {
            detected = type
        } else {
            let handle = try? FileHandle(forReadingFrom: image.url)
            defer { try? handle?.close() }
            let header = (try? handle?.read(upToCount: 12)) ?? Data()
            if header.starts(with: Data("bplist00".utf8)) { detected = "binary property list" }
            else if header.starts(with: [0xff, 0x0a]) || header.starts(with: [0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20]) { detected = "JPEG XL" }
            else { detected = "unrecognized" }
        }
        func safeType(_ value: String) -> Bool {
            value.count <= 100 && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        }
        let requested = requestedType.flatMap { safeType($0) ? $0 : nil } ?? "unknown"
        let offered = offeredTypes.filter { safeType($0) }.prefix(8).joined(separator: ", ")
        return "Detected: \(detected) (\(image.byteCount) bytes). Requested: \(requested). Offered: \(offered.isEmpty ? "none" : offered)."
    }
    @concurrent static func originalFile(_ input: ImageFile) async throws -> ImageFile {
        try Task.checkCancellation()
        guard input.byteCount > 0 else { throw unreadableError }
        guard input.byteCount <= maximumBytes else { throw byteLimitError }
        let handle = try FileHandle(forReadingFrom: input.url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 8) == Data("bplist00".utf8) else { return input }
        let refusal = ReceiverError.unsupportedImageFormat("The source supplied an image object without a safely extractable image file. Share the image from Photos or Files instead.")
        do {
            let archive = try Data(contentsOf: input.url, options: .mappedIfSafe)
            guard archive.count <= maximumBytes else { throw byteLimitError }
            try Task.checkCancellation()
            let decoder = try NSKeyedUnarchiver(forReadingFrom: archive)
            decoder.requiresSecureCoding = true
            decoder.decodingFailurePolicy = .setErrorAndReturn
            decoder.setClass(ArchivedImageBytes.self, forClassName: "UIImage")
            defer { decoder.finishDecoding() }
            guard let image = decoder.decodeObject(of: ArchivedImageBytes.self, forKey: NSKeyedArchiveRootObjectKey),
                  decoder.error == nil,
                  let source = CGImageSourceCreateWithData(image.data as CFData,
                    [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary),
                  CGImageSourceGetType(source) != nil else { throw refusal }
            try Task.checkCancellation()
            return try ImageFile.stage(image.data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ReceiverError { throw error }
        catch { throw refusal }
    }
}
