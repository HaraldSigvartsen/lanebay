import Darwin
import Foundation

public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var columns: UInt16
    public var rows: UInt16
    public var scrollbackBytes: Int

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        columns: UInt16 = 80,
        rows: UInt16 = 24,
        scrollbackBytes: Int = 1_048_576
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.scrollbackBytes = max(0, scrollbackBytes)
    }
}

public enum ProcessEvent: Sendable, Equatable {
    case output(Data)
    case exited(code: Int32, signal: Int32?)
    case failed(String)
}

public enum ProcessSupervisorError: Error, LocalizedError {
    case sessionNotFound
    case systemCall(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound: "The process session does not exist."
        case let .systemCall(operation, code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Coalesces level-triggered PTY read events so only one drain runs at a time.
private final class ReadScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func tryStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if started { return false }
        started = true
        return true
    }

    func stop() {
        lock.lock()
        started = false
        lock.unlock()
    }
}

/// Owns interactive child processes and their pseudo terminals.
public actor ProcessSupervisor {
    /// Fixed-capacity byte ring; appending never shifts the retained history.
    private struct Scrollback {
        var bytes: [UInt8]
        var next = 0
        var count = 0

        init(capacity: Int) { bytes = Array(repeating: 0, count: max(0, capacity)) }

        mutating func append(_ data: Data) {
            guard !bytes.isEmpty else { return }
            for byte in data.suffix(bytes.count) {
                bytes[next] = byte
                next = (next + 1) % bytes.count
                count = min(count + 1, bytes.count)
            }
        }

        var data: Data {
            let start = (next + bytes.count - count) % max(1, bytes.count)
            let firstCount = min(count, bytes.count - start)
            return Data(bytes[start..<(start + firstCount)] + bytes.prefix(count - firstCount))
        }
    }

    private struct Session {
        let masterFD: Int32
        let processGroup: pid_t
        let continuation: AsyncStream<ProcessEvent>.Continuation
        let writeQueue = DispatchQueue(label: "Lanebay.PTY.write")
        var scrollback: Scrollback
        var outputQueue: [Data] = []
        /// Short reads sit here until they fill a chunk or the stream has been quiet.
        var outputPartial = Data()
        var queuedOutputBytes = 0
        var outputEnded = false
        var waitStatus: Int32?
        var waitError: String?
        var terminationTask: Task<Void, Never>?
        var escalationSent = false
        var readSource: DispatchSourceRead?
        var readSourceSuspended = false
        /// True only after `DispatchSource.suspend()` until the matching `resume()`.
        var kernelReadSuspended = false
        let readScheduler = ReadScheduler()
        var outputStreamBackpressured = false
        var drainRetryTask: Task<Void, Never>?
        let outputHighWaterBytes: Int
        let outputLowWaterBytes: Int

        init(masterFD: Int32, processGroup: pid_t, continuation: AsyncStream<ProcessEvent>.Continuation, scrollback: Scrollback, outputHighWaterBytes: Int, outputLowWaterBytes: Int) {
            self.masterFD = masterFD
            self.processGroup = processGroup
            self.continuation = continuation
            self.scrollback = scrollback
            self.outputHighWaterBytes = outputHighWaterBytes
            self.outputLowWaterBytes = outputLowWaterBytes
        }
    }

    private var sessions: [SessionID: Session] = [:]
    private var completedScrollback: [SessionID: Data] = [:]
    private let outputQueueHighWaterBytes = 1_048_576
    private let outputQueueLowWaterBytes = 524_288
    private let streamLowRemainingSlots = 8

    public init() {}

    /// Starts a login shell which resolves and executes the requested command.
    /// `zsh -lc` loads login startup files before resolving the command in PATH.
    public func start(spec: ProcessSpec) throws -> StartedProcessSession {
        let id = SessionID()
        let (stream, continuation) = AsyncStream<ProcessEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let environment = ProcessSupervisor.loginEnvironment(overrides: spec.environment)
        // Resolve bare commands in the login shell, after its startup files set PATH.
        let shellCommand = "exec " + ([spec.executable] + spec.arguments).map(Self.shellQuote).joined(separator: " ")
        let arguments: [UnsafeMutablePointer<CChar>?] = ["zsh", "-lc", shellCommand].map { value in value.withCString { strdup($0) } } + [nil]
        let environmentPointers: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let directory = strdup(spec.workingDirectory.path)!
        let shell = strdup("/bin/zsh")!
        defer {
            arguments.forEach { free($0) }
            environmentPointers.forEach { free($0) }
            free(directory)
            free(shell)
        }
        var childSignalMask = sigset_t()
        sigemptyset(&childSignalMask)
        var defaultSignalAction = sigaction()
        defaultSignalAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultSignalAction.sa_mask)
        var master: Int32 = -1
        var window = winsize(ws_row: spec.rows, ws_col: spec.columns, ws_xpixel: 0, ws_ypixel: 0)
        let child = arguments.withUnsafeBufferPointer { argv in
            environmentPointers.withUnsafeBufferPointer { env in
                let argvPointer = UnsafeMutablePointer(mutating: argv.baseAddress!)
                let envPointer = env.baseAddress!
                let pid = forkpty(&master, nil, nil, &window)
                if pid == 0 {
                    // Only async-signal-safe calls between fork and exec.
                    // Dispatch threads can block signals; hosts may ignore terminal signals.
                    if sigaction(SIGTERM, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGINT, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGQUIT, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGHUP, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGPIPE, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGCHLD, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGTSTP, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGTTIN, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigaction(SIGTTOU, &defaultSignalAction, nil) != 0 { _exit(126) }
                    if sigprocmask(SIG_SETMASK, &childSignalMask, nil) != 0 { _exit(126) }
                    if chdir(directory) != 0 { _exit(126) }
                    execve(shell, argvPointer, envPointer)
                    _exit(127)
                }
                return pid
            }
        }
        guard child >= 0 else { throw ProcessSupervisorError.systemCall("forkpty", errno) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        sessions[id] = Session(
            masterFD: master,
            processGroup: child,
            continuation: continuation,
            scrollback: Scrollback(capacity: spec.scrollbackBytes),
            outputHighWaterBytes: outputQueueHighWaterBytes,
            outputLowWaterBytes: outputQueueLowWaterBytes
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.terminate(id) }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
        let scheduler = sessions[id]!.readScheduler
        // Level-triggered sources keep calling the handler while the fd is readable.
        // Coalesce to one actor read; that read suspends or cancels the source before returning.
        source.setEventHandler { [weak self] in
            guard scheduler.tryStart() else { return }
            Task { await self?.readAvailableOutput(for: id) }
        }
        source.resume()
        sessions[id]?.readSource = source
        DispatchQueue.global().async { [self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &status, 0) } while result < 0 && errno == EINTR
            let error = result < 0 ? "waitpid failed: \(String(cString: strerror(errno)))" : nil
            let reapedStatus = status
            Task { await self.reaped(id, status: reapedStatus, error: error) }
        }
        return StartedProcessSession(id: id, events: stream)
    }

    public func write(_ bytes: Data, to id: SessionID) async throws {
        guard let session = sessions[id] else { throw ProcessSupervisorError.sessionNotFound }
        // Keep this descriptor valid across actor suspension and session cleanup.
        let fd = fcntl(session.masterFD, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw ProcessSupervisorError.systemCall("dup", errno) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            session.writeQueue.async {
                defer { Darwin.close(fd) }
                do {
                    try bytes.withUnsafeBytes { buffer in
                        guard let base = buffer.baseAddress else { return }
                        var offset = 0
                        while offset < buffer.count {
                            let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                            if written < 0 && errno == EINTR { continue }
                            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                                _ = Darwin.poll(&descriptor, 1, 100)
                                continue
                            }
                            guard written > 0 else {
                                throw ProcessSupervisorError.systemCall("write", written == 0 ? EIO : errno)
                            }
                            offset += written
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func windowSize(for id: SessionID) throws -> (columns: UInt16, rows: UInt16) {
        guard let session = sessions[id] else { throw ProcessSupervisorError.sessionNotFound }
        var window = winsize()
        guard ioctl(session.masterFD, TIOCGWINSZ, &window) == 0 else {
            throw ProcessSupervisorError.systemCall("ioctl(TIOCGWINSZ)", errno)
        }
        return (window.ws_col, window.ws_row)
    }

    public func resize(_ columns: UInt16, _ rows: UInt16, for id: SessionID) throws {
        guard let session = sessions[id] else { throw ProcessSupervisorError.sessionNotFound }
        var window = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(session.masterFD, TIOCSWINSZ, &window) == 0 else {
            throw ProcessSupervisorError.systemCall("ioctl(TIOCSWINSZ)", errno)
        }
    }

    public func terminate(_ id: SessionID, gracePeriod: Duration = .milliseconds(500)) {
        guard var session = sessions[id], session.terminationTask == nil else { return }
        if kill(-session.processGroup, SIGTERM) != 0 && errno == ESRCH && session.waitStatus == nil {
            // forkpty's child may not have established its process group yet.
            _ = kill(session.processGroup, SIGTERM)
        }
        session.terminationTask = Task { [weak self] in
            try? await Task.sleep(for: gracePeriod)
            guard !Task.isCancelled else { return }
            await self?.sendKill(id)
        }
        sessions[id] = session
    }

    public func scrollback(for id: SessionID) throws -> Data {
        if let session = sessions[id] { return session.scrollback.data }
        if let data = completedScrollback[id] { return data }
        throw ProcessSupervisorError.sessionNotFound
    }

    func bufferedOutputByteCount(for id: SessionID) throws -> Int {
        guard let session = sessions[id] else { throw ProcessSupervisorError.sessionNotFound }
        return session.queuedOutputBytes
    }

    func outputReadPaused(for id: SessionID) throws -> Bool {
        guard let session = sessions[id] else { throw ProcessSupervisorError.sessionNotFound }
        return session.readSourceSuspended
    }

    func outputHighWaterMark(for id: SessionID) throws -> Int {
        guard let session = sessions[id] else { throw ProcessSupervisorError.sessionNotFound }
        return session.outputHighWaterBytes
    }

    /// Releases a completed session's retained history. Active sessions are unaffected.
    public func discardScrollback(for id: SessionID) {
        completedScrollback.removeValue(forKey: id)
    }

    private func sendKill(_ id: SessionID) {
        guard var session = sessions[id] else { return }
        if kill(-session.processGroup, SIGKILL) != 0 && errno == ESRCH && session.waitStatus == nil {
            _ = kill(session.processGroup, SIGKILL)
        }
        session.escalationSent = true
        sessions[id] = session
        finishIfReady(id)
    }

    private func receive(_ data: Data, for id: SessionID) {
        guard var session = sessions[id], !data.isEmpty else { return }
        session.scrollback.append(data)
        enqueueOutput(data, into: &session)
        session.queuedOutputBytes += data.count
        sessions[id] = session
        if session.queuedOutputBytes >= session.outputHighWaterBytes {
            suspendReadSource(id)
        }
        drainOutputQueue(id)
    }

    /// A short tail must not wait for another 16 KiB. Call this when the PTY has nothing more ready.
    private func flushPartialOutput(_ id: SessionID) {
        guard var session = sessions[id], !session.outputPartial.isEmpty else { return }
        flushOutputPartial(&session)
        sessions[id] = session
        drainOutputQueue(id)
    }

    /// Join short reads into 16 KiB yields. A line at a time would leave the completion marker behind thousands of stream events.
    private func enqueueOutput(_ data: Data, into session: inout Session) {
        let chunkLimit = 16_384
        session.outputPartial.append(data)
        while session.outputPartial.count >= chunkLimit {
            session.outputQueue.append(Data(session.outputPartial.prefix(chunkLimit)))
            session.outputPartial.removeFirst(chunkLimit)
        }
    }

    private func flushOutputPartial(_ session: inout Session) {
        guard !session.outputPartial.isEmpty else { return }
        session.outputQueue.append(session.outputPartial)
        session.outputPartial.removeAll(keepingCapacity: true)
    }

    private func reaped(_ id: SessionID, status: Int32, error: String?) {
        guard var session = sessions[id] else { return }
        session.waitStatus = status
        session.waitError = error
        let needsReadKick = session.readSourceSuspended
        sessions[id] = session
        if needsReadKick { resumeReadSource(id) }
        finishIfReady(id)
    }

    private func outputEnded(_ id: SessionID, error: String?) {
        guard var session = sessions[id], !session.outputEnded else { return }
        session.outputEnded = true
        if let error { session.continuation.yield(.failed(error)) }
        sessions[id] = session
        finishIfReady(id)
    }

    private func finishIfReady(_ id: SessionID) {
        guard var session = sessions[id], session.outputEnded, let status = session.waitStatus else { return }
        // macOS can revoke the PTY when its leader exits while descendants survive.
        // Keep the grace timer alive until the remaining process group is killed.
        if session.terminationTask != nil && !session.escalationSent {
            if kill(-session.processGroup, 0) == 0 || errno == EPERM { return }
        }
        flushOutputPartial(&session)
        session.drainRetryTask?.cancel()
        session.drainRetryTask = nil
        sessions[id] = session
        drainOutputQueue(id)
        guard var session = sessions[id] else { return }
        cancelReadSource(&session)
        sessions.removeValue(forKey: id)
        completedScrollback[id] = session.scrollback.data
        session.terminationTask?.cancel()
        session.drainRetryTask?.cancel()
        if let error = session.waitError {
            session.continuation.yield(.failed(error))
        } else {
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            session.continuation.yield(.exited(code: code, signal: signal == 0 ? nil : signal))
        }
        session.continuation.finish()
        Darwin.close(session.masterFD)
    }

    private func readAvailableOutput(for id: SessionID) {
        let scheduler = sessions[id]?.readScheduler
        defer { scheduler?.stop() }
        guard let session = sessions[id], !session.readSourceSuspended, !session.outputEnded else { return }
        if session.queuedOutputBytes >= session.outputHighWaterBytes {
            suspendReadSource(id)
            return
        }
        let fd = session.masterFD
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            guard let current = sessions[id], !current.readSourceSuspended, !current.outputEnded else { return }
            let readBudget = current.outputHighWaterBytes - current.queuedOutputBytes
            // The previous read may have filled only part of the buffer. Size this read to what is still allowed.
            if readBudget <= 0 {
                flushPartialOutput(id)
                suspendReadSource(id)
                return
            }
            var count: Int
            repeat { count = Darwin.read(fd, &buffer, min(buffer.count, readBudget)) } while count < 0 && errno == EINTR
            if count > 0 {
                receive(Data(buffer.prefix(count)), for: id)
                if sessions[id]?.readSourceSuspended == true { return }
                continue
            }
            if count == 0 {
                flushPartialOutput(id)
                cancelReadSource(id)
                outputEnded(id, error: nil)
                return
            }
            let error = errno
            if error == EAGAIN || error == EWOULDBLOCK {
                flushPartialOutput(id)
                return
            }
            // A PTY may report EIO when its final slave descriptor closes.
            // Cancel first so a level-triggered EOF cannot queue reads forever.
            cancelReadSource(id)
            outputEnded(id, error: error == EIO ? nil : "read failed: \(String(cString: strerror(error)))")
            return
        }
    }

    private func drainOutputQueue(_ id: SessionID) {
        guard var session = sessions[id] else { return }
        var emitted = 0
        while let chunk = session.outputQueue.first, emitted < 32 {
            switch session.continuation.yield(.output(chunk)) {
            case .enqueued(let remaining):
                session.outputQueue.removeFirst()
                session.queuedOutputBytes -= chunk.count
                emitted += 1
                if remaining <= streamLowRemainingSlots {
                    session.outputStreamBackpressured = true
                    sessions[id] = session
                    // Coalesced chunks fill the 64-slot stream before the byte queue does.
                    // Stop reading or bufferingNewest discards output the consumer has not seen.
                    suspendReadSource(id)
                    scheduleDrainRetry(id)
                    return
                }
                session.outputStreamBackpressured = false
            case .dropped:
                session.outputStreamBackpressured = true
                sessions[id] = session
                suspendReadSource(id)
                scheduleDrainRetry(id)
                return
            case .terminated:
                session.outputQueue.removeAll(keepingCapacity: false)
                session.queuedOutputBytes = 0
                session.outputStreamBackpressured = false
                sessions[id] = session
                return
            @unknown default:
                session.outputStreamBackpressured = true
                sessions[id] = session
                suspendReadSource(id)
                scheduleDrainRetry(id)
                return
            }
        }
        // The stream was full and every coalesced chunk has been handed off.
        // Clear the flag so the next retry resumes reads outside this turn and learns if the consumer caught up.
        if session.outputQueue.isEmpty && session.outputStreamBackpressured && session.readSourceSuspended {
            session.outputStreamBackpressured = false
            sessions[id] = session
            scheduleDrainRetry(id)
            return
        }
        if session.queuedOutputBytes <= session.outputLowWaterBytes, !session.outputStreamBackpressured {
            sessions[id] = session
            resumeReadSource(id)
            // resume reads more output; keep that session instead of restoring the pre-resume copy.
            guard let refreshed = sessions[id] else { return }
            session = refreshed
        }
        if session.outputQueue.isEmpty && !session.readSourceSuspended {
            session.outputStreamBackpressured = false
        }
        if needsDrainRetry(session) {
            if session.drainRetryTask == nil {
                sessions[id] = session
                scheduleDrainRetry(id)
                return
            }
        } else {
            session.drainRetryTask?.cancel()
            session.drainRetryTask = nil
        }
        sessions[id] = session
    }

    private func needsDrainRetry(_ session: Session) -> Bool {
        !session.outputQueue.isEmpty || session.outputStreamBackpressured || session.readSourceSuspended
    }

    private func scheduleDrainRetry(_ id: SessionID) {
        guard var session = sessions[id], session.drainRetryTask == nil else { return }
        session.drainRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            await self?.clearDrainRetryAndDrain(id)
        }
        sessions[id] = session
    }

    private func clearDrainRetryAndDrain(_ id: SessionID) {
        guard var session = sessions[id] else { return }
        session.drainRetryTask = nil
        flushOutputPartial(&session)
        sessions[id] = session
        drainOutputQueue(id)
    }

    private func suspendReadSource(_ id: SessionID) {
        guard var session = sessions[id], let source = session.readSource, !session.readSourceSuspended else { return }
        session.readSourceSuspended = true
        session.kernelReadSuspended = true
        sessions[id] = session
        source.suspend()
    }

    private func resumeReadSource(_ id: SessionID) {
        guard var session = sessions[id], let source = session.readSource, session.readSourceSuspended else { return }
        session.readSourceSuspended = false
        let needsKernelResume = session.kernelReadSuspended
        session.kernelReadSuspended = false
        sessions[id] = session
        if needsKernelResume {
            source.resume()
        } else {
            readAvailableOutput(for: id)
        }
    }

    /// `cancel` on a suspended source traps. Resume first when this actor suspended it.
    private func cancelReadSource(_ id: SessionID) {
        guard var session = sessions[id] else { return }
        cancelReadSource(&session)
        sessions[id] = session
    }

    private func cancelReadSource(_ session: inout Session) {
        guard let source = session.readSource else { return }
        if session.kernelReadSuspended {
            source.resume()
            session.kernelReadSuspended = false
        }
        session.readSourceSuspended = false
        session.readSource = nil
        source.cancel()
    }

    public nonisolated static func resolveExecutable(_ executable: String, path: String?) -> String {
        if executable.hasPrefix("/") { return executable }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = (path ?? "").split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin"
        ]
        for directory in candidates {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return executable
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func loginEnvironment(overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(overrides) { _, new in new }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["/opt/homebrew/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin"]
        environment["PATH"] = ([environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"] + extras).joined(separator: ":")
        // The host terminal's COLUMNS is not this PTY. The shell must use TIOCSWINSZ.
        environment.removeValue(forKey: "COLUMNS")
        environment.removeValue(forKey: "LINES")
        environment.removeValue(forKey: "TERMCAP")
        return environment
    }
}

public struct StartedProcessSession: Sendable {
    public let id: SessionID
    public let events: AsyncStream<ProcessEvent>

    public init(id: SessionID, events: AsyncStream<ProcessEvent>) {
        self.id = id
        self.events = events
    }
}
