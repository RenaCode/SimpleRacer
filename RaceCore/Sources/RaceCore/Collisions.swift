public struct Takedown {
    public let attacker: Car
    public let victim: Car
}

/// Zderzenia aut jako prostokątów we współrzędnych trasy — o wymiarach z `def.shape` każdego auta
/// (dla pary: średnia długości i szerokości, czyli styk dwóch prostokątów o połówkach La/2 i Lb/2).
/// Mocne uderzenie bokiem albo w tył rozbija rywala (takedown), lżejsze — odpycha.
public enum Collisions {
    public static func resolve(_ cars: [Car], trackLength: Double) -> [Takedown] {
        var out: [Takedown] = []

        func takedown(_ attacker: Car, _ victim: Car) {
            // Gra dla dzieci: rywal nigdy nie rozbija gracza — kończy się na odepchnięciu.
            if victim.isPlayer && !attacker.isPlayer {
                victim.speed = max(victim.speed, attacker.speed * 0.9)
                return
            }
            // Rywale między sobą tylko się przepychają: rozbicia w ścisku na starcie (ok. 1–2 na wyścig)
            // tylko zaśmiecały ekran koziołkującymi autami. Takedown to nagroda gracza.
            if !attacker.isPlayer && !victim.isPlayer { return }
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
                if a.wrecked && b.wrecked { continue }
                let ds = wrapDelta(a.s, b.s, trackLength)
                let dd = a.d - b.d
                let L = (a.def.shape.length + b.def.shape.length) / 2
                let W = (a.def.shape.width + b.def.shape.width) / 2
                let overS = L - abs(ds)
                let overD = W - abs(dd)
                if overS <= 0 || overD <= 0 { continue }
                // Rozbite auto to przeszkoda, nie duch: jadące auto łagodnie omija je bokiem,
                // bez utraty prędkości i bez kolejnego rozbicia.
                if a.wrecked || b.wrecked {
                    let live = a.wrecked ? b : a
                    let sign: Double = (live === a ? dd : -dd) >= 0 ? 1 : -1
                    live.d += sign * min(overD, Physics.wreckAvoidStep)
                    continue
                }

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
                        if victim.wrecked { victim.alphaVel = attackerIsA ? -sign * 0.5 : sign * 0.5 }
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
                        back.speed = max(0, v - 1) // przy styku poniżej 1 m/s auto toczyło się wstecz
                        front.speed = v + 1
                    }
                }
            }
        }
        return out
    }
}
