import Foundation

/// A single tone field on the handpan.
struct Note {
    let name: String
    let frequency: Double
}

/// D Kurd scale layout: a center "ding" plus eight tone fields in a ring,
/// arranged clockwise starting from the top.
enum HandpanLayout {
    static let ding = Note(name: "D3", frequency: 146.83)

    static let ring: [Note] = [
        Note(name: "A3", frequency: 220.00),
        Note(name: "Bb3", frequency: 233.08),
        Note(name: "C4", frequency: 261.63),
        Note(name: "D4", frequency: 293.66),
        Note(name: "E4", frequency: 329.63),
        Note(name: "F4", frequency: 349.23),
        Note(name: "G4", frequency: 392.00),
        Note(name: "A4", frequency: 440.00),
    ]

    /// Maps a point (relative to the handpan's center) to the note it should trigger.
    /// `centerRadius` and `outerRadius` are in the same units as the point.
    static func note(for point: CGPoint, center: CGPoint, centerRadius: CGFloat, outerRadius: CGFloat) -> (note: Note, sector: Int?)? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()

        guard radius <= outerRadius else { return nil }

        if radius <= centerRadius {
            return (ding, nil)
        }

        // Convert to a compass bearing (0 = up, clockwise positive) so sector 0 is at the top.
        let mathAngle = atan2(dy, dx) // 0 = east, +pi/2 = north (AppKit y-up)
        var bearing = 90 - mathAngle * 180 / .pi
        bearing = bearing.truncatingRemainder(dividingBy: 360)
        if bearing < 0 { bearing += 360 }

        let sectorIndex = Int(bearing / 45) % ring.count
        return (ring[sectorIndex], sectorIndex)
    }
}
