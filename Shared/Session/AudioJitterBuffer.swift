import Foundation
import os

/// Smooths network audio for a real-time render callback (spec §7).
///
/// - Producer: network thread pushes 16-bit interleaved packets.
/// - Consumer: the audio render thread pulls Float32 frames; it never blocks
///   for long (one short unfair lock) and never allocates.
/// - Starts output only after `targetFrames` are buffered (prebuffer), plays
///   silence on underrun and re-prebuffers, and drops the oldest audio when
///   more than `maxFrames` pile up, so latency stays bounded.
/// - Clock drift (Mac and iPad audio clocks differ by tens of ppm): when the
///   level leaves a band around the target, one frame per pull is skipped
///   (too full) or repeated (too empty) until it is back near the target.
///   Measured before (client.log): latency wandered 19-84 ms and a slow
///   drain ended in an underrun (30 ms gap, click) about every 10 minutes.
public final class AudioJitterBuffer: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var underruns = 0
        public var droppedFrames = 0
        public var bufferedFrames = 0
        /// Frames skipped or repeated for drift correction.
        public var driftCorrections = 0
    }

    public let channels: Int
    public let targetFrames: Int
    public let maxFrames: Int

    private struct State {
        var ring: [Float]
        var readIndex = 0   // in frames
        var count = 0       // frames buffered
        var playing = false
        var stats = Stats()
        /// +1 skipping (too full), -1 repeating (too empty), 0 none.
        var correcting = 0
    }

    private let capacity: Int
    /// Drift band: correct above `high` or below `low`, stop once within
    /// `settle` of the target.
    private let high: Int, low: Int, settle: Int
    private let state: OSAllocatedUnfairLock<State>

    public init(channels: Int, targetFrames: Int, maxFrames: Int) {
        precondition(channels >= 1 && targetFrames >= 1 && maxFrames >= targetFrames)
        self.channels = channels
        self.targetFrames = targetFrames
        self.maxFrames = maxFrames
        capacity = maxFrames + SessionConstants.maxAudioFramesPerPacket
        high = targetFrames + max(targetFrames / 3, 1)
        low = targetFrames / 2
        settle = max(targetFrames / 12, 1)
        state = OSAllocatedUnfairLock(initialState: State(ring: [Float](repeating: 0, count: capacity * channels)))
    }

    public var stats: Stats { state.withLock { var s = $0.stats; s.bufferedFrames = $0.count; return s } }

    public func reset() {
        state.withLock {
            $0.readIndex = 0
            $0.count = 0
            $0.playing = false
            $0.correcting = 0
        }
    }

    /// Network side. Packets whose channel count does not match are ignored.
    public func push(_ packet: AudioPacket) {
        guard Int(packet.channels) == channels else { return }
        let frames = packet.frameCount
        guard frames > 0 else { return }
        state.withLock { s in
            for frame in 0..<frames {
                let write = (s.readIndex + s.count) % capacity
                for channel in 0..<channels {
                    s.ring[write * channels + channel] = Float(packet.samples[frame * channels + channel]) / 32768
                }
                if s.count < capacity { s.count += 1 } else { s.readIndex = (s.readIndex + 1) % capacity }
            }
            if s.count > maxFrames {
                // Too far behind real time: drop down to the target latency.
                let drop = s.count - targetFrames
                s.readIndex = (s.readIndex + drop) % capacity
                s.count -= drop
                s.stats.droppedFrames += drop
            }
            if !s.playing && s.count >= targetFrames { s.playing = true }
        }
    }

    /// Render side: fills `frames` frames into per-channel (deinterleaved)
    /// buffers. Missing channels in `buffers` are skipped; extra output
    /// channels get the last source channel (mono -> stereo).
    public func pull(into buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        // Unchecked: the closure runs synchronously under the lock; the raw
        // output pointers never escape it.
        state.withLockUnchecked { s in
            fill(&s, count: buffers.count, frames: frames) { buffers[$0] }
        }
    }

    /// Same as `pull(into:frames:)` for up to two output channels, without
    /// building an array: for render callbacks, which must not allocate.
    public func pull(_ first: UnsafeMutablePointer<Float>?, _ second: UnsafeMutablePointer<Float>?, frames: Int) {
        let count = first == nil ? 0 : second == nil ? 1 : 2
        guard count > 0 else { return }
        state.withLockUnchecked { s in
            fill(&s, count: count, frames: frames) { $0 == 0 ? first! : second! }
        }
    }

    private func fill(_ s: inout State, count outputs: Int, frames: Int,
                      buffer: (Int) -> UnsafeMutablePointer<Float>) {
        var produced = 0
        if s.playing {
            // Drift correction: at most one frame per pull, so it is inaudible.
            if s.count > high { s.correcting = 1 } else if s.count < low { s.correcting = -1 }
            else if abs(s.count - targetFrames) <= settle { s.correcting = 0 }
            let repeatLast = s.correcting < 0 && frames > 1 && s.count > 0
            let wanted = repeatLast ? frames - 1 : frames
            produced = min(wanted, s.count)
            for frame in 0..<produced {
                let read = (s.readIndex + frame) % capacity
                for index in 0..<outputs {
                    buffer(index)[frame] = s.ring[read * channels + min(index, channels - 1)]
                }
            }
            s.readIndex = (s.readIndex + produced) % capacity
            s.count -= produced
            if repeatLast, produced == wanted, produced > 0 {
                for index in 0..<outputs { buffer(index)[produced] = buffer(index)[produced - 1] }
                produced += 1
                s.stats.driftCorrections += 1
            } else if s.correcting > 0, s.count > 1 {
                s.readIndex = (s.readIndex + 1) % capacity // skip one frame
                s.count -= 1
                s.stats.driftCorrections += 1
            }
            if produced < frames {
                s.playing = false // re-prebuffer before resuming
                s.correcting = 0
                s.stats.underruns += 1
            }
        }
        for index in 0..<outputs where produced < frames {
            (buffer(index) + produced).update(repeating: 0, count: frames - produced)
        }
    }
}

public enum PCM {
    /// Float [-1, 1] (deinterleaved, one pointer per channel) -> Int16 interleaved, clipped.
    public static func interleave(_ channels: [UnsafePointer<Float>], frames: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: frames * channels.count)
        for frame in 0..<frames {
            for (index, channel) in channels.enumerated() {
                let value = max(-1, min(1, channel[frame]))
                out[frame * channels.count + index] = Int16((value * 32767).rounded())
            }
        }
        return out
    }
}
