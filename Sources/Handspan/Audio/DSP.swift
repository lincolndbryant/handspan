import Foundation

/// Small reusable signal-processing building blocks shared by the synths.
enum DSP {
    /// Soft-clipping (tanh) waveshaper. `amount` is 0 (no effect) to 1 (heavy
    /// saturation) — used to give the bell tones a grittier, more driven edge.
    static func softClip(_ sample: Double, amount: Double) -> Double {
        guard amount > 0 else { return sample }
        let drive = 1 + amount * 5
        return tanh(sample * drive) / tanh(drive)
    }
}

/// A single Direct Form I biquad filter with persistent state, so its
/// coefficients can change between blocks without discontinuities in the
/// filter's history. Used as a resonant bandpass (vocal formants, percussive
/// "knock" transients) and as a low-pass (muffling the club kick).
final class Biquad {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    func setBandpass(frequency: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b1 = 0
        b2 = -alpha / a0
        a1 = -2 * cos(w0) / a0
        a2 = (1 - alpha) / a0
    }

    /// Rolls off highs above `frequency` — used to make the kick sound
    /// muffled by distance and a crowd rather than close and bright.
    func setLowpass(frequency: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let a0 = 1 + alpha
        b0 = ((1 - cosw0) / 2) / a0
        b1 = (1 - cosw0) / a0
        b2 = ((1 - cosw0) / 2) / a0
        a1 = (-2 * cosw0) / a0
        a2 = (1 - alpha) / a0
    }

    func process(_ x0: Double) -> Double {
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x0
        y2 = y1; y1 = y0
        return y0
    }
}
