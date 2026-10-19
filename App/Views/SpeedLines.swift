import SwiftUI

/// Smugi prędkości: cienkie, jasne kreski uciekające od środka ekranu ku brzegom — jak rozmycie ruchu
/// w grach wyścigowych. Tylko przy nitro i bardzo dużej prędkości, tylko przy brzegach (środek, gdzie
/// jest auto i droga, zostaje czysty).
struct SpeedLines: View {
    /// 0…1 — siła efektu.
    let intensity: Double

    private struct Streak {
        let angle: Double
        let phase: Double
        let speed: Double
        let width: Double
    }

    private static let streaks: [Streak] = {
        var g = SystemRandomNumberGenerator()
        return (0..<70).map { _ in
            Streak(angle: .random(in: 0..<(2 * .pi), using: &g), phase: .random(in: 0..<1, using: &g),
                   speed: .random(in: 1.4...2.6, using: &g), width: .random(in: 1...2.6, using: &g))
        }
    }()

    var body: some View {
        TimelineView(.animation(paused: intensity <= 0.01)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                guard intensity > 0.01 else { return }
                let c = CGPoint(x: size.width / 2, y: size.height * 0.46)
                let maxR = hypot(size.width, size.height) / 2
                for s in Self.streaks {
                    // Pozycja kreski na promieniu: od 45% do 100% odległości do rogu, w kółko.
                    let p = (s.phase + t * s.speed).truncatingRemainder(dividingBy: 1)
                    let r0 = maxR * (0.45 + 0.55 * p)
                    let r1 = r0 + maxR * 0.2 * (0.5 + p)
                    let dir = CGVector(dx: cos(s.angle), dy: sin(s.angle) * 0.8)
                    var path = Path()
                    path.move(to: CGPoint(x: c.x + dir.dx * r0, y: c.y + dir.dy * r0))
                    path.addLine(to: CGPoint(x: c.x + dir.dx * r1, y: c.y + dir.dy * r1))
                    ctx.stroke(path, with: .color(.white.opacity(0.5 * intensity * p)), lineWidth: s.width * 1.3)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
