import Foundation
import Network
import Darwin

public enum AgentHookEvent: String, Codable, Sendable, CaseIterable {
    case sessionStart, sessionEnd, preToolUse, postToolUse, postToolUseFailure
    case permissionRequest, notification, stop, subagentStop
}

public struct AgentEvent: Sendable, Equatable {
    public var agent: String
    public var event: AgentHookEvent
    public var sessionID: String?
    public var cwd: String?
    public var payload: [String: JSONValue]

    public init(agent: String, event: AgentHookEvent, sessionID: String? = nil, cwd: String? = nil, payload: [String: JSONValue] = [:]) {
        self.agent = agent; self.event = event; self.sessionID = sessionID; self.cwd = cwd; self.payload = payload
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) } else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) } else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case let .string(v): try c.encode(v); case let .number(v): try c.encode(v); case let .bool(v): try c.encode(v); case let .object(v): try c.encode(v); case let .array(v): try c.encode(v); case .null: try c.encodeNil() }
    }
}

public enum HookServerError: Error { case alreadyRunning, invalidRequest }

public enum HookRequestParser {
    public static let maximumBodySize = 65_536
    public static func validateContentLength(_ headers: String) throws -> Int {
        let value = headers.split(separator: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame
                ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first
        guard let value, (0...maximumBodySize).contains(value) else { throw HookServerError.invalidRequest }
        return value
    }
    fileprivate static func bearerToken(_ authorization: String) -> String? {
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        return String(authorization.dropFirst(prefix.count))
    }
    public static func parse(headers: String, body: Data, token: String) throws -> (agent: String, event: AgentHookEvent, sessionID: String?, cwd: String?, payload: [String: JSONValue]) {
        guard body.count <= maximumBodySize else { throw HookServerError.invalidRequest }
        guard headers.split(separator: "\r\n").first?.hasPrefix("POST ") == true,
              headers.split(separator: "\r\n").dropFirst().contains(where: { line in
                  let parts = line.split(separator: ":", maxSplits: 1)
                  return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Authorization") == .orderedSame
                      && Self.bearerToken(parts[1].trimmingCharacters(in: .whitespaces)).map { ConstantTimeTokenComparison.matches($0, token: token) } == true
              }),
              let path = headers.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init),
              path.hasPrefix("/hook/"), let agent = path.split(separator: "/").last.map(String.init) else { throw HookServerError.invalidRequest }
        guard let data = try? JSONDecoder().decode(HookServer.IncomingHook.self, from: body),
              let event = AgentHookEvent(rawValue: data.event) else { throw HookServerError.invalidRequest }
        return (agent, event, data.sessionID, data.cwd, data.payload)
    }
}

public enum ConstantTimeTokenComparison {
    public static func matches(_ candidate: String, token: String) -> Bool {
        let lhs = Array(candidate.utf8), rhs = Array(token.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

/// A loopback-only, bounded HTTP hook receiver. Its stream has one consumer.
public final class HookServer: @unchecked Sendable {
    public let port: UInt16
    public let token: String
    public let events: AsyncStream<AgentEvent>
    private let listener: NWListener
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let queue = DispatchQueue(label: "Lanebay.HookServer")

    public init() throws {
        let pair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream; continuation = pair.continuation
        let generatedToken = Self.randomToken()
        token = generatedToken
        let connectionHandler: @Sendable (NWConnection) -> Void = { [queue, continuation, generatedToken] connection in
            Self.receive(connection, token: generatedToken, continuation: continuation, queue: queue)
        }
        var selected: (NWListener, UInt16)?
        for _ in 0..<5 {
            let candidate = UInt16.random(in: 49_152...65_535)
            guard let endpointPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            let attempt = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            attempt.newConnectionHandler = connectionHandler
            attempt.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
                if case .failed = state { ready.signal() }
            }
            attempt.start(queue: queue)
            if ready.wait(timeout: .now() + .milliseconds(150)) == .success, case .ready = attempt.state {
                selected = (attempt, candidate)
                break
            }
            attempt.cancel()
        }
        guard let (newListener, assigned) = selected else { throw HookServerError.invalidRequest }
        port = assigned
        listener = newListener
        newListener.stateUpdateHandler = nil
    }

    public func stop() { listener.cancel(); continuation.finish() }

    public func writeRuntime(to hooksRoot: URL) throws {
        try HookRuntimeFile.write(port: port, token: token, to: hooksRoot)
    }

    private static func receive(_ connection: NWConnection, token: String, continuation: AsyncStream<AgentEvent>.Continuation, queue: DispatchQueue) {
        guard case let .hostPort(host: .ipv4(address), _) = connection.endpoint,
              Array(address.rawValue).first == 127 else { connection.cancel(); return }
        connection.start(queue: queue)
        read(connection, data: Data(), token: token, continuation: continuation, queue: queue)
    }

    private static func read(_ connection: NWConnection, data: Data, token: String, continuation: AsyncStream<AgentEvent>.Continuation, queue: DispatchQueue) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { part, _, complete, error in
            let combined = data + (part ?? Data())
            guard combined.count <= HookRequestParser.maximumBodySize + 8192 else { respond(connection, status: 413); return }
            if let range = combined.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = combined[..<range.lowerBound]
                guard let header = String(data: headerData, encoding: .utf8), let length = try? HookRequestParser.validateContentLength(header) else { respond(connection, status: 413); return }
                let bodyStart = range.upperBound
                let body = combined[bodyStart...]
                guard body.count >= length else { if complete || error != nil { respond(connection, status: 400) } else { read(connection, data: combined, token: token, continuation: continuation, queue: queue) }; return }
                guard let parsed = try? HookRequestParser.parse(headers: header, body: Data(body.prefix(length)), token: token) else {
                    let status = validHeaders(header, token: token) ? 400 : 401
                    respond(connection, status: status); return
                }
                continuation.yield(AgentEvent(agent: parsed.agent, event: parsed.event, sessionID: parsed.sessionID, cwd: parsed.cwd, payload: parsed.payload))
                respond(connection, status: 204); return
            }
            guard !complete, error == nil else { respond(connection, status: 400); return }
            read(connection, data: combined, token: token, continuation: continuation, queue: queue)
        }
    }

