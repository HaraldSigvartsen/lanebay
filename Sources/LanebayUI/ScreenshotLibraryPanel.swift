import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LanebayCore
import SwiftUI
import UniformTypeIdentifiers

public struct ScreenshotAttachTarget: Identifiable, Equatable {
    public let id: UUID
    public let title: String
}

@MainActor
@Observable
public final class ScreenshotLibraryPanelModel {
    public private(set) var items: [ScreenshotLibraryItem] = []
    public private(set) var selectedItem: ScreenshotLibraryItem?
    public private(set) var selectedImageData: Data?
    public private(set) var selectedCGImage: CGImage?
    public private(set) var layers: [ScreenshotAnnotationLayer] = []
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?
    public private(set) var isBusy = false

    public var selectedTool: ScreenshotAnnotationTool = .arrow
    public var selectedAttachTargetID: UUID?
    public var draftText = "Label"

    public private(set) var attachTargets: [ScreenshotAttachTarget]
    public private(set) var pendingDelete: ScreenshotLibraryItem?

    private let store: ScreenshotLibraryStore
    private let attachToConsole: @MainActor @Sendable (UUID, String) -> Bool
    private var pendingTextPoint: ScreenshotPoint?

    public init(
        store: ScreenshotLibraryStore = ScreenshotLibraryStore(),
        attachTargets: [ScreenshotAttachTarget] = [],
        attachToConsole: @escaping @MainActor @Sendable (UUID, String) -> Bool = { _, _ in false }
    ) {
        self.store = store
        self.attachTargets = attachTargets
        self.attachToConsole = attachToConsole
        self.selectedAttachTargetID = attachTargets.first?.id
        reloadLibrary()
    }

    public func updateAttachTargets(_ targets: [ScreenshotAttachTarget]) {
        attachTargets = targets
        if let selectedAttachTargetID, targets.contains(where: { $0.id == selectedAttachTargetID }) {
            self.selectedAttachTargetID = selectedAttachTargetID
        } else {
            self.selectedAttachTargetID = targets.first?.id
        }
    }

    public func reloadLibrary() {
        do {
            items = try store.loadItems()
            if let selectedItem {
                if let matched = items.first(where: { $0.id == selectedItem.id }) {
                    try select(matched)
                } else {
                    clearSelection()
                }
            } else if let first = items.first {
                try select(first)
            }
            errorMessage = nil
        } catch {
            items = []
            clearSelection()
            errorMessage = error.localizedDescription
        }
    }

    public func chooseImportFromFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    public func importURLs(_ urls: [URL]) {
        isBusy = true
        defer { isBusy = false }
        var importedCount = 0
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                _ = try store.importImage(data: data, suggestedName: url.deletingPathExtension().lastPathComponent)
                importedCount += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        reloadLibrary()
        if importedCount > 0 {
            statusMessage = importedCount == 1 ? "Imported screenshot." : "Imported \(importedCount) screenshots."
        }
    }

