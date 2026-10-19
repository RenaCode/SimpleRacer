/// Butla nitro leżąca na trasie. Po zebraniu znika na `Physics.pickupRespawn` sekund.
public struct NitroPickup {
    public let s: Double
    public let d: Double
    /// Ile sekund do ponownego pojawienia się; 0 = leży na trasie.
    public var respawnIn = 0.0

    public var isActive: Bool { respawnIn <= 0 }
}

public enum Pickups {
    /// Serie butli wzdłuż trasy, każda seria na innym pasie (lewy, środek, prawy, środek…).
    public static func layout(track: Track) -> [NitroPickup] {
        let lanes = [0.5, 0.0, -0.5, 0.0].map { $0 * track.halfWidth }
        var out: [NitroPickup] = []
        var s = 80.0, group = 0
        // Bez butli tuż przed linią startu, żeby nie leżały pod stawką.
        while s < track.length - 60 {
            for k in 0..<Physics.pickupsPerGroup {
                out.append(NitroPickup(s: s + Double(k) * Physics.pickupSpacing, d: lanes[group % lanes.count]))
            }
            s += Physics.pickupGroupSpacing
            group += 1
        }
        return out
    }
}
