import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ScreenshotLibraryItem: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var imageFilename: String
    public var annotationFilename: String
    public var createdAt: Date
    public var updatedAt: Date

    public var imagePath: String { imageFilename }
    public var annotationPath: String { annotationFilename }
}

public struct ScreenshotLibraryDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var items: [ScreenshotLibraryItem]

    public init(version: Int = ScreenshotLibraryDocument.currentVersion, items: [ScreenshotLibraryItem] = []) {
        self.version = version
        self.items = items
    }
}

public enum ScreenshotAnnotationTool: String, Codable, Sendable, Equatable, CaseIterable {
    case arrow
    case rectangle
    case text
    case freehand
}

public struct ScreenshotColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct ScreenshotPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScreenshotRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ScreenshotAnnotationLayer: Codable, Sendable, Equatable {
    case arrow(start: ScreenshotPoint, end: ScreenshotPoint, color: ScreenshotColor, lineWidth: Double)
    case rectangle(rect: ScreenshotRect, color: ScreenshotColor, lineWidth: Double)
    case text(position: ScreenshotPoint, text: String, color: ScreenshotColor, fontSize: Double)
    case freehand(points: [ScreenshotPoint], color: ScreenshotColor, lineWidth: Double)
}

public struct ScreenshotAnnotationDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var layers: [ScreenshotAnnotationLayer]

    public init(version: Int = ScreenshotAnnotationDocument.currentVersion, layers: [ScreenshotAnnotationLayer] = []) {
        self.version = version
        self.layers = layers
    }
}

public enum ScreenshotLibraryError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case imageTooLarge(Int)
    case imageDecodeFailed
    case imageDimensionsTooLarge(Int)
    case unsupportedImageType
    case duplicateID
    case annotationTooLarge(Int)
    case invalidName
    case itemNotFound

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported screenshot library version: \(version)."
        case .imageTooLarge(let max): "Image exceeds allowed size (\(max) bytes)."
        case .imageDecodeFailed: "Image could not be decoded."
        case .imageDimensionsTooLarge(let max): "Image dimensions exceed allowed limit (\(max) px)."
        case .unsupportedImageType: "Only decodable raster image formats are supported."
        case .duplicateID: "Screenshot ID already exists."
        case .annotationTooLarge(let max): "Annotation data exceeds allowed size (\(max) bytes)."
        case .invalidName: "Screenshot name cannot be empty."
        case .itemNotFound: "Screenshot not found."
        }
    }
}