    public func importFromPasteboard() {
        let pasteboard = NSPasteboard.general
        if let urlString = pasteboard.string(forType: .fileURL),
           let url = URL(string: urlString) {
            importURLs([url])
            return
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            do {
                _ = try store.importImage(data: data, suggestedName: "Pasted")
                reloadLibrary()
                statusMessage = "Pasted screenshot imported."
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            errorMessage = "No image found on clipboard."
        }
    }

    public func select(_ item: ScreenshotLibraryItem) throws {
        selectedItem = item
        let imageData = try store.loadImageData(for: item)
        selectedImageData = imageData
        selectedCGImage = try ScreenshotLibraryStore.decodeImage(data: imageData)
        layers = try store.loadAnnotations(for: item).layers
    }

    public func renameSelected(_ name: String) {
        guard let selectedItem else { return }
        do {
            try store.rename(id: selectedItem.id, newName: name)
            reloadLibrary()
            statusMessage = "Screenshot renamed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func requestDeleteSelected() {
        pendingDelete = selectedItem
    }

    public func confirmDeleteSelection() {
        guard let pendingDelete else { return }
        do {
            try store.delete(id: pendingDelete.id)
            self.pendingDelete = nil
            reloadLibrary()
            statusMessage = "Screenshot deleted."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelDelete() {
        pendingDelete = nil
    }

    public func saveAnnotations() {
        guard let selectedItem else { return }
        do {
            try store.saveAnnotations(ScreenshotAnnotationDocument(layers: layers), for: selectedItem)
            reloadLibrary()
            statusMessage = "Annotations saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearAnnotations() {
        layers = []
        saveAnnotations()
    }

    public func appendLayer(_ layer: ScreenshotAnnotationLayer) {
        layers.append(layer)
        saveAnnotations()
    }

    public func setPendingTextPoint(_ point: ScreenshotPoint) {
        pendingTextPoint = point
    }

    public func addTextLayer() {
        guard let point = pendingTextPoint else {
            errorMessage = "Click in the image first to place text."
            return
        }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Text annotation cannot be empty."
            return
        }
        appendLayer(.text(position: point, text: text, color: .init(red: 0.94, green: 0.27, blue: 0.36, alpha: 1), fontSize: 18))
        pendingTextPoint = nil
    }

    public func attachSelectedToConsole() {
        guard let item = selectedItem else {
            errorMessage = "Select a screenshot first."
            return
        }
        guard let target = selectedAttachTargetID else {
            errorMessage = "Select a running console."
            return
        }
        let path = store.imageURL(for: item).path
        if attachToConsole(target, path) {
            statusMessage = "Attached path sent to selected console."
        } else {
            errorMessage = "Could not dispatch to selected console. Ensure it is running and idle."
        }
    }

    public func exportFlattenedPNG() {
        guard let item = selectedItem, let imageData = selectedImageData else { return }
        guard let flattened = ScreenshotAnnotationRenderer.flattenedPNG(baseData: imageData, layers: layers) else {
            errorMessage = "Could not render flattened PNG."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(item.displayName).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try flattened.write(to: url, options: .atomic)
            statusMessage = "Flattened PNG exported."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearSelection() {
        selectedItem = nil
        selectedImageData = nil
        selectedCGImage = nil
        layers = []
    }
}

public struct ScreenshotLibraryPanel: View {
    @Bindable private var model: ScreenshotLibraryPanelModel
    @State private var renameValue = ""

    public init(model: ScreenshotLibraryPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Button("Import…") { model.chooseImportFromFilePicker() }
                Button("Paste") { model.importFromPasteboard() }
                Spacer()
                Button("Refresh") { model.reloadLibrary() }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.importURLs(urls)
                return true
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Spacing.xs)], spacing: Spacing.xs) {
                    ForEach(model.items) { item in
                        Button {
                            try? model.select(item)
                            renameValue = item.displayName
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(item.displayName)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)
                                Text(item.createdAt, style: .date)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.mutedInk)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.xs)
                            .background(item.id == model.selectedItem?.id ? Palette.accentSoft : Palette.raisedSurface)
                            .overlay(RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 220)

            if model.selectedItem != nil {
                HStack {
                    TextField("Name", text: $renameValue)
                    Button("Rename") { model.renameSelected(renameValue) }
                    Button("Delete", role: .destructive) { model.requestDeleteSelected() }
                }
                annotationToolbar
                editorSurface
                HStack {
                    if !model.attachTargets.isEmpty {
                        Picker("Attach to console", selection: $model.selectedAttachTargetID) {
                            ForEach(model.attachTargets) { target in
                                Text(target.title).tag(Optional(target.id))
                            }
                        }
                        .pickerStyle(.menu)
                        Button("Attach path") { model.attachSelectedToConsole() }
                    }
                    Spacer()
                    Button("Export flattened PNG") { model.exportFlattenedPNG() }
                }
            } else {
                ContentUnavailableView("No screenshot selected", systemImage: "photo.on.rectangle", description: Text("Import from file picker, drag-drop, or paste an image."))
            }

            if let message = model.statusMessage {
                Text(message).font(Typography.caption).foregroundStyle(Palette.accent)
            }
            if let error = model.errorMessage {
                Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
            }
            Text("Images are imported from files, drag-drop, or paste. Screen capture is intentionally not included.")
                .font(Typography.caption)
                .foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm)
        .alert("Delete screenshot?", isPresented: Binding(
            get: { model.pendingDelete != nil },
            set: { if !$0 { model.cancelDelete() } }
        )) {
            Button("Cancel", role: .cancel) { model.cancelDelete() }
            Button("Delete", role: .destructive) { model.confirmDeleteSelection() }
        } message: {
            Text("This removes the stored image copy and its annotation JSON.")
        }
    }

    private var annotationToolbar: some View {
        HStack {
            Picker("Tool", selection: $model.selectedTool) {
                Text("Arrow").tag(ScreenshotAnnotationTool.arrow)
                Text("Rectangle").tag(ScreenshotAnnotationTool.rectangle)
                Text("Freehand").tag(ScreenshotAnnotationTool.freehand)
                Text("Text").tag(ScreenshotAnnotationTool.text)
            }
            .pickerStyle(.segmented)
            if model.selectedTool == .text {
                TextField("Text", text: $model.draftText)
                Button("Add text") { model.addTextLayer() }
            }
            Button("Clear annotations", role: .destructive) { model.clearAnnotations() }
        }
    }

    private var editorSurface: some View {
        ScreenshotAnnotationCanvas(
            cgImage: model.selectedCGImage,
            layers: model.layers,
            selectedTool: model.selectedTool
        ) { layer in
            model.appendLayer(layer)
        } onTextPlacement: { point in
            model.setPendingTextPoint(point)
        }
        .frame(minHeight: 260)
        .background(Palette.raisedSurface)
        .overlay(RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border))
    }
}

private struct ScreenshotAnnotationCanvas: View {
    let cgImage: CGImage?
    let layers: [ScreenshotAnnotationLayer]
    let selectedTool: ScreenshotAnnotationTool
    let onLayerCommitted: (ScreenshotAnnotationLayer) -> Void
    let onTextPlacement: (ScreenshotPoint) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var freehandPoints: [CGPoint] = []

