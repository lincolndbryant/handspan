import AppKit
import AVFoundation

/// Captures indirect (trackpad) multi-touch input and renders the handpan.
final class HandpanView: NSView {
    // Lazy so constructing the view (e.g. for headless snapshot rendering)
    // never touches CoreAudio unless a touch actually triggers a note.
    private lazy var toneEngine: ToneEngine = {
        let engine = ToneEngine()
        engine.prepare(notes: [HandpanLayout.ding] + HandpanLayout.ring)
        return engine
    }()

    private struct ActiveTouch {
        let note: Note
        var point: CGPoint
        let player: AVAudioPlayerNode?
        let beganAt: TimeInterval
    }

    private var activeTouches: [NSObject: ActiveTouch] = [:]
    private var updateTimer: Timer?

    // How long a held touch rings freely before damping kicks in, and how long
    // the fade-to-silence ramp takes once it does. Mimics resting a finger on a
    // handpan tone field to choke the note, the way a real player mutes it.
    private let dampGrace: TimeInterval = 0.12
    private let dampRamp: TimeInterval = 0.5

    // Touching within this fraction of the trackpad's edge, in both axes, counts
    // as a corner touch and triggers the sustained "Om" drone instead of a note.
    private let cornerThreshold: CGFloat = 0.08
    private let ohmDuration: TimeInterval = 10
    private var cornerGlow: (corner: Int, expiry: TimeInterval)?

    // Tap-tempo: hold Space and tap the trackpad 4 times to set a kick drum
    // loop's BPM from the average interval. Escape stops the loop.
    private let spaceKeyCode: UInt16 = 49
    private let escapeKeyCode: UInt16 = 53
    private var isSpaceHeld = false
    private var tempoTapTimestamps: [TimeInterval] = []
    private var activeBPM: Double?

