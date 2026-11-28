import Foundation

/// Transport-aware bitrate controller using RTT and frame-drop signals with hysteresis.
/// Adjusts encoder bitrate without changing the virtual display's logical resolution.
public struct AdaptiveBitrateController: Sendable {
    public struct Config: Sendable, Equatable {
        public let minMbps: Int
        public let maxMbps: Int
        public let initialMbps: Int
        public let targetRTTMs: Double
        public let highRTTMs: Double
        public let decreaseCooldown: TimeInterval
        public let increaseInterval: TimeInterval
        public let increaseStepMbps: Int

        public init(minMbps: Int, maxMbps: Int, initialMbps: Int,
                    targetRTTMs: Double = 15, highRTTMs: Double = 30,
                    decreaseCooldown: TimeInterval = 1.0,
                    increaseInterval: TimeInterval = 3.0,
                    increaseStepMbps: Int = 2) {
            self.minMbps = max(2, minMbps)
            self.maxMbps = max(self.minMbps, maxMbps)
            self.initialMbps = min(max(initialMbps, self.minMbps), self.maxMbps)
            self.targetRTTMs = targetRTTMs
            self.highRTTMs = max(targetRTTMs, highRTTMs)
            self.decreaseCooldown = decreaseCooldown
            self.increaseInterval = increaseInterval
            self.increaseStepMbps = max(1, increaseStepMbps)
        }

        public static func wifi(ceilingMbps: Int = 50) -> Config {
            let cap = max(6, min(ceilingMbps, 80))
            return Config(minMbps: 6, maxMbps: cap, initialMbps: min(25, cap))
        }

        public static func usb(ceilingMbps: Int = 80) -> Config {
            let cap = max(30, min(ceilingMbps, 200))
            return Config(minMbps: 30, maxMbps: cap, initialMbps: cap,
                          targetRTTMs: 5, highRTTMs: 15)
        }
    }

    public let config: Config
    public private(set) var currentMbps: Int
    private var lastDecreaseTime: TimeInterval = -.infinity
    private var stableSince: TimeInterval?

    public init(config: Config) {
        self.config = config
        self.currentMbps = config.initialMbps
    }

    /// Evaluates one telemetry window and returns the new bitrate in Mbps if it changed.
    public mutating func observe(rttMs: Double, droppedFrames: Int, queueDepth: Int, now: TimeInterval) -> Int? {
        let congested = droppedFrames > 0 || queueDepth >= 3 || (rttMs.isFinite && rttMs > config.highRTTMs)
        if congested {
            stableSince = nil
            guard now - lastDecreaseTime >= config.decreaseCooldown else { return nil }
            let factor = droppedFrames > 0 ? 0.72 : 0.85
            let next = max(config.minMbps, Int((Double(currentMbps) * factor).rounded(.down)))
            lastDecreaseTime = now
            guard next != currentMbps else { return nil }
            currentMbps = next
            return next
        }

        let healthy = !rttMs.isFinite || rttMs <= config.targetRTTMs
        guard healthy, queueDepth <= 1 else {
            stableSince = nil
            return nil
        }

        if let since = stableSince {
            guard now - since >= config.increaseInterval else { return nil }
            stableSince = now
            let step = max(config.increaseStepMbps, currentMbps / 10)
            let next = min(config.maxMbps, currentMbps + step)
            guard next != currentMbps else { return nil }
            currentMbps = next
            return next
        } else {
            stableSince = now
            return nil
        }
    }

    public mutating func reset() {
        currentMbps = config.initialMbps
        lastDecreaseTime = -.infinity
        stableSince = nil
    }
}
