import Foundation

enum AsyncDeadlineError: LocalizedError {
    case exceeded(String)

    var errorDescription: String? {
        switch self {
        case .exceeded(let operation):
            return "\(operation) exceeded its deadline."
        }
    }
}

/// Returns as soon as either task wins. Unlike a structured task-group race,
/// this does not wait for a misbehaving framework call after its cancellation.
private final class AsyncDeadlineGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let ready: Result<Value, Error>?
        lock.lock()
        if let result {
            ready = result
        } else {
            self.continuation = continuation
            ready = nil
        }
        lock.unlock()
        if let ready { continuation.resume(with: ready) }
    }

    func retain(_ task: Task<Void, Never>) {
        lock.lock()
        if result == nil {
            tasks.append(task)
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    func resolve(_ newResult: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        let tasks: [Task<Void, Never>]
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        continuation = self.continuation
        self.continuation = nil
        tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()

        continuation?.resume(with: newResult)
        tasks.forEach { $0.cancel() }
    }
}

func withAsyncDeadline<Value: Sendable>(
    _ duration: Duration,
    operationName: String,
    onTimeout: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let gate = AsyncDeadlineGate<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)

            let work = Task {
                do {
                    gate.resolve(.success(try await operation()))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            gate.retain(work)

            let timer = Task {
                do {
                    try await Task.sleep(for: duration)
                    gate.resolve(.failure(AsyncDeadlineError.exceeded(operationName)))
                    // Cleanup must never weaken the deadline contract. Some
                    // framework cancellation hooks are themselves allowed to
                    // stall, so notify the caller first and clean up detached
                    // from the race.
                    Task { await onTimeout() }
                } catch {
                    // The work won or the parent was cancelled.
                }
            }
            gate.retain(timer)
        }
    } onCancel: {
        gate.resolve(.failure(CancellationError()))
        Task { await onTimeout() }
    }
}
