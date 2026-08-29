import Foundation

enum HighQualityRuntimeMemorySampler {
    static func measure<Value>(
        _ operation: () async throws -> Value
    ) async throws -> (value: Value, peakMemoryBytes: UInt64) {
        let sampler = Task {
            var peak = WhisperKitRuntime.currentMemoryBytes()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                peak = max(peak, WhisperKitRuntime.currentMemoryBytes())
            }
            return max(peak, WhisperKitRuntime.currentMemoryBytes())
        }
        do {
            let value = try await operation()
            sampler.cancel()
            return (value, await sampler.value)
        } catch {
            sampler.cancel()
            _ = await sampler.value
            throw error
        }
    }
}
