import Foundation

/// Eases a 0…1 progress value so motion starts quickly and settles gently.
public func easeOut(_ t: Double) -> Double {
    let c = min(max(t, 0), 1)
    return 1 - pow(1 - c, 3)
}

/// Where the spotlight is in its on/off animation.
public struct SpotlightFrame: Equatable, Sendable {
    /// Radius of the lit circle, in points.
    public var radius: Double
    /// How much of the configured dimming is applied, 0…1.
    public var dimFraction: Double

    /// - Parameters:
    ///   - level: 0 = fully off, 1 = fully on. The animation moves this over time.
    ///   - radius: the configured circle radius.
    ///   - screenDiagonal: the circle zooms in from this size when `zoom` is on.
    ///   - zoom: whether the circle zooms down onto the pointer, or only fades.
    public static func at(level: Double, radius: Double, screenDiagonal: Double, zoom: Bool) -> SpotlightFrame {
        let eased = easeOut(level)
        guard zoom else { return SpotlightFrame(radius: radius, dimFraction: eased) }
        let start = max(screenDiagonal, radius)
        return SpotlightFrame(radius: start + (radius - start) * eased, dimFraction: eased)
    }
}

/// The ring drawn for a mouse click.
public struct ClickRingFrame: Equatable, Sendable {
    public var radius: Double
    public var opacity: Double

    /// - Parameters:
    ///   - sinceRelease: seconds since the button came up, or nil while it is held.
    ///   - expand: whether the ring grows outward as it fades.
    public static func at(sinceRelease: Double?, radius: Double, duration: Double, expand: Bool) -> ClickRingFrame {
        guard let sinceRelease else { return ClickRingFrame(radius: radius, opacity: 1) }
        let t = duration > 0 ? min(sinceRelease / duration, 1) : 1
        let grow = expand ? 1 + 0.6 * easeOut(t) : 1
        return ClickRingFrame(radius: radius * grow, opacity: 1 - t)
    }
}

/// Short synthesized click sounds, so the app ships no audio files.
public enum ClickSoundSynth {
    /// A 16-bit mono WAV: a decaying tone with a sharp noise transient on top.
    /// - Parameters:
    ///   - frequency: the body of the click; lower reads as "press", higher as "release".
    public static func wav(frequency: Double, duration: Double = 0.045, sampleRate: Int = 44_100) -> Data {
        let count = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: count)
        var seed: UInt32 = 0x1234_5678
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            let envelope = exp(-t * 90)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let noiseEnvelope = exp(-t * 600)
            let value = 0.55 * sin(2 * .pi * frequency * t) * envelope + 0.35 * noise * noiseEnvelope
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                 // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))               // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for s in samples { append(s) }
        return data
    }
}
