import Darwin
import Foundation

/// One request per connection: a single JSON line in, a single JSON line out.
public struct ControlRequest: Codable, Sendable, Equatable {
  public var token: String
  public var op: String
  public var args: [String: String]

  public init(token: String, op: String, args: [String: String] = [:]) {
    self.token = token
    self.op = op
    self.args = args
  }
}

public struct ControlResponse: Codable, Sendable, Equatable {
  public var ok: Bool
  public var error: String?
  public var task: AgentTaskRecord?
  public var tasks: [AgentTaskRecord]?
  public var output: String?

  public init(ok: Bool = true, error: String? = nil, task: AgentTaskRecord? = nil, tasks: [AgentTaskRecord]? = nil, output: String? = nil) {
    self.ok = ok
    self.error = error
    self.task = task
    self.tasks = tasks
    self.output = output
  }

  public static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }
}

public enum ControlOperation: String, CaseIterable, Sendable {
  case spawn, send, read, status, stop, list, link, cron
}

public enum ControlSocketError: Error, LocalizedError, Equatable {
  case pathTooLong(String)
  case alreadyRunning(String)
  case systemCall(String, Int32)
  case notRunning(String)
  case tokenMissing(String)
  case badResponse

  public var errorDescription: String? {
    switch self {
    case let .pathTooLong(path): "Socket path is too long: \(path)"
    case let .alreadyRunning(path): "Another LaneBay instance is serving \(path)."
    case let .systemCall(name, code): "\(name) failed: \(String(cString: strerror(code)))"
    case let .notRunning(path): "LaneBay is not running (no control socket at \(path)). Open Lanebay.app first."
    case let .tokenMissing(path): "Control token is missing or unreadable: \(path)"
    case .badResponse: "LaneBay sent a malformed response."
    }
  }
}

/// Paths of the control endpoint. The directory is 0700, the socket and token 0600.
public struct ControlPaths: Sendable, Equatable {
  public let directory: URL
  public var socket: URL { directory.appendingPathComponent("control.sock") }
  public var token: URL { directory.appendingPathComponent("control.token") }

  public init(directory: URL) { self.directory = directory }

  public static func live(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ControlPaths {
    if let override = ProcessInfo.processInfo.environment["LANEBAY_CONTROL_DIR"], !override.isEmpty {
      return ControlPaths(directory: URL(fileURLWithPath: override, isDirectory: true))
    }
    return ControlPaths(directory: homeDirectory.appendingPathComponent("Library/Application Support/Lanebay", isDirectory: true))
  }
}

enum UnixSocketAddress {
  static func make(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw ControlSocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }

  static func connect(_ path: String) throws -> Int32 {
    var address = try make(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlSocketError.systemCall("socket", errno) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
      let code = errno
      close(fd)
      throw ControlSocketError.systemCall("connect", code)
    }
    return fd
  }

  static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if written < 0 { if errno == EINTR { continue }; return false }
        offset += written
      }
      return true
    }
  }

  /// Reads up to the first newline or EOF, bounded by `limit` bytes.
  static func readLine(_ fd: Int32, limit: Int) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count <= limit {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 { if errno == EINTR { continue }; return nil }
      if count == 0 { break }
      data.append(buffer, count: count)
      if let newline = data.firstIndex(of: 0x0A) { return data.prefix(upTo: newline) }
    }
    return data.count <= limit ? data : nil
  }
}

/// Localhost-only control API on a Unix domain socket. Only the same user can connect
/// (0600 socket in a 0700 directory, peer uid check) and every request carries the per-launch token.
public final class ControlServer: @unchecked Sendable {
  public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse
  public static let maximumRequestBytes = 65_536

  public let paths: ControlPaths
  public let token: String
  private let handler: Handler
  private let lock = NSLock()
  private var listenFD: Int32 = -1
  private var stopped = false

  public init(paths: ControlPaths, token: String = ControlServer.makeToken(), handler: @escaping Handler) {
    self.paths = paths
    self.token = token
    self.handler = handler
  }

