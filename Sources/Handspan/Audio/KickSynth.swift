import AVFoundation

/// Renders one beat's worth of audio for the tap-tempo loop: a distant,
/// low-pass-filtered club kick — the thump you feel halfway back in a crowd,
/// rounded and muffled rather than a close, clicky transient — with a very
/// quiet detuned sub-tone lingering under and between hits as a
/// barely-conscious undertone. Padded with silence out to exactly `60/bpm`
/// seconds so `.loops` playback holds tempo exactly. The reverberant "room"
/// comes from a live reverb node in ToneEngine's graph, not from anything
/// baked in here, so its tail rings on continuously across the loop boundary.
enum KickSynth {
    static func render(bpm: Double, format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer {
        let beatInterval = 60.0 / bpm
        let totalFrameCount = AVAudioFrameCount(beatInterval * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrameCount)!
        buffer.frameLength = totalFrameCount

        let startFreq = 95.0
        let endFreq = 40.0
        let pitchDecay = 0.09
        let ampDecay = 0.35

        // Subliminal undertone: quiet, slightly detuned against the sweep's
        // resting pitch, decaying slowly enough to still be humming faintly
        // when the next hit lands.
        let subFreq = endFreq * 1.015
        let subDecay = 0.9
        let subAmount = 0.06

        let lowpass = Biquad()
        lowpass.setLowpass(frequency: 220, q: 0.7, sampleRate: sampleRate)

        let attackSamples = Int(0.004 * sampleRate)
        let kickDuration = min(0.5, beatInterval * 0.9)
        let kickFrames = Int(kickDuration * sampleRate)

        var phase = 0.0
        var subPhase = 0.0
        for frame in 0..<Int(totalFrameCount) {
            guard frame < kickFrames else {
                for channel in 0..<Int(format.channelCount) {
                    buffer.floatChannelData![channel][frame] = 0
                }
                continue
            }

            let t = Double(frame) / sampleRate
            let freq = endFreq + (startFreq - endFreq) * exp(-t / pitchDecay)
            phase += 2 * .pi * freq / sampleRate
            var sample = sin(phase) * exp(-t / ampDecay)

            subPhase += 2 * .pi * subFreq / sampleRate
            sample += sin(subPhase) * exp(-t / subDecay) * subAmount

            sample = lowpass.process(sample)

            if frame < attackSamples {
                sample *= Double(frame) / Double(attackSamples)
            }

            let value = Float(sample * 0.55)
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData![channel][frame] = value
            }
        }

        return buffer
    }
}
