import AVFoundation

/// Renders the struck-bell tone used for every handpan note: a handful of
/// slightly inharmonic partials, each with its own amplitude and decay, plus
/// an optional noise layer and soft saturation for a grittier, more organic
/// character — controlled by the noise slider in the UI.
enum BellSynth {
    struct Partial {
        let ratio: Double
        let amplitude: Double
        let decay: Double
    }

    // Fingertip: warm and mellow. Mallet (⌘ held): brighter, harder attack, faster decay.
    static let fingerPartials: [Partial] = [
        Partial(ratio: 1.00, amplitude: 1.00, decay: 1.8),
        Partial(ratio: 2.00, amplitude: 0.28, decay: 0.9),
        Partial(ratio: 3.01, amplitude: 0.14, decay: 0.6),
        Partial(ratio: 4.16, amplitude: 0.07, decay: 0.4),
    ]
    static let malletPartials: [Partial] = [
        Partial(ratio: 1.00, amplitude: 1.00, decay: 1.3),
        Partial(ratio: 2.00, amplitude: 0.45, decay: 0.7),
        Partial(ratio: 3.01, amplitude: 0.32, decay: 0.5),
        Partial(ratio: 4.16, amplitude: 0.22, decay: 0.35),
        Partial(ratio: 5.40, amplitude: 0.14, decay: 0.25),
        Partial(ratio: 6.80, amplitude: 0.08, decay: 0.18),
    ]

    /// `noiseAmount` (0...1) mixes in a decaying noise layer riding the same
    /// envelope as the fundamental, then runs the whole signal through soft
    /// saturation — noise and tone get driven together for a cohesive,
    /// grimier character rather than a clean tone with noise dabbed on top.
    static func render(
        frequency: Double,
        partials: [Partial],
        attack: Double,
        noiseAmount: Double,
        duration: Double,
        format: AVAudioFormat,
        sampleRate: Double
    ) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let attackSamples = Int(attack * sampleRate)
        let noiseEnvDecay = partials.first?.decay ?? 1.0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var sample = 0.0
            for partial in partials {
                let envelope = exp(-t / partial.decay)
                sample += partial.amplitude * envelope * sin(2 * .pi * frequency * partial.ratio * t)
            }

            if noiseAmount > 0 {
                let noiseEnv = exp(-t / noiseEnvDecay)
                sample += Double.random(in: -1...1) * noiseAmount * 0.22 * noiseEnv
            }

            if frame < attackSamples {
                sample *= Double(frame) / Double(attackSamples)
            }

            if noiseAmount > 0 {
                sample = DSP.softClip(sample, amount: noiseAmount)
            }

            let value = Float(sample * 0.3)
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData![channel][frame] = value
            }
        }

        return buffer
    }
}