  public static func makeToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytesShim.fill(&bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  public func start() throws {
    // A client that hangs up early must not kill the app. Console children reset SIGPIPE to default.
    signal(SIGPIPE, SIG_IGN)
    let fm = FileManager.default
    try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(paths.directory.path, 0o700)
    let socketPath = paths.socket.path
    if fm.fileExists(atPath: socketPath) {
      if let fd = try? UnixSocketAddress.connect(socketPath) {
        close(fd)
        throw ControlSocketError.alreadyRunning(socketPath)
      }
      unlink(socketPath)
    }
    var address = try UnixSocketAddress.make(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlSocketError.systemCall("socket", errno) }
    let previousMask = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(previousMask)
    guard bound == 0 else { let code = errno; close(fd); throw ControlSocketError.systemCall("bind", code) }
    chmod(socketPath, 0o600)
    guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw ControlSocketError.systemCall("listen", code) }
    try AtomicPrivateFileWriter.write(Data((token + "\n").utf8), to: paths.token, temporaryPrefix: "control-token")
    chmod(paths.token.path, 0o600)
    lock.withLock { listenFD = fd; stopped = false }
    let thread = Thread { [weak self] in self?.acceptLoop(fd) }
    thread.name = "lanebay.control"
    thread.start()
  }

  public func stop() {
    let fd: Int32 = lock.withLock {
      stopped = true
      let fd = listenFD
      listenFD = -1
      return fd
    }
    guard fd >= 0 else { return }
    shutdown(fd, SHUT_RDWR)
    close(fd)
    unlink(paths.socket.path)
    try? FileManager.default.removeItem(at: paths.token)
  }

  deinit { stop() }

  private func acceptLoop(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      if lock.withLock({ stopped }) { close(client); return }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
    }
  }

  private func serve(_ client: Int32) {
    defer { close(client) }
    var one: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
      respond(client, .failure("Peer is not the current user."))
      return
    }
    guard let line = UnixSocketAddress.readLine(client, limit: Self.maximumRequestBytes) else {
      respond(client, .failure("Request too large or unreadable."))
      return
    }
    guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
      respond(client, .failure("Malformed request."))
      return
    }
    guard Self.constantTimeEqual(request.token, token) else {
      respond(client, .failure("Invalid control token."))
      return
    }
    guard ControlOperation(rawValue: request.op) != nil else {
      respond(client, .failure("Unknown operation '\(request.op)'."))
      return
    }
    let box = ResponseBox()
    let semaphore = DispatchSemaphore(value: 0)
    let handler = self.handler
    Task {
      box.value = await handler(request)
      semaphore.signal()
    }
    semaphore.wait()
    respond(client, box.value ?? .failure("No response."))
  }

  private func respond(_ client: Int32, _ response: ControlResponse) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard var data = try? encoder.encode(response) else { return }
    data.append(0x0A)
    _ = UnixSocketAddress.writeAll(client, data)
  }

  static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count, !x.isEmpty else { return false }
    var diff: UInt8 = 0
    for index in x.indices { diff |= x[index] ^ y[index] }
    return diff == 0
  }
}

private final class ResponseBox: @unchecked Sendable { var value: ControlResponse? }

enum SecRandomCopyBytesShim {
  static func fill(_ bytes: inout [UInt8]) -> Bool {
    arc4random_buf(&bytes, bytes.count)
    return true
  }
}

/// Client used by the `lanebay` CLI and tests.
public struct ControlClient: Sendable {
  public let paths: ControlPaths
  public init(paths: ControlPaths = .live()) { self.paths = paths }

  public func token() throws -> String {
    guard let text = try? String(contentsOf: paths.token, encoding: .utf8) else {
      throw ControlSocketError.tokenMissing(paths.token.path)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func send(op: ControlOperation, args: [String: String] = [:]) throws -> ControlResponse {
    guard FileManager.default.fileExists(atPath: paths.socket.path) else { throw ControlSocketError.notRunning(paths.socket.path) }
    let request = ControlRequest(token: try token(), op: op.rawValue, args: args)
    let fd: Int32
    do { fd = try UnixSocketAddress.connect(paths.socket.path) } catch { throw ControlSocketError.notRunning(paths.socket.path) }
    defer { close(fd) }
    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    guard UnixSocketAddress.writeAll(fd, data),
      let line = UnixSocketAddress.readLine(fd, limit: 4 * 1_048_576) else { throw ControlSocketError.badResponse }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let response = try? decoder.decode(ControlResponse.self, from: line) else { throw ControlSocketError.badResponse }
    return response
  }
}
