import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageEncoder {
    @concurrent static func png(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw ReceiverError.message("Each image must be at most 20 MiB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 10000, height <= 10000,
              width * height <= 12_000_000 else { throw ReceiverError.message("This image is too large for the share extension. Use a normal screenshot.") }
        if data.starts(with: [137,80,78,71,13,10,26,10]) { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ReceiverError.message("Could not prepare the image.")
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 20 * 1024 * 1024 else {
            throw ReceiverError.message("Could not prepare a PNG smaller than 20 MiB.")
        }
        try Task.checkCancellation()
        return output as Data
    }
}