    var body: some View {
        GeometryReader { geometry in
            if let cgImage {
                let frame = aspectFitRect(image: CGSize(width: cgImage.width, height: cgImage.height), in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    Canvas { context, _ in
                        for layer in layers {
                            draw(layer: layer, in: &context, imageFrame: frame, imageSize: CGSize(width: cgImage.width, height: cgImage.height))
                        }
                        if let preview = previewLayer(imageFrame: frame, imageSize: CGSize(width: cgImage.width, height: cgImage.height)) {
                            draw(layer: preview, in: &context, imageFrame: frame, imageSize: CGSize(width: cgImage.width, height: cgImage.height))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard frame.contains(value.location) else { return }
                            if dragStart == nil {
                                dragStart = value.startLocation
                                if selectedTool == .text {
                                    let point = convertToImagePoint(value.location, imageFrame: frame, imageSize: CGSize(width: cgImage.width, height: cgImage.height))
                                    onTextPlacement(point)
                                }
                            }
                            dragCurrent = value.location
                            if selectedTool == .freehand {
                                freehandPoints.append(value.location)
                            }
                        }
                        .onEnded { _ in
                            defer {
                                dragStart = nil
                                dragCurrent = nil
                                freehandPoints = []
                            }
                            guard let layer = committedLayer(imageFrame: frame, imageSize: CGSize(width: cgImage.width, height: cgImage.height)) else { return }
                            onLayerCommitted(layer)
                        }
                )
            } else {
                ContentUnavailableView("Could not decode image", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func committedLayer(imageFrame: CGRect, imageSize: CGSize) -> ScreenshotAnnotationLayer? {
        switch selectedTool {
        case .arrow:
            guard let start = dragStart, let end = dragCurrent else { return nil }
            return .arrow(
                start: convertToImagePoint(start, imageFrame: imageFrame, imageSize: imageSize),
                end: convertToImagePoint(end, imageFrame: imageFrame, imageSize: imageSize),
                color: .init(red: 0.18, green: 0.43, blue: 0.95, alpha: 1),
                lineWidth: 3
            )
        case .rectangle:
            guard let start = dragStart, let end = dragCurrent else { return nil }
            let rect = normalizedRect(from: start, to: end)
            let imageStart = convertToImagePoint(rect.origin, imageFrame: imageFrame, imageSize: imageSize)
            let imageEnd = convertToImagePoint(CGPoint(x: rect.maxX, y: rect.maxY), imageFrame: imageFrame, imageSize: imageSize)
            return .rectangle(
                rect: ScreenshotRect(
                    x: imageStart.x,
                    y: imageStart.y,
                    width: imageEnd.x - imageStart.x,
                    height: imageEnd.y - imageStart.y
                ),
                color: .init(red: 0.05, green: 0.68, blue: 0.43, alpha: 1),
                lineWidth: 3
            )
        case .freehand:
            let points = freehandPoints.map { convertToImagePoint($0, imageFrame: imageFrame, imageSize: imageSize) }
            guard points.count > 1 else { return nil }
            return .freehand(points: points, color: .init(red: 0.94, green: 0.58, blue: 0.2, alpha: 1), lineWidth: 2.5)
        case .text:
            return nil
        }
    }

    private func previewLayer(imageFrame: CGRect, imageSize: CGSize) -> ScreenshotAnnotationLayer? {
        committedLayer(imageFrame: imageFrame, imageSize: imageSize)
    }

    private func draw(layer: ScreenshotAnnotationLayer, in context: inout GraphicsContext, imageFrame: CGRect, imageSize: CGSize) {
        switch layer {
        case .arrow(let start, let end, let color, let lineWidth):
            let a = convertToViewPoint(start, imageFrame: imageFrame, imageSize: imageSize)
            let b = convertToViewPoint(end, imageFrame: imageFrame, imageSize: imageSize)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(path, with: .color(swiftUIColor(color)), lineWidth: lineWidth)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let headSize = CGFloat(10)
            var head = Path()
            head.move(to: b)
            head.addLine(to: CGPoint(x: b.x - headSize * cos(angle - .pi / 6), y: b.y - headSize * sin(angle - .pi / 6)))
            head.move(to: b)
            head.addLine(to: CGPoint(x: b.x - headSize * cos(angle + .pi / 6), y: b.y - headSize * sin(angle + .pi / 6)))
            context.stroke(head, with: .color(swiftUIColor(color)), lineWidth: lineWidth)
        case .rectangle(let rect, let color, let lineWidth):
            let topLeft = convertToViewPoint(.init(x: rect.x, y: rect.y), imageFrame: imageFrame, imageSize: imageSize)
            let bottomRight = convertToViewPoint(.init(x: rect.x + rect.width, y: rect.y + rect.height), imageFrame: imageFrame, imageSize: imageSize)
            let viewRect = CGRect(
                x: min(topLeft.x, bottomRight.x),
                y: min(topLeft.y, bottomRight.y),
                width: abs(bottomRight.x - topLeft.x),
                height: abs(bottomRight.y - topLeft.y)
            )
            context.stroke(Path(viewRect), with: .color(swiftUIColor(color)), lineWidth: lineWidth)
        case .text(let position, let text, let color, let fontSize):
            let point = convertToViewPoint(position, imageFrame: imageFrame, imageSize: imageSize)
            context.draw(
                Text(text).font(.system(size: fontSize, weight: .semibold)).foregroundColor(swiftUIColor(color)),
                at: point,
                anchor: .topLeading
            )
        case .freehand(let points, let color, let lineWidth):
            guard points.count > 1 else { return }
            var path = Path()
            let first = convertToViewPoint(points[0], imageFrame: imageFrame, imageSize: imageSize)
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: convertToViewPoint(point, imageFrame: imageFrame, imageSize: imageSize))
            }
            context.stroke(path, with: .color(swiftUIColor(color)), lineWidth: lineWidth)
        }
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func convertToImagePoint(_ point: CGPoint, imageFrame: CGRect, imageSize: CGSize) -> ScreenshotPoint {
        let xRatio = imageSize.width / imageFrame.width
        let yRatio = imageSize.height / imageFrame.height
        return ScreenshotPoint(
            x: max(0, min(imageSize.width, (point.x - imageFrame.minX) * xRatio)),
            y: max(0, min(imageSize.height, (point.y - imageFrame.minY) * yRatio))
        )
    }

    private func convertToViewPoint(_ point: ScreenshotPoint, imageFrame: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + (point.x / imageSize.width) * imageFrame.width,
            y: imageFrame.minY + (point.y / imageSize.height) * imageFrame.height
        )
    }

    private func aspectFitRect(image: CGSize, in available: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height)
        let width = image.width * scale
        let height = image.height * scale
        return CGRect(x: (available.width - width) * 0.5, y: (available.height - height) * 0.5, width: width, height: height)
    }

    private func swiftUIColor(_ color: ScreenshotColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

enum ScreenshotAnnotationRenderer {
    static func flattenedPNG(baseData: Data, layers: [ScreenshotAnnotationLayer]) -> Data? {
        guard let image = try? ScreenshotLibraryStore.decodeImage(data: baseData) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for layer in layers {
            draw(layer: layer, into: context, canvasHeight: CGFloat(height))
        }
        guard let rendered = context.makeImage() else { return nil }
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutable, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutable as Data
    }

    private static func draw(layer: ScreenshotAnnotationLayer, into context: CGContext, canvasHeight: CGFloat) {
        switch layer {
        case .arrow(let start, let end, let color, let lineWidth):
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(lineWidth)
            let a = cgPoint(start, canvasHeight: canvasHeight)
            let b = cgPoint(end, canvasHeight: canvasHeight)
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = CGFloat(10)
            context.move(to: b)
            context.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6)))
            context.move(to: b)
            context.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6)))
            context.strokePath()
        case .rectangle(let rect, let color, let lineWidth):
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(lineWidth)
            let cgRect = CGRect(x: rect.x, y: Double(canvasHeight) - (rect.y + rect.height), width: rect.width, height: rect.height)
            context.stroke(cgRect)
        case .text(let position, let text, let color, let fontSize):
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(
                    calibratedRed: color.red,
                    green: color.green,
                    blue: color.blue,
                    alpha: color.alpha
                ),
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            ]
            let point = CGPoint(x: position.x, y: Double(canvasHeight) - position.y - fontSize)
            NSAttributedString(string: text, attributes: attributes).draw(at: point)
        case .freehand(let points, let color, let lineWidth):
            guard points.count > 1 else { return }
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.move(to: cgPoint(points[0], canvasHeight: canvasHeight))
            for point in points.dropFirst() {
                context.addLine(to: cgPoint(point, canvasHeight: canvasHeight))
            }
            context.strokePath()
        }
    }

    private static func cgPoint(_ point: ScreenshotPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: Double(canvasHeight) - point.y)
    }

    private static func cgColor(_ color: ScreenshotColor) -> CGColor {
        CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