    private static func respond(_ connection: NWConnection, status: Int) {
        let reason = status == 204 ? "No Content" : status == 413 ? "Payload Too Large" : status == 401 ? "Unauthorized" : "Bad Request"
        let response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    private static func path(_ headers: String) -> String? { headers.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) }
    private static func validHeaders(_ headers: String, token: String) -> Bool {
        headers.split(separator: "\r\n").dropFirst().contains { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Authorization") == .orderedSame
                && HookRequestParser.bearerToken(parts[1].trimmingCharacters(in: .whitespaces)).map { ConstantTimeTokenComparison.matches($0, token: token) } == true
        } && headers.split(separator: "\r\n").first?.hasPrefix("POST ") == true
    }
    private static func randomToken() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    fileprivate static func writePrivately(_ data: Data, to destination: URL, permissions: Int) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var succeeded = false
        defer { _ = close(descriptor); if !succeeded { try? FileManager.default.removeItem(at: temporary) } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        succeeded = true
    }
    fileprivate struct IncomingHook: Decodable {
        let event: String; let sessionID: String?; let cwd: String?; let payload: [String: JSONValue]
        struct Key: CodingKey { var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; var intValue: Int? { nil }; init?(intValue: Int) { return nil } }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            event = try c.decode(String.self, forKey: Key(stringValue: "event")!); sessionID = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "session_id")!); cwd = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "cwd")!)
            payload = Dictionary(uniqueKeysWithValues: try c.allKeys.filter { !["event", "session_id", "cwd"].contains($0.stringValue) }.map { ($0.stringValue, try c.decode(JSONValue.self, forKey: $0)) })
        }
    }
}

enum HookRuntimeFile {
    static func write(port: UInt16, token: String, to hooksRoot: URL) throws {
        try FileManager.default.createDirectory(at: hooksRoot, withIntermediateDirectories: true)
        let url = hooksRoot.appendingPathComponent("runtime.json")
        let data = try JSONSerialization.data(withJSONObject: ["port": port, "token": token])
        try HookServer.writePrivately(data, to: url, permissions: 0o600)
    }
}

public struct HookScriptInstaller {
    public init() {}
    public func install(to hooksRoot: URL) throws {
        try FileManager.default.createDirectory(at: hooksRoot, withIntermediateDirectories: true)
        let script = "#!/bin/sh\ninput=$(cat) || exit 0\n[ -r \"$HOME/.lanebay/hooks/runtime.json\" ] || exit 0\nport=$(/usr/bin/plutil -extract port raw -o - \"$HOME/.lanebay/hooks/runtime.json\" 2>/dev/null) || exit 0\ntoken=$(/usr/bin/plutil -extract token raw -o - \"$HOME/.lanebay/hooks/runtime.json\" 2>/dev/null) || exit 0\nevent=$2\n[ -n \"$event\" ] || exit 0\nbody=$(printf '%s' \"$input\" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); d[\"event\"]=sys.argv[1]; print(json.dumps(d))' \"$event\" 2>/dev/null) || exit 0\nprintf '%s' \"$body\" | /usr/bin/curl --silent --max-time 1 --output /dev/null -X POST -H \"Authorization: Bearer $token\" -H 'Content-Type: application/json' --data-binary @- \"http://127.0.0.1:$port/hook/$1\" >/dev/null 2>&1 || true\nexit 0\n"
        let url = hooksRoot.appendingPathComponent("lanebay-hook.sh")
        try HookServer.writePrivately(Data(script.utf8), to: url, permissions: 0o700)
    }
}
