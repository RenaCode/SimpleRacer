public struct Takedown {
    public let attacker: Car
    public let victim: Car
}

/// Zderzenia aut jako prostokątów we współrzędnych trasy.
/// Mocne uderzenie bokiem albo w tył rozbija rywala (takedown), lżejsze — odpycha.
public enum Collisions {
    public static func resolve(_ cars: [Car], trackLength: Double) -> [Takedown] {
        var out: [Takedown] = []
        let L = Physics.carLength, W = Physics.carWidth

        func takedown(_ attacker: Car, _ victim: Car) {
            victim.wreck()
            attacker.takedowns += 1
            attacker.nitro.add(Physics.takedownNitro)
            out.append(Takedown(attacker: attacker, victim: victim))
        }
        func shift(_ car: Car, _ ds: Double) {
            car.s = wrap(car.s + ds, trackLength)
            car.distance += ds
        }

        for i in 0..<cars.count {
            for j in (i + 1)..<cars.count {
                let a = cars[i], b = cars[j]
                if a.wrecked || b.wrecked { continue }
                let ds = wrapDelta(a.s, b.s, trackLength)
                let dd = a.d - b.d
                let overS = L - abs(ds)
                let overD = W - abs(dd)
                if overS <= 0 || overD <= 0 { continue }

                let shockA = a.nitro.mode == .shockwave
                let shockB = b.nitro.mode == .shockwave

                if overD < overS {
                    // Kontakt bokiem. sign > 0: a jest po lewej od b.
                    let sign: Double = dd >= 0 ? 1 : -1
                    a.d += sign * overD / 2
                    b.d -= sign * overD / 2
                    let aPush = -sign * a.lateralSpeed
                    let bPush = sign * b.lateralSpeed
                    let attackerIsA = aPush >= bPush
                    let attacker = attackerIsA ? a : b
                    let victim = attackerIsA ? b : a
                    if aPush + bPush > Physics.sideSlamSpeed || (attackerIsA ? shockA : shockB) {
                        takedown(attacker, victim)
                        victim.alphaVel = attackerIsA ? -sign * 0.5 : sign * 0.5
                    } else {
                        a.alphaVel *= 0.5
                        b.alphaVel *= 0.5
                    }
                } else {
                    // Kontakt przód–tył.
                    let frontIsA = ds > 0
                    let front = frontIsA ? a : b
                    let back = frontIsA ? b : a
                    shift(front, overS / 2)
                    shift(back, -overS / 2)
                    let delta = back.speed - front.speed
                    let backShock = frontIsA ? shockB : shockA
                    if delta > Physics.rearTakedownDelta || (backShock && delta > 0) {
                        takedown(back, front)
                    } else if delta > 0 {
                        let v = (back.speed + front.speed) / 2
                        back.speed = v - 1
                        front.speed = v + 1
                    }
                }
            }
        }
        return out
    }
}
