import AVFoundation

/// Owns the `AVAudioEngine` graph (mixer/reverb routing, the player-node
/// pool) and the cache of pre-rendered buffers. Sound *design* lives in
/// `BellSynth` / `OhmSynth` / `KickSynth` — this type is just the plumbing:
/// wiring nodes together, caching what they produce, and scheduling playback.
final class ToneEngine {
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private let format: AVAudioFormat

    private var players: [AVAudioPlayerNode] = []
    // Keyed by "<note>_<octaveShift>_<f|m>" (f = fingertip, m = mallet).
    private var noteBuffers: [String: AVAudioPCMBuffer] = [:]
    private var nextPlayerIndex = 0

    // Dedicated node for the corner "Om" drone so it can't get cut off by the
    // round-robin note pool while a 10-second sustain is still ringing.
    private let ohmPlayer = AVAudioPlayerNode()
    private var ohmBuffersByShift: [Int: AVAudioPCMBuffer] = [:]

    // Dedicated node + reverb for the tap-tempo kick loop, kept separate from
    // the handpan's reverb bus so it can be tuned much bigger and wetter —
    // a large, diffuse room rather than the notes' bell tail.
    private let kickPlayer = AVAudioPlayerNode()
    private let kickReverb = AVAudioUnitReverb()

    private let sampleRate: Double = 44100
    private let duration: Double = 3.0
    private let polyphony = 16

    private var preparedNotes: [Note] = []
    private var noiseAmount: Double = 0.25
    private var noiseRequestID = 0

    init() {
        // Stereo throughout: connecting a mono format through AVAudioUnitReverb
        // can silently produce no output on some macOS versions.
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        engine.attach(mixer)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 38

        engine.connect(mixer, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        mixer.outputVolume = 1.0

        for _ in 0..<polyphony {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mixer, format: format)
            player.volume = 1.0
            players.append(player)
        }

        engine.attach(ohmPlayer)
        engine.connect(ohmPlayer, to: mixer, format: format)
        ohmPlayer.volume = 1.0

        engine.attach(kickPlayer)
        engine.attach(kickReverb)
        kickReverb.loadFactoryPreset(.largeHall2)
        kickReverb.wetDryMix = 48
        engine.connect(kickPlayer, to: kickReverb, format: format)
        engine.connect(kickReverb, to: engine.mainMixerNode, format: format)
        kickPlayer.volume = 1.0

        do {
            try engine.start()
            print("[ToneEngine] engine started, isRunning=\(engine.isRunning), outputFormat=\(engine.outputNode.outputFormat(forBus: 0))")
        } catch {
            print("[ToneEngine] FAILED to start audio engine: \(error)")
        }
    }

    private func bufferKey(_ noteName: String, octaveShift: Int, mallet: Bool) -> String {
        "\(noteName)_\(octaveShift)_\(mallet ? "m" : "f")"
    }

    func prepare(notes: [Note]) {
        preparedNotes = notes
        noteBuffers = renderedNoteBuffers(for: notes, noiseAmount: noiseAmount)
        print("[ToneEngine] prepared \(notes.count) notes x3 octaves x2 techniques (\(noteBuffers.count) buffers)")
    }

    /// Re-renders every bell buffer with a new noise/distortion amount, off
    /// the main thread so dragging the slider doesn't stall touch handling.
    /// A request ID discards a slower, stale render if a newer one lands first.
    func updateNoiseAmount(_ amount: Double) {
        noiseAmount = amount
        noiseRequestID += 1
        let requestID = noiseRequestID
        let notes = preparedNotes
        guard !notes.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let newBuffers = self.renderedNoteBuffers(for: notes, noiseAmount: amount)
            DispatchQueue.main.async {
                guard self.noiseRequestID == requestID else { return }
                self.noteBuffers = newBuffers
                print("[ToneEngine] re-rendered bell buffers, noiseAmount=\(amount)")
            }
        }
    }

    private func renderedNoteBuffers(for notes: [Note], noiseAmount: Double) -> [String: AVAudioPCMBuffer] {
        var result: [String: AVAudioPCMBuffer] = [:]
        for note in notes {
            for shift in [-1, 0, 1] {
                let frequency = note.frequency * pow(2.0, Double(shift))
                result[bufferKey(note.name, octaveShift: shift, mallet: false)] = BellSynth.render(
                    frequency: frequency, partials: BellSynth.fingerPartials, attack: 0.004,
                    noiseAmount: noiseAmount, duration: duration, format: format, sampleRate: sampleRate
                )
                result[bufferKey(note.name, octaveShift: shift, mallet: true)] = BellSynth.render(
                    frequency: frequency, partials: BellSynth.malletPartials, attack: 0.0015,
                    noiseAmount: noiseAmount, duration: duration, format: format, sampleRate: sampleRate
                )
            }
        }
        return result
    }

    /// Plays the note and returns the player node driving it, so the caller can
    /// ride its volume for as long as the triggering touch stays down (damping).
    /// `octaveShift` is -1 (Shift held), 0, or +1 (Option held). `mallet` (⌘ held)
    /// swaps the warm fingertip timbre for a brighter, harder-struck one. `volume`
    /// defaults to a full strike; pass lower for a softer, quieter touch (e.g.
    /// the startup chime).
    @discardableResult
    func play(_ note: Note, octaveShift: Int = 0, mallet: Bool = false, volume: Float = 1.0) -> AVAudioPlayerNode? {
        let key = bufferKey(note.name, octaveShift: octaveShift, mallet: mallet)
        guard let buffer = noteBuffers[key] else {
            print("[ToneEngine] no buffer for key \(key)")
            return nil
        }
        let player = players[nextPlayerIndex]
        nextPlayerIndex = (nextPlayerIndex + 1) % players.count

        if player.isPlaying {
            player.stop()
        }
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        return player
    }

    /// Starts (or retempos) a sample-accurate, seamlessly looping kick drum at
    /// the given BPM, from tap-tempo on the trackpad while Space is held. The
    /// kick buffer is padded with silence to exactly one beat's length and
    /// played with `.loops`, so the beat can't drift the way a repeating
    /// Timer re-triggering playback would.
    func startKickLoop(bpm: Double) {
        let clamped = min(200, max(40, bpm))
        let buffer = KickSynth.render(bpm: clamped, format: format, sampleRate: sampleRate)
        kickPlayer.stop()
        kickPlayer.scheduleBuffer(buffer, at: nil, options: [.loops])
        kickPlayer.play()
        print("[ToneEngine] kick loop started at \(clamped) BPM")
    }

    func stopKickLoop() {
        kickPlayer.stop()
        print("[ToneEngine] kick loop stopped")
    }

    /// Plays a 10-second vocal-like "Om" chant drone, triggered from the trackpad corners.
    /// `octaveShift` shifts the chant pitch (Shift = down, Option = up) while keeping
    /// the same formant shaping, the way a real voice pitched differently still sounds.
    func playOhm(octaveShift: Int = 0) {
        if ohmBuffersByShift[octaveShift] == nil {
            let f0 = 110.0 * pow(2.0, Double(octaveShift))
            ohmBuffersByShift[octaveShift] = OhmSynth.render(f0: f0, format: format, sampleRate: sampleRate)
            print("[ToneEngine] rendered ohm drone buffer shift \(octaveShift)")
        }
        guard let buffer = ohmBuffersByShift[octaveShift] else { return }
        ohmPlayer.stop()
        ohmPlayer.volume = 1.0
        ohmPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts)
        ohmPlayer.play()
        print("[ToneEngine] playing ohm drone, octaveShift=\(octaveShift)")
    }

}
