import Foundation
import Testing

@testable import Terminatab

@Suite struct TerminalProcessTests {
    @Test func spawnProducesOutputStreamWithData() async throws {
        let proc = try TerminalProcess.spawn(cols: 80, rows: 24)
        defer { proc.close() }

        let output = await collectOutput(
            from: proc.outputStream(),
            until: "$",
            timeout: .seconds(3)
        )
        // Any non-empty output proves the shell launched and wrote a prompt.
        #expect(!output.isEmpty)
    }

    @Test func writeSendsInputBackThroughOutput() async throws {
        let proc = try TerminalProcess.spawn(cols: 80, rows: 24)
        defer { proc.close() }

        let stream = proc.outputStream()
        // Give the shell a moment to print its prompt before issuing input,
        // so the marker doesn't get swallowed by the prompt-rendering chunk.
        try await Task.sleep(for: .milliseconds(200))
        proc.write("echo hello_test_marker\n")

        let output = await collectOutput(
            from: stream,
            until: "hello_test_marker",
            timeout: .seconds(5)
        )
        #expect(output.contains("hello_test_marker"))
    }

    @Test func resizeIsReflectedInSttySize() async throws {
        let proc = try TerminalProcess.spawn(cols: 80, rows: 24)
        defer { proc.close() }

        let stream = proc.outputStream()
        try await Task.sleep(for: .milliseconds(200))

        try proc.resize(cols: 120, rows: 40)
        proc.write("stty size\n")

        let output = await collectOutput(
            from: stream,
            until: "40 120",
            timeout: .seconds(5)
        )
        #expect(output.contains("40 120"))
    }

    @Test func closeFinishesOutputStream() async throws {
        let proc = try TerminalProcess.spawn(cols: 80, rows: 24)
        let stream = proc.outputStream()

        // Drain the prompt, then close. The for-await loop must exit.
        try await Task.sleep(for: .milliseconds(200))
        proc.close()

        // Race the drain against a hard deadline so a broken close() fails
        // the test instead of hanging forever.
        let drainTask = Task<Bool, Never> {
            for await _ in stream {
                if Task.isCancelled { break }
            }
            return !Task.isCancelled
        }
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(3))
            drainTask.cancel()
        }
        let drained = await drainTask.value
        timeoutTask.cancel()

        #expect(drained, "outputStream should finish after close()")
    }

    @Test func spawnUsesLoginShellPrefix() async throws {
        let proc = try TerminalProcess.spawn(cols: 80, rows: 24)
        defer { proc.close() }

        let stream = proc.outputStream()
        try await Task.sleep(for: .milliseconds(200))
        proc.write("echo \"shell0=$0\"\n")

        let output = await collectOutput(
            from: stream,
            until: "shell0=-",
            timeout: .seconds(5)
        )
        #expect(output.contains("shell0=-"),
                "argv[0] should be prefixed with '-' for a login shell")
    }
}

// MARK: - helpers

/// Read from an AsyncStream until `substring` appears in the decoded UTF-8
/// output, or until `timeout` elapses. Returns whatever was collected.
private func collectOutput(
    from stream: AsyncStream<Data>,
    until substring: String,
    timeout: Duration
) async -> String {
    let collector = Task<String, Never> {
        var collected = ""
        for await chunk in stream {
            collected += String(decoding: chunk, as: UTF8.self)
            if collected.contains(substring) {
                return collected
            }
            if Task.isCancelled {
                return collected
            }
        }
        return collected
    }
    let timer = Task<Void, Never> {
        try? await Task.sleep(for: timeout)
        collector.cancel()
    }
    let result = await collector.value
    timer.cancel()
    return result
}
