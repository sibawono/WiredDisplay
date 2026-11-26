import Foundation

/// Rolling stage latency and drop-reason tracker for pipeline diagnostics.
public struct PipelineMetrics: Sendable {
    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let p50Ms: Double
        public let p95Ms: Double
        public let p99Ms: Double
        public let maxMs: Double
        public let encoderDrops: UInt64
        public let networkDrops: UInt64
        public let decoderDrops: UInt64
    }

    private var samples: [Double] = []
    private let capacity: Int
    public private(set) var encoderDrops: UInt64 = 0
    public private(set) var networkDrops: UInt64 = 0
    public private(set) var decoderDrops: UInt64 = 0

    public init(capacity: Int = 300) {
        self.capacity = max(1, capacity)
        self.samples.reserveCapacity(self.capacity)
    }

    public mutating func recordLatencyMs(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        if samples.count >= capacity {
            samples.removeFirst()
        }
        samples.append(ms)
    }

    public mutating func noteEncoderDrop() { encoderDrops &+= 1 }
    public mutating func noteNetworkDrop() { networkDrops &+= 1 }
    public mutating func noteDecoderDrop() { decoderDrops &+= 1 }

    public func summary() -> Summary {
        guard !samples.isEmpty else {
            return Summary(count: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0, maxMs: 0,
                           encoderDrops: encoderDrops, networkDrops: networkDrops, decoderDrops: decoderDrops)
        }
        let sorted = samples.sorted()
        let last = sorted.count - 1
        return Summary(
            count: sorted.count,
            p50Ms: sorted[last * 50 / 100],
            p95Ms: sorted[last * 95 / 100],
            p99Ms: sorted[last * 99 / 100],
            maxMs: sorted[last],
            encoderDrops: encoderDrops,
            networkDrops: networkDrops,
            decoderDrops: decoderDrops
        )
    }

    public mutating func resetSamples() {
        samples.removeAll(keepingCapacity: true)
    }
}
