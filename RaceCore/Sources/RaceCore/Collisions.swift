public struct Takedown {
    public let attacker: Car
    public let victim: Car
}

/// Zderzenia aut jako prostokątów we współrzędnych trasy — o wymiarach z `def.shape` każdego auta
/// (dla pary: średnia długości i szerokości, czyli styk dwóch prostokątów o połówkach La/2 i Lb/2).
/// Mocne uderzenie gracza bokiem albo w tył rozbija rywala (takedown), lżejsze — odpycha.
///
/// Gra dla dzieci: takedown to wyłącznie nagroda gracza. Rywal nigdy nie rozbija gracza, a rywale
/// między sobą też się nie rozbijają (rozbicia w ścisku na starcie tylko zaśmiecały ekran) — takie
/// zderzenia kończą się zwykłym odepchnięciem albo wymianą prędkości.
public enum Collisions {
    public static func resolve(_ cars: [Car], trackLength: Double) -> [Takedown] {
        var out: [Takedown] = []

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
                let playerShock = (shockA && a.isPlayer) || (shockB && b.isPlayer)

                if overD < overS {
                    // Kontakt bokiem. sign > 0: a jest po lewej od b.
                    let sign: Double = dd >= 0 ? 1 : -1
                    a.d += sign * overD / 2
                    b.d -= sign * overD / 2
                    let aPush = -sign * a.lateralSpeed
                    let bPush = sign * b.lateralSpeed
                    // Fala gracza rozbija przy każdym styku — napastnikiem jest gracz, nawet gdy to rywal pcha
                    // mocniej (inaczej gracz w fali zostawał „ofiarą”, której nic się nie dzieje). Fala rywala
                    // nie zmienia wyboru: rywal i tak gracza nie rozbija, a mocniej pchający gracz dalej rozbija rywala.
                    let attackerIsA = playerShock ? a.isPlayer : aPush >= bPush
                    let attacker = attackerIsA ? a : b
                    let victim = attackerIsA ? b : a
                    // Mocniej pchający rywal nie dostaje nic: dawniej gracz-„ofiara” dostawał 90% prędkości rywala,
                    // czyli skok np. 20 → 54 m/s w jednym kroku od samego otarcia.
                    if attacker.isPlayer && (aPush + bPush > Physics.sideSlamSpeed || (attackerIsA ? shockA : shockB)) {
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
                    if playerShock && front.isPlayer && delta > 0 {
                        // Rywal, który wjeżdża w tył gracza w fali, rozbija się.
                        takedown(front, back)
                    } else if back.isPlayer && (delta > Physics.rearTakedownDelta || (backShock && delta > 0)) {
                        takedown(back, front)
                    } else if delta > 0 {
                        // Także rywal wjeżdżający szybko w gracza albo w innego rywala: wymiana prędkości,
                        // bez niej tylny przenikał przez przedni.
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
