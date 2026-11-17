import Foundation

/// Runs a child process to completion. Output is drained while the process
/// runs, so chatty tools (uv, PyTorch) can't fill a pipe and stall, and the
/// process is terminated if the calling task is cancelled.
enum ProcessRunner {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
    }

    struct Failure: LocalizedError {
        let executableName: String
        let status: Int32
        let stderr: String

        var errorDescription: String? {
            let tail = stderr.split(separator: "\n").suffix(8)
                .joined(separator: "\n")
            return tail.isEmpty
                ? "\(executableName) exited with status \(status)."
                : "\(executableName) exited with status \(status): \(tail)"
        }
    }

    static func run(
        _ executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = OutputBuffer()
        let stderr = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdout.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }

        let handle = ProcessHandle(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                    // Cancelled before launch: onCancel found nothing
                    // running, so stop it here.
                    if Task.isCancelled {
                        handle.terminate()
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.terminate()
        }

        for (pipe, buffer) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
            pipe.fileHandleForReading.readabilityHandler = nil
            buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        }
        try Task.checkCancellation()

        guard status == 0 else {
            throw Failure(
                executableName: executableURL.lastPathComponent,
                status: status,
                stderr: stderr.string
            )
        }
        return Output(stdout: stdout.string, stderr: stderr.string)
    }
}

/// Keeps the last `limit` bytes of a stream; errors only need the tail.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 256 * 1024

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lets the cancellation handler, which may run on any thread, stop the
/// process. Process is thread-safe for terminate/isRunning.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}
