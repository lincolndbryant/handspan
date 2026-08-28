import AVFoundation

/// Renders a 10-second vocal "Om" chant: a buzzy vocal-fold-like source
/// shaped by three formant filters that morph from an open "aw" mouth shape
/// into a closed nasal "mmm" hum, the way a real Om chant closes from vowel
/// to hum. Triggered from the trackpad corners.
enum OhmSynth {
    /// A resonant bandpass filter target (RBJ constant-skirt-gain form) used
    /// to carve a single vowel formant out of a harmonically rich source.
    struct Formant {
        var frequency: Double
        var q: Double
        var gain: Double
    }

    static func render(f0: Double, format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer {
        let totalDuration = 10.0
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let harmonicCount = 22

        // Formant targets: open "aw/oh" vowel at the start, closed nasal "m" hum for the sustain.
        let vowel = (f1: Formant(frequency: 620, q: 9, gain: 1.0),
                     f2: Formant(frequency: 950, q: 12, gain: 0.55),
                     f3: Formant(frequency: 2500, q: 14, gain: 0.22))
        let nasal = (f1: Formant(frequency: 260, q: 12, gain: 1.0),
                     f2: Formant(frequency: 1000, q: 16, gain: 0.10),
                     f3: Formant(frequency: 2200, q: 18, gain: 0.025))

        let morphDuration = 1.6
        let attack = 0.35
        let release = 2.2

        let bp1 = Biquad()
        let bp2 = Biquad()
        let bp3 = Biquad()

        let blockSize = 256
        let totalSamples = Int(frameCount)

        var phase = 0.0
        var frame = 0
        while frame < totalSamples {
            let blockEnd = min(frame + blockSize, totalSamples)
            let t = Double(frame) / sampleRate

            // Ease-in/out morph from vowel to nasal formants (mouth closing).
            let morphLinear = min(1, t / morphDuration)
            let morph = morphLinear * morphLinear * (3 - 2 * morphLinear)

            let f1 = Formant(
                frequency: vowel.f1.frequency + (nasal.f1.frequency - vowel.f1.frequency) * morph,
                q: vowel.f1.q + (nasal.f1.q - vowel.f1.q) * morph,
                gain: vowel.f1.gain + (nasal.f1.gain - vowel.f1.gain) * morph
            )
            let f2 = Formant(
                frequency: vowel.f2.frequency + (nasal.f2.frequency - vowel.f2.frequency) * morph,
                q: vowel.f2.q + (nasal.f2.q - vowel.f2.q) * morph,
                gain: vowel.f2.gain + (nasal.f2.gain - vowel.f2.gain) * morph
            )
            let f3 = Formant(
                frequency: vowel.f3.frequency + (nasal.f3.frequency - vowel.f3.frequency) * morph,
                q: vowel.f3.q + (nasal.f3.q - vowel.f3.q) * morph,
                gain: vowel.f3.gain + (nasal.f3.gain - vowel.f3.gain) * morph
            )
            bp1.setBandpass(frequency: f1.frequency, q: f1.q, sampleRate: sampleRate)
            bp2.setBandpass(frequency: f2.frequency, q: f2.q, sampleRate: sampleRate)
            bp3.setBandpass(frequency: f3.frequency, q: f3.q, sampleRate: sampleRate)

            for i in frame..<blockEnd {
                let sampleTime = Double(i) / sampleRate

                // Slight natural vibrato on the fundamental.
                let vibrato = 1 + 0.006 * sin(2 * .pi * 5.2 * sampleTime)
                let instFreq = f0 * vibrato
                phase += 2 * .pi * instFreq / sampleRate

                // Harmonically rich buzz (bandlimited sawtooth-ish), the "vocal fold" source.
                var excitation = 0.0
                for n in 1...harmonicCount {
                    excitation += sin(phase * Double(n)) / Double(n)
                }
                excitation *= 0.35

                let formants = f1.gain * bp1.process(excitation)
                    + f2.gain * bp2.process(excitation)
                    + f3.gain * bp3.process(excitation)

                var envelope = 1.0
                if sampleTime < attack {
                    envelope = sampleTime / attack
                } else if sampleTime > totalDuration - release {
                    envelope = max(0, (totalDuration - sampleTime) / release)
                }
                // Gentle breath-like swell so the sustain doesn't sound perfectly static.
                let breath = 1.0 + 0.05 * sin(2 * .pi * 0.2 * sampleTime)

                let value = Float(formants * envelope * breath * 0.9)
                for channel in 0..<Int(format.channelCount) {
                    buffer.floatChannelData![channel][i] = value
                }
            }

            frame = blockEnd
        }

        return buffer
    }
}