public struct ScreenshotLibraryStore {
    public static let maximumImageBytes = 12 * 1024 * 1024
    public static let maximumImagePixelDimension = 8_192
    public static let maximumAnnotationBytes = 512 * 1024
    public static let maximumNameBytes = 256

    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lanebay", isDirectory: true)
        self.fileManager = fileManager
    }

    public func loadItems() throws -> [ScreenshotLibraryItem] {
        try loadDocument().items.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func imageURL(for item: ScreenshotLibraryItem) -> URL {
        screenshotsDirectory().appendingPathComponent(item.imageFilename)
    }

    public func annotationURL(for item: ScreenshotLibraryItem) -> URL {
        screenshotsDirectory().appendingPathComponent(item.annotationFilename)
    }

    @discardableResult
    public func importImage(data: Data, suggestedName: String?) throws -> ScreenshotLibraryItem {
        guard data.count <= Self.maximumImageBytes else {
            throw ScreenshotLibraryError.imageTooLarge(Self.maximumImageBytes)
        }
        let ext = try detectedImageExtension(from: data)
        try ensureDirectories()
        var document = try loadDocument()
        let id = UUID()
        guard !document.items.contains(where: { $0.id == id }) else { throw ScreenshotLibraryError.duplicateID }
        let now = Date()
        let item = ScreenshotLibraryItem(
            id: id,
            displayName: sanitizedName(suggestedName) ?? "Screenshot \(Self.nameTimestampFormatter.string(from: now))",
            imageFilename: "\(id.uuidString).\(ext)",
            annotationFilename: "\(id.uuidString).annotations.json",
            createdAt: now,
            updatedAt: now
        )
        try AtomicPrivateFileWriter.write(
            data,
            to: imageURL(for: item),
            temporaryPrefix: "screenshot-image",
            fileManager: fileManager
        )
        try saveAnnotations(ScreenshotAnnotationDocument(), for: item)
        document.items.append(item)
        try saveDocument(document)
        return item
    }

    public func rename(id: UUID, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumNameBytes else {
            throw ScreenshotLibraryError.invalidName
        }
        var document = try loadDocument()
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw ScreenshotLibraryError.itemNotFound }
        document.items[index].displayName = trimmed
        document.items[index].updatedAt = Date()
        try saveDocument(document)
    }

    public func delete(id: UUID) throws {
        var document = try loadDocument()
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw ScreenshotLibraryError.itemNotFound }
        let item = document.items.remove(at: index)
        try saveDocument(document)
        try? fileManager.removeItem(at: imageURL(for: item))
        try? fileManager.removeItem(at: annotationURL(for: item))
    }

    public func loadAnnotations(for item: ScreenshotLibraryItem) throws -> ScreenshotAnnotationDocument {
        let file = annotationURL(for: item)
        guard fileManager.fileExists(atPath: file.path) else { return ScreenshotAnnotationDocument() }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumAnnotationBytes else {
            throw ScreenshotLibraryError.annotationTooLarge(Self.maximumAnnotationBytes)
        }
        let document = try JSONDecoder().decode(ScreenshotAnnotationDocument.self, from: data)
        guard document.version <= ScreenshotAnnotationDocument.currentVersion else {
            throw ScreenshotLibraryError.unsupportedVersion(document.version)
        }
        return document
    }

    public func saveAnnotations(_ document: ScreenshotAnnotationDocument, for item: ScreenshotLibraryItem) throws {
        guard document.version <= ScreenshotAnnotationDocument.currentVersion else {
            throw ScreenshotLibraryError.unsupportedVersion(document.version)
        }
        let data = try JSONEncoder.privatePrettyEncoder.encode(document)
        guard data.count <= Self.maximumAnnotationBytes else {
            throw ScreenshotLibraryError.annotationTooLarge(Self.maximumAnnotationBytes)
        }
        try ensureDirectories()
        try AtomicPrivateFileWriter.write(
            data,
            to: annotationURL(for: item),
            temporaryPrefix: "screenshot-annotations",
            fileManager: fileManager
        )
    }

    public func loadImageData(for item: ScreenshotLibraryItem) throws -> Data {
        try Data(contentsOf: imageURL(for: item))
    }

    private func loadDocument() throws -> ScreenshotLibraryDocument {
        let file = indexURL()
        guard fileManager.fileExists(atPath: file.path) else { return ScreenshotLibraryDocument() }
        let data = try Data(contentsOf: file)
        let document = try JSONDecoder().decode(ScreenshotLibraryDocument.self, from: data)
        guard document.version <= ScreenshotLibraryDocument.currentVersion else {
            throw ScreenshotLibraryError.unsupportedVersion(document.version)
        }
        return document
    }

    private func saveDocument(_ document: ScreenshotLibraryDocument) throws {
        try ensureDirectories()
        let data = try JSONEncoder.privatePrettyEncoder.encode(document)
        try AtomicPrivateFileWriter.write(data, to: indexURL(), temporaryPrefix: "screenshots-index", fileManager: fileManager)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: screenshotsDirectory(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func indexURL() -> URL {
        rootURL.appendingPathComponent("screenshots.json")
    }

    private func screenshotsDirectory() -> URL {
        rootURL.appendingPathComponent("screenshots", isDirectory: true)
    }

    private func sanitizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.utf8.count > Self.maximumNameBytes {
            let prefixData = Data(trimmed.utf8.prefix(Self.maximumNameBytes))
            return String(decoding: prefixData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func detectedImageExtension(from data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgType = CGImageSourceGetType(source),
              (try? Self.decodeImage(data: data)) != nil else {
            throw ScreenshotLibraryError.imageDecodeFailed
        }
        let type = cgType as String
        guard let utType = UTType(type), utType.conforms(to: .image) else {
            throw ScreenshotLibraryError.unsupportedImageType
        }
        if utType == .png { return "png" }
        if utType == .jpeg { return "jpg" }
        if utType == .gif { return "gif" }
        if utType == .tiff { return "tiff" }
        if let preferred = utType.preferredFilenameExtension {
            return preferred
        }
        return "img"
    }

    public static func decodeImage(data: Data, maxPixelDimension: Int = maximumImagePixelDimension) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ScreenshotLibraryError.imageDecodeFailed
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ScreenshotLibraryError.imageDecodeFailed
        }
        guard width > 0, height > 0 else {
            throw ScreenshotLibraryError.imageDecodeFailed
        }
        guard width <= maxPixelDimension, height <= maxPixelDimension else {
            throw ScreenshotLibraryError.imageDimensionsTooLarge(maxPixelDimension)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ScreenshotLibraryError.imageDecodeFailed
        }
        return image
    }

    private static let nameTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private extension JSONEncoder {
    static var privatePrettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
