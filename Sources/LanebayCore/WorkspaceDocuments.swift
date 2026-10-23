import Foundation
import Darwin

public struct WorkspaceDocument: Identifiable, Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }
    public var id: String { relativePath }
}

public typealias WorkspaceSourceFile = WorkspaceDocument

public enum WorkspaceDocumentsError: Error, LocalizedError, Equatable {
    case invalidRoot
    case outsideRoot
    case unsupportedFile
    case tooLarge
    case notRegularFile

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "The project folder is unavailable."
        case .outsideRoot: "The document is outside the project folder."
        case .unsupportedFile: "Only Markdown and plain text documents are supported."
        case .tooLarge: "The document exceeds the 1 MB size limit."
        case .notRegularFile: "The selected document is not a regular file."
        }
    }
}

/// Read-only access to project files contained in a project folder.
public struct WorkspaceDocuments {
    public static let maximumFileSize = 1_048_576
    private enum FileKind {
        case document
        case source
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func list(in projectRoot: URL) throws -> [WorkspaceDocument] {
        let root = try canonicalRoot(projectRoot)
        var documents: [WorkspaceDocument] = []
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, Self.supported(url, as: .document) else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard let relativePath = relativePath(root: root, candidate: resolved) else { continue }
            let document = WorkspaceDocument(url: url, relativePath: relativePath)
            do { _ = try read(document, in: root); documents.append(document) }
            catch WorkspaceDocumentsError.tooLarge { continue }
            catch WorkspaceDocumentsError.unsupportedFile { continue }
        }
        return documents.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    public func read(_ document: WorkspaceDocument, in projectRoot: URL) throws -> String {
        let root = try canonicalRoot(projectRoot)
        let candidate = document.url
        guard Self.supported(candidate, as: .document) else { throw WorkspaceDocumentsError.unsupportedFile }
        return try readContainedFile(candidate, root: root)
    }

