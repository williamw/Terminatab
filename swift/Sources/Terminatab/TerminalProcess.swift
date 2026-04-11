import Darwin
import Foundation
import SwiftTerm

/// Wraps SwiftTerm's `LocalProcess` and adapts its push-based delegate
/// callbacks to an `AsyncStream<Data>` that the rest of the app already
/// consumes (see `WebSocketConnection.startPTYReadLoop`).
///
/// This replaces the previous hand-rolled `forkpty` wrapper. SwiftTerm's
/// `LocalProcess` brings a `DispatchIO` read loop, a `DispatchSourceProcess`
/// child-exit watcher, and proper login-shell `argv[0]` support.
final class TerminalProcess: @unchecked Sendable {
    enum TerminalProcessError: Error {
        case startFailed
        case resizeFailed
    }

    private let lp: LocalProcess
    private let delegateBox: DelegateBox
    private let lock = NSLock()
    private var currentSize: winsize
    private var continuation: AsyncStream<Data>.Continuation?
    private var pendingChunks: [Data] = []
    private var closed = false

    private init(size: winsize) {
        self.currentSize = size
        self.delegateBox = DelegateBox()
        // Dedicated serial queue: keeps dataReceived ordered, off the main queue.
        let queue = DispatchQueue(label: "terminatab.localprocess")
        self.lp = LocalProcess(delegate: delegateBox, dispatchQueue: queue)
        // LocalProcess holds the delegate weakly; the box is owned by self.
        // The box references self weakly to avoid a retain cycle.
        delegateBox.owner = self
    }

    /// Spawn a login shell in a fresh PTY with the given dimensions.
    static func spawn(shell: String? = nil, cols: UInt16, rows: UInt16) throws -> TerminalProcess {
        let shellPath = shell
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        let basename = (shellPath as NSString).lastPathComponent
        // Login-shell convention: argv[0] is "-<shellname>".
        let execName = "-" + basename

        let ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let proc = TerminalProcess(size: ws)

        // Inherit the parent environment, then override the bits we care about.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        proc.lp.startProcess(
            executable: shellPath,
            args: [],
            environment: envStrings,
            execName: execName
        )
        guard proc.lp.running else { throw TerminalProcessError.startFailed }
        return proc
    }

    /// Write raw bytes to the PTY master.
    func write(_ data: [UInt8]) {
        lp.send(data: data[...])
    }

    /// Write a UTF-8 string to the PTY master.
    func write(_ string: String) {
        let bytes = Array(string.utf8)
        lp.send(data: bytes[...])
    }

    /// Resize the PTY. SwiftTerm only reads `winsize` once at fork time, so
    /// dynamic resize requires an explicit `ioctl(TIOCSWINSZ)` on the master fd.
    func resize(cols: UInt16, rows: UInt16) throws {
        lock.lock()
        currentSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var ws = currentSize
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { throw TerminalProcessError.resizeFailed }
        guard ioctl(lp.childfd, TIOCSWINSZ, &ws) == 0 else {
            throw TerminalProcessError.resizeFailed
        }
    }

    /// Push-to-pull adapter: yields each chunk SwiftTerm hands us via the
    /// delegate. Single-consumer; calling this twice replaces the previous
    /// continuation. Bytes that arrived between `spawn()` and the first
    /// `outputStream()` call are buffered and replayed on attach — necessary
    /// because `LocalProcess` starts reading from the PTY immediately and the
    /// shell's first prompt usually races the WebSocket task that sets up the
    /// stream.
    func outputStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            lock.lock()
            let pending = pendingChunks
            pendingChunks.removeAll()
            self.continuation = continuation
            let alreadyClosed = closed
            lock.unlock()

            for chunk in pending {
                continuation.yield(chunk)
            }

            if alreadyClosed {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuation = nil
                self.lock.unlock()
            }
        }
    }

    /// Force the session to end. Closing the master fd causes the kernel to
    /// deliver SIGHUP to the child's foreground process group on its next I/O.
    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        if !alreadyClosed && lp.running {
            // Only close if LocalProcess hasn't already closed the fd internally
            // (it does so when the child exits naturally and processTerminated fires).
            Darwin.close(lp.childfd)
        }
        finishStream()
    }

    // MARK: - Delegate callbacks (called from the LocalProcess dispatch queue)

    fileprivate func handleData(_ slice: ArraySlice<UInt8>) {
        // CRITICAL: copy synchronously. SwiftTerm reuses an 8 KB DispatchIO
        // buffer across callbacks; the slice is invalid the moment
        // dataReceived returns. With binary WebSocket frames there is no
        // defensive re-encoding to mask corruption. Do not "optimize" this.
        let data = Data(slice)
        lock.lock()
        if let c = continuation {
            lock.unlock()
            c.yield(data)
        } else {
            // No consumer attached yet — buffer for replay on outputStream().
            pendingChunks.append(data)
            lock.unlock()
        }
    }

    fileprivate func handleTerminated(_ exitCode: Int32?) {
        lock.lock()
        closed = true
        lock.unlock()
        finishStream()
    }

    fileprivate func currentWinsize() -> winsize {
        lock.lock(); defer { lock.unlock() }
        return currentSize
    }

    private func finishStream() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.finish()
    }
}

/// Concrete delegate object held strongly by `TerminalProcess`. Necessary
/// because `LocalProcess.delegate` is a weak reference.
private final class DelegateBox: LocalProcessDelegate {
    weak var owner: TerminalProcess?

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        owner?.handleTerminated(exitCode)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        owner?.handleData(slice)
    }

    func getWindowSize() -> winsize {
        owner?.currentWinsize()
            ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}