    private let backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 1)
    private let discCenterColor = NSColor(calibratedWhite: 0.19, alpha: 1)
    private let discEdgeColor = NSColor(calibratedWhite: 0.045, alpha: 1)
    private let fieldColor = NSColor(calibratedWhite: 0.10, alpha: 1)
    private let grooveShadow = NSColor(calibratedWhite: 0.0, alpha: 0.85)
    private let grooveHighlight = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    private let goldColor = NSColor(calibratedRed: 0.78, green: 0.64, blue: 0.34, alpha: 1)

    // Cached so the randomized grass bokeh doesn't regenerate (and flicker)
    // on every redraw — only when the view's size actually changes.
    private var cachedBackground: NSImage?
    private var cachedBackgroundSize: NSSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer

        addSubview(stopButton)
        addSubview(noiseSlider)
        positionStopButton()
        positionNoiseSlider()
    }

    /// Controls how much noise/distortion BellSynth mixes into the handpan
    /// tones. Dragging re-renders the note buffers in the background (see
    /// ToneEngine.updateNoiseAmount), so it never blocks touch handling.
    private lazy var noiseSlider: NSSlider = {
        let slider = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: self, action: #selector(noiseSliderChanged))
        slider.isContinuous = true
        slider.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        slider.toolTip = "Bell noise / distortion amount"
        slider.appearance = NSAppearance(named: .darkAqua)
        return slider
    }()

    @objc private func noiseSliderChanged() {
        toneEngine.updateNoiseAmount(noiseSlider.doubleValue)
    }

    private func positionNoiseSlider() {
        noiseSlider.frame = NSRect(x: 16, y: bounds.maxY - 32, width: 120, height: 20)
    }

    /// Native circular stop control for the tempo loop — only visible while
    /// a loop is running. A physical click is a separate event path from the
    /// resting-finger touches used for drumming, so the two never conflict.
    private lazy var stopButton: NSButton = {
        let button = NSButton(title: "\u{25A0}", target: self, action: #selector(stopButtonTapped))
        button.bezelStyle = .circular
        button.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        button.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        button.toolTip = "Stop tempo loop (Esc)"
        button.isHidden = true
        return button
    }()

    @objc private func stopButtonTapped() {
        toneEngine.stopKickLoop()
        activeBPM = nil
        stopButton.isHidden = true
        needsDisplay = true
    }

    private func positionStopButton() {
        stopButton.frame = NSRect(x: bounds.maxX - 44, y: bounds.minY + 10, width: 32, height: 32)
    }

    override func layout() {
        super.layout()
        positionStopButton()
        positionNoiseSlider()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime

        for touch in activeTouches.values {
            guard let player = touch.player else { continue }
            let held = now - touch.beganAt
            guard held > dampGrace else { continue }
            let t = min(1, (held - dampGrace) / dampRamp)
            player.volume = Float(1 - t)
        }

        if let glow = cornerGlow {
            needsDisplay = true
            if now >= glow.expiry {
                cornerGlow = nil
            }
        } else if !activeTouches.isEmpty {
            needsDisplay = true
        }
    }

    /// Returns which trackpad corner (0=bottom-left, 1=bottom-right, 2=top-left,
    /// 3=top-right) the touch is in, or nil if it's not near a corner.
    private func cornerIndex(for touch: NSTouch) -> Int? {
        let p = touch.normalizedPosition
        let left = p.x < cornerThreshold
        let right = p.x > 1 - cornerThreshold
        let bottom = p.y < cornerThreshold
        let top = p.y > 1 - cornerThreshold
        if left && bottom { return 0 }
        if right && bottom { return 1 }
        if left && top { return 2 }
        if right && top { return 3 }
        return nil
    }

    private func viewPointForCorner(_ corner: Int) -> CGPoint {
        let inset: CGFloat = 40
        switch corner {
        case 0: return CGPoint(x: bounds.minX + inset, y: bounds.minY + inset)
        case 1: return CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset)
        case 2: return CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset)
        default: return CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset)
        }
    }

    /// A soft, quiet strike of the handpan's own center "ding" — the
    /// instrument's own voice, not a generic test tone — as a gentle welcome.
    func playStartupChime() {
        toneEngine.play(HandpanLayout.ding, volume: 0.35)
    }

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        needsDisplay = true
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case spaceKeyCode:
            if !event.isARepeat {
                isSpaceHeld = true
                tempoTapTimestamps.removeAll()
                needsDisplay = true
            }
        case escapeKeyCode:
            toneEngine.stopKickLoop()
            activeBPM = nil
            stopButton.isHidden = true
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == spaceKeyCode {
            isSpaceHeld = false
            tempoTapTimestamps.removeAll()
            needsDisplay = true
        } else {
            super.keyUp(with: event)
        }
    }

    /// Records one tempo tap; once 4 taps have landed, averages the last 3
    /// intervals into a BPM and (re)starts the kick loop. A gap over 2.5s
    /// between taps is treated as an abandoned sequence, not part of the timing.
    private func registerTempoTap() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = tempoTapTimestamps.last, now - last > 2.5 {
            tempoTapTimestamps.removeAll()
        }
        tempoTapTimestamps.append(now)
        if tempoTapTimestamps.count > 4 {
            tempoTapTimestamps.removeFirst(tempoTapTimestamps.count - 4)
        }
        guard tempoTapTimestamps.count == 4 else { return }

        let intervals = zip(tempoTapTimestamps, tempoTapTimestamps.dropFirst()).map { $1 - $0 }
        let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
        guard avgInterval > 0.05 else { return }

        let bpm = min(200, max(40, 60.0 / avgInterval))
        activeBPM = bpm
        toneEngine.startKickLoop(bpm: bpm)
        stopButton.isHidden = false
    }

    /// -1 (Shift, down an octave), 0, or +1 (Option, up an octave). Holding both cancels out.
    private func octaveShift(for flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.option) ? 1 : 0) - (flags.contains(.shift) ? 1 : 0)
    }

    // MARK: - Geometry

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var outerRadius: CGFloat { min(bounds.width, bounds.height) * 0.46 }
    private var centerRadius: CGFloat { outerRadius * 0.32 }

    private func viewPoint(for touch: NSTouch) -> CGPoint {
        // normalizedPosition is 0...1 across the physical trackpad surface.
        let normalized = touch.normalizedPosition
        return CGPoint(x: normalized.x * bounds.width, y: normalized.y * bounds.height)
    }

    private func pointOnCircle(angleDegrees: Double, radius: CGFloat) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }

    // MARK: - Touch handling

    override func touchesBegan(with event: NSEvent) {
        if isSpaceHeld {
            for _ in event.touches(matching: .began, in: self) {
                registerTempoTap()
            }
            needsDisplay = true
            return
        }

        let shift = octaveShift(for: event.modifierFlags)
        let mallet = event.modifierFlags.contains(.command)

        for touch in event.touches(matching: .began, in: self) {
            if let corner = cornerIndex(for: touch) {
                toneEngine.playOhm(octaveShift: shift)
                cornerGlow = (corner, ProcessInfo.processInfo.systemUptime + ohmDuration)
                continue
            }

            let p = viewPoint(for: touch)
            guard let result = HandpanLayout.note(for: p, center: center, centerRadius: centerRadius, outerRadius: outerRadius) else { continue }
            let key = touch.identity as! NSObject
            let player = toneEngine.play(result.note, octaveShift: shift, mallet: mallet)
            activeTouches[key] = ActiveTouch(note: result.note, point: p, player: player, beganAt: ProcessInfo.processInfo.systemUptime)
        }
        needsDisplay = true
    }

    override func touchesMoved(with event: NSEvent) {
        for touch in event.touches(matching: .moved, in: self) {
            let key = touch.identity as! NSObject
            guard activeTouches[key] != nil else { continue }
            activeTouches[key]?.point = viewPoint(for: touch)
        }
        needsDisplay = true
    }

    override func touchesEnded(with event: NSEvent) {
        for touch in event.touches(matching: .ended, in: self) {
            activeTouches.removeValue(forKey: touch.identity as! NSObject)
        }
        needsDisplay = true
    }

    override func touchesCancelled(with event: NSEvent) {
        for touch in event.touches(matching: .cancelled, in: self) {
            activeTouches.removeValue(forKey: touch.identity as! NSObject)
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        backgroundImage(for: bounds.size).draw(in: bounds)

        drawDropShadow()
        drawDiscBody()
        drawSectors()
        drawDing()
        drawSheen()
        drawActiveHighlights()
        drawCornerMarkers()
        drawOctaveIndicator()
        drawTempoIndicator()
        drawNoiseLabel()
    }

    private func drawNoiseLabel() {
        let text = "noise" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 0.7),
        ]
        let point = CGPoint(x: noiseSlider.frame.maxX + 8, y: noiseSlider.frame.minY + 3)
        text.draw(at: point, withAttributes: attributes)
    }

    private func drawTempoIndicator() {
        let text: NSString
        if let bpm = activeBPM {
            text = "\(Int(bpm.rounded())) BPM \u{2014} Esc to stop" as NSString
        } else if isSpaceHeld {
            text = (tempoTapTimestamps.isEmpty ? "tap tempo\u{2026}" : "tap \(tempoTapTimestamps.count)/4\u{2026}") as NSString
        } else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.5, alpha: 0.9),
        ]
        let size = text.size(withAttributes: attributes)
        let point = CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 16)
        text.draw(at: point, withAttributes: attributes)
    }

    private func backgroundImage(for size: NSSize) -> NSImage {
        if let cached = cachedBackground, cachedBackgroundSize == size, size.width > 0, size.height > 0 {
            return cached
        }
        let image = renderGrassBackground(size: size)
        cachedBackground = image
        cachedBackgroundSize = size
        return image
    }

    /// A stylized, shallow-depth-of-field grass field: a green vertical gradient
    /// base with scattered soft bokeh blobs and a few warm sunlight glints,
    /// the way a handpan is often photographed sitting outdoors on grass.
    private func renderGrassBackground(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            if let base = NSGradient(colors: [
                NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.15, alpha: 1),
                NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.07, alpha: 1),
            ]) {
                base.draw(in: rect, angle: 90)
            }

            for _ in 0..<220 {
                let radius = CGFloat.random(in: 14...70)
                let x = CGFloat.random(in: rect.minX...rect.maxX)
                let y = CGFloat.random(in: rect.minY...rect.maxY)
                let mix = CGFloat.random(in: 0...1)
                let color = NSColor(
                    calibratedRed: 0.22 + 0.35 * mix,
                    green: 0.32 + 0.28 * mix,
                    blue: 0.07 + 0.05 * mix,
                    alpha: CGFloat.random(in: 0.10...0.28)
                )
                guard let gradient = NSGradient(starting: color, ending: color.withAlphaComponent(0)) else { continue }
                let blobRect = NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                gradient.draw(in: NSBezierPath(ovalIn: blobRect), relativeCenterPosition: .zero)
            }

            for _ in 0..<8 {
                let radius = CGFloat.random(in: 40...100)
                let x = CGFloat.random(in: rect.minX...rect.maxX)
                let y = CGFloat.random(in: rect.midY...rect.maxY)
                let color = NSColor(calibratedRed: 0.95, green: 0.88, blue: 0.55, alpha: CGFloat.random(in: 0.05...0.12))
                guard let gradient = NSGradient(starting: color, ending: color.withAlphaComponent(0)) else { continue }
                let blobRect = NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                gradient.draw(in: NSBezierPath(ovalIn: blobRect), relativeCenterPosition: .zero)
            }

            if let vignette = NSGradient(starting: NSColor(calibratedWhite: 0, alpha: 0), ending: NSColor(calibratedWhite: 0, alpha: 0.4)) {
                let vRect = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
                vignette.draw(in: NSBezierPath(ovalIn: vRect), relativeCenterPosition: .zero)
            }

            return true
        }
    }

    /// Soft dark contact shadow beneath the disc, grounding it on the grass.
    private func drawDropShadow() {
        guard let gradient = NSGradient(
            starting: NSColor(calibratedWhite: 0.0, alpha: 0.5),
            ending: NSColor(calibratedWhite: 0.0, alpha: 0)
        ) else { return }
        let shadowRadius = outerRadius * 1.08
        let shadowCenter = CGPoint(x: center.x, y: center.y - outerRadius * 0.07)
        let rect = NSRect(x: shadowCenter.x - shadowRadius, y: shadowCenter.y - shadowRadius, width: shadowRadius * 2, height: shadowRadius * 2)
        gradient.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
    }

    /// The matte-black disc, shaded with a radial gradient to suggest a
    /// gently domed, studio-lit metal surface.
    private func drawDiscBody() {
        let rect = NSRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2)
        let path = NSBezierPath(ovalIn: rect)

        if let gradient = NSGradient(starting: discCenterColor, ending: discEdgeColor) {
            gradient.draw(in: path, relativeCenterPosition: NSPoint(x: -0.15, y: 0.2))
        } else {
            discEdgeColor.setFill()
            path.fill()
        }

        NSColor(calibratedWhite: 0.35, alpha: 0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A soft, offset highlight ellipse blended over the upper-left of the
    /// disc, mimicking a studio key light catching a curved surface.
    private func drawSheen() {
        let discRect = NSRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2)
        let clipPath = NSBezierPath(ovalIn: discRect)

        NSGraphicsContext.saveGraphicsState()
        clipPath.setClip()

        let sheenRadius = outerRadius * 0.95
        let sheenCenter = CGPoint(x: center.x - outerRadius * 0.28, y: center.y + outerRadius * 0.32)
        if let gradient = NSGradient(
            starting: NSColor(calibratedWhite: 1.0, alpha: 0.07),
            ending: NSColor(calibratedWhite: 1.0, alpha: 0)
        ) {
            let rect = NSRect(x: sheenCenter.x - sheenRadius, y: sheenCenter.y - sheenRadius, width: sheenRadius * 2, height: sheenRadius * 2)
            gradient.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawOctaveIndicator() {
        let flags = NSEvent.modifierFlags
        let shift = octaveShift(for: flags)
        let mallet = flags.contains(.command)
        guard shift != 0 || mallet else { return }

        var parts: [String] = []
        if shift != 0 { parts.append(shift > 0 ? "+8va" : "-8va") }
        if mallet { parts.append("mallet") }
        let text = parts.joined(separator: " \u{00B7} ") as NSString

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.8, blue: 1.0, alpha: 0.9),
        ]
        let size = text.size(withAttributes: attributes)
        let point = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 16)
        text.draw(at: point, withAttributes: attributes)
    }

    private func labelAttributes() -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1.5
        return [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: goldColor,
            .shadow: shadow,
        ]
    }

    /// A capsule ("stadium") tone field pointing up the +y axis from a point
    /// near the disc center, matching the petal-shaped fields on a real
    /// tongue drum rather than a flat pie wedge.
    private func petalPath() -> NSBezierPath {
        let width = (outerRadius - centerRadius) * 0.44
        let innerGap: CGFloat = 8
        let outerMargin: CGFloat = 16
        let rect = NSRect(
            x: -width / 2,
            y: centerRadius + innerGap,
            width: width,
            height: outerRadius - outerMargin - (centerRadius + innerGap)
        )
        return NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2)
    }

    private func strokeGroove(_ path: NSBezierPath) {
        grooveShadow.setStroke()
        path.lineWidth = 2.5
        path.stroke()
        grooveHighlight.setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    private func drawSectors() {
        let count = HandpanLayout.ring.count
        for i in 0..<count {
            let a0 = 90 - Double(i + 1) * 45
            let a1 = 90 - Double(i) * 45
            let mid = (a0 + a1) / 2

            let path = petalPath()
            var transform = AffineTransform.identity
            transform.translate(x: center.x, y: center.y)
            transform.rotate(byDegrees: CGFloat(mid - 90))
            path.transform(using: transform)

            fieldColor.setFill()
            path.fill()
            strokeGroove(path)

            let labelPoint = pointOnCircle(angleDegrees: mid, radius: (centerRadius + outerRadius) / 2 + 4)
            let note = HandpanLayout.ring[i]
            let text = note.name as NSString
            let attrs = labelAttributes()
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: labelPoint.x - size.width / 2, y: labelPoint.y - size.height / 2), withAttributes: attrs)
        }
    }

    /// An arch ("tombstone") shape for the center ding field: flat bottom,
    /// rounded top, matching the center field on a real tongue drum.
    private func dingPath() -> NSBezierPath {
        let width = centerRadius * 1.7
        let height = centerRadius * 1.9
        let r = width / 2
        let bottomY = center.y - height / 2
        let archCenterY = center.y + height / 2 - r

        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x - width / 2, y: bottomY))
        path.line(to: CGPoint(x: center.x - width / 2, y: archCenterY))
        path.appendArc(withCenter: CGPoint(x: center.x, y: archCenterY), radius: r, startAngle: 180, endAngle: 0, clockwise: true)
        path.line(to: CGPoint(x: center.x + width / 2, y: bottomY))
        path.close()
        return path
    }

    private func drawDing() {
        let path = dingPath()
        fieldColor.setFill()
        path.fill()
        strokeGroove(path)

        let text = HandpanLayout.ding.name as NSString
        let attrs = labelAttributes()
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }

    private func drawCornerMarkers() {
        let now = ProcessInfo.processInfo.systemUptime
        for corner in 0..<4 {
            let point = viewPointForCorner(corner)

            let isActive = cornerGlow?.corner == corner
            let radius: CGFloat = isActive ? 30 : 5
            var alpha: CGFloat = isActive ? 0.5 : 0.18

            if isActive, let glow = cornerGlow {
                let remaining = glow.expiry - now
                let pulse = 0.15 * sin(now * 4)
                alpha = CGFloat(max(0.15, min(0.6, 0.45 + pulse)))
                if remaining < 1.5 {
                    alpha *= CGFloat(max(0, remaining / 1.5))
                }
            }

            let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: rect)
            NSColor(calibratedRed: 0.6, green: 0.8, blue: 1.0, alpha: alpha).setFill()
            path.fill()
        }
    }

    private func drawActiveHighlights() {
        for (_, touch) in activeTouches {
            let radius: CGFloat = 26
            let rect = NSRect(x: touch.point.x - radius, y: touch.point.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: rect)
            NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.5, alpha: 0.55).setFill()
            path.fill()
        }
    }
}