    /// Lists and reads Markdown files from a known skill folder using the same
    /// containment, symlink, regular-file, and size checks as workspace docs.
    public func listMarkdown(in directory: URL) throws -> [WorkspaceDocument] {
        let root = try canonicalRoot(directory)
        var result: [WorkspaceDocument] = []
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, ["md", "markdown"].contains(url.pathExtension.lowercased()) else { continue }
            guard let relative = relativePath(
                root: root, candidate: url.standardizedFileURL.resolvingSymlinksInPath())
            else { continue }
            let doc = WorkspaceDocument(url: url, relativePath: relative)
            do { _ = try read(doc, in: root); result.append(doc) }
            catch WorkspaceDocumentsError.tooLarge { continue }
            catch WorkspaceDocumentsError.unsupportedFile { continue }
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Lists source files for the code browser, excluding generated, dependency, and Git data.
    public func listSourceFiles(in projectRoot: URL) throws -> [WorkspaceSourceFile] {
        let root = try canonicalRoot(projectRoot)
        var files: [WorkspaceSourceFile] = []
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard let relative = relativeComponents(
                root: root, candidate: url.standardizedFileURL.resolvingSymlinksInPath())
            else { continue }
            if relative.contains(where: { [".git", "node_modules", ".build"].contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, Self.supported(url, as: .source) else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard let relativePath = relativePath(root: root, candidate: resolved) else { continue }
            do {
                _ = try readFile(WorkspaceDocument(url: url, relativePath: relativePath), in: root, as: .source)
                files.append(WorkspaceSourceFile(url: url, relativePath: relativePath))
            } catch WorkspaceDocumentsError.tooLarge {
                continue
            } catch WorkspaceDocumentsError.unsupportedFile {
                continue
            }
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    public func readSourceFile(_ file: WorkspaceSourceFile, in projectRoot: URL) throws -> String {
        try readFile(file, in: projectRoot, as: .source)
    }

    private func readFile(_ file: WorkspaceDocument, in projectRoot: URL, as kind: FileKind) throws -> String {
        let root = try canonicalRoot(projectRoot)
        let components = file.relativePath.split(separator: "/")
        guard !components.contains(where: { [".git", "node_modules", ".build"].contains(String($0)) }) else {
            throw WorkspaceDocumentsError.outsideRoot
        }
        guard Self.supported(file.url, as: kind) else { throw WorkspaceDocumentsError.unsupportedFile }
        return try readContainedFile(file.url, root: root)
    }

    /// Opens every component relative to a pinned root descriptor without following
    /// symlinks, then validates and reads from that same final descriptor.
    private func readContainedFile(_ url: URL, root: URL) throws -> String {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkspaceDocumentsError.invalidRoot
        }
        // Root is already canonicalized and user-selected; keep O_NOFOLLOW on descendants
        // while allowing symlinked roots such as /var -> /private/var to open correctly.
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw WorkspaceDocumentsError.invalidRoot }
        defer { _ = close(rootFD) }

        guard let parts = relativeComponents(root: root, candidate: url) else {
            throw WorkspaceDocumentsError.outsideRoot
        }
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw WorkspaceDocumentsError.outsideRoot
        }

        var parentFD = rootFD
        var ownedParentFD: Int32 = -1
        defer { if ownedParentFD >= 0 { _ = close(ownedParentFD) } }
        for part in parts.dropLast() {
            let next = part.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw WorkspaceDocumentsError.outsideRoot }
            if ownedParentFD >= 0 { _ = close(ownedParentFD) }
            ownedParentFD = next
            parentFD = next
        }
        guard let leaf = parts.last else { throw WorkspaceDocumentsError.outsideRoot }
        let fileFD = leaf.withCString { openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fileFD >= 0 else { throw WorkspaceDocumentsError.outsideRoot }
        defer { _ = close(fileFD) }

        var info = stat()
        guard fstat(fileFD, &info) == 0 else { throw WorkspaceDocumentsError.outsideRoot }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceDocumentsError.notRegularFile }
        guard info.st_size >= 0, info.st_size <= off_t(Self.maximumFileSize) else { throw WorkspaceDocumentsError.tooLarge }

        var data = Data()
        let readLimit = Self.maximumFileSize + 1
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, readLimit))
        while data.count < readLimit {
            let amount = min(buffer.count, readLimit - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fileFD, $0.baseAddress, amount) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(buffer, count: count)
        }
        guard data.count <= Self.maximumFileSize else { throw WorkspaceDocumentsError.tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceDocumentsError.unsupportedFile
        }
        return text
    }

    private func canonicalRoot(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceDocumentsError.invalidRoot
        }
        return resolved
    }

    private static func supported(_ url: URL, as kind: FileKind) -> Bool {
        let extensions: Set<String>
        switch kind {
        case .document:
            extensions = ["md", "markdown", "txt", "text"]
        case .source:
            extensions = [
                "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "kt",
                "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm", "json", "yaml", "yml",
                "toml", "sh", "bash", "zsh", "css", "scss", "html", "htm", "md", "markdown",
                "txt", "text", "xml", "sql", "graphql", "vue", "svelte", "astro", "php",
                "pl", "pm", "r", "dart", "ex", "exs", "erl", "hrl", "hs", "lhs", "elm", "clj",
                "cljs", "cljc", "edn", "fs", "fsi", "fsx", "cs", "vb", "ps1", "psm1", "bat",
                "cmd", "make", "mk", "dockerfile", "properties", "ini", "conf", "config", "env",
                "tf", "hcl", "proto", "thrift", "graphqls", "mdx", "ipynb"
            ]
        }
        return extensions.contains(url.pathExtension.lowercased())
    }

    private func isContained(root: URL, candidate: URL) -> Bool {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return normalizedCandidate == normalizedRoot
            || normalizedCandidate.hasPrefix(normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/")
    }

    private func relativePath(root: URL, candidate: URL) -> String? {
        relativeComponents(root: root, candidate: candidate)?.joined(separator: "/")
    }

    private func relativeComponents(root: URL, candidate: URL) -> [String]? {
        guard isContained(root: root, candidate: candidate) else { return nil }
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let normalizedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard normalizedCandidate.count > normalizedRoot.count,
              Array(normalizedCandidate.prefix(normalizedRoot.count)) == normalizedRoot else { return nil }
        return Array(normalizedCandidate.dropFirst(normalizedRoot.count))
    }
}
