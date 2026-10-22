import RaceCore
import SwiftUI

/// Ekran ładowania wyścigu: lekki (żadnej sceny 3D), pokazuje się od razu i płynnie animuje,
/// gdy auta i tekstury wczytują się w tle. Zdjęcie krainy, nazwa trasy, prawdziwy postęp i podpowiedź
/// z piktogramem — dziecko ogląda, czego się spodziewać, zamiast czarnego ekranu.
struct LoadingView: View {
    let spec: TrackSpec
    let progress: Double
    /// Ładowanie się nie udało: zamiast paska komunikat i „Spróbuj ponownie”.
    var error: String?
    var retry: () -> Void = {}
    /// Powrót do menu — zawsze widoczny: bez niego zawieszone ładowanie wymagało zabicia aplikacji.
    var menu: () -> Void = {}
    @State private var photo: UIImage?
    @State private var tip = LoadingView.tips.randomElement()!

    var body: some View {
        ZStack {
            // Zdjęcie w tle przycięte do ekranu (scaledToFill bez tego rozpycha cały widok).
            Color.black
                .overlay {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
                .clipped()
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.35), .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                LogoBanner().padding(.top, 34)
                Spacer()
                Text(spec.region.name)
                    .font(Theme.display(26))
                    .textCase(.uppercase)
                    .foregroundStyle(Color(white: 0.07))
                    .padding(.leading, 28).padding(.trailing, 34).padding(.vertical, 6)
                    .background(SlantShape(slant: 14).fill(Theme.accent))
                    .padding(.leading, 40)
                Text("Trasa \(spec.id) · \(spec.name)")
                    .font(Theme.display(54))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
                    .padding(.leading, 44).padding(.top, 10)
                Label("\(spec.laps) \(spec.laps == 1 ? "okrążenie" : "okrążenia")", systemImage: "flag.checkered")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.leading, 46).padding(.top, 4)

                HStack(alignment: .bottom, spacing: 28) {
                    TipCard(icon: tip.icon, text: tip.text)
                    Spacer(minLength: 0)
                    if let error {
                        VStack(alignment: .trailing, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            Button(action: retry) { Label("Spróbuj ponownie", systemImage: "arrow.clockwise") }
                                .buttonStyle(RaceButtonStyle(primary: true))
                        }
                        .frame(width: 380, alignment: .trailing)
                    } else {
                        ProgressBar(value: progress)
                            .frame(width: 380)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 30)
                .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Button(action: menu) { Label("Menu", systemImage: "house.fill") }
                .buttonStyle(RaceButtonStyle())
                .padding(.top, 34).padding(.trailing, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .task {
            // Mała kopia panoramy krainy (2048 px) — dekodowana poza głównym wątkiem.
            let key = LocalAssets.regionKey(spec.region)
            guard let url = Bundle.main.url(forResource: "sky-\(key)", withExtension: "jpg") else { return }
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let i = UIImage(contentsOfFile: url.path) else { return nil }
                // Pokazujemy pas od horyzontu w górę — tam jest krajobraz, nie asfalt pod aparatem.
                return i.preparingForDisplay().flatMap { $0.cgImage }.flatMap { cg in
                    let h = cg.height, crop = CGRect(x: 0, y: Int(Double(h) * 0.18), width: cg.width / 2, height: Int(Double(h) * 0.42))
                    return cg.cropping(to: crop).map { UIImage(cgImage: $0) }
                }
            }.value
            withAnimation(.easeIn(duration: 0.25)) { photo = image }
        }
    }

    struct Tip { let icon: String; let text: String }

    /// Podpowiedzi dla dzieci — każda z piktogramem, krótka, o tym, co dzieje się w wyścigu.
    static let tips: [Tip] = [
        Tip(icon: "wind", text: "Przytrzymaj DRIFT w zakręcie — dostaniesz nitro!"),
        Tip(icon: "bolt.fill", text: "Zbieraj niebieskie butle — pełny pasek to NITRO!"),
        Tip(icon: "sparkles", text: "Wciśnij NITRO jeszcze raz, gdy pasek świeci — to PERFECT NITRO!"),
        Tip(icon: "car.2.fill", text: "Przejedź blisko rywala — „na włos” daje nitro!"),
        Tip(icon: "star.fill", text: "Wygraj wyścig — zdobędziesz 3 gwiazdki i monety!"),
        Tip(icon: "wrench.and.screwdriver.fill", text: "Za monety ulepszysz auto w garażu."),
    ]
}

private struct TipCard: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.white.opacity(0.1))
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
                Image(systemName: icon).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.nitro)
            }
            .frame(width: 58, height: 58)
            Text(text)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 30).padding(.trailing, 26).padding(.vertical, 14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(SlantShape(slant: 18).fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.92)))
    }
}

/// Pochylony pasek postępu z przesuwającymi się pasami (widać, że gra pracuje, nawet gdy postęp stoi).
struct ProgressBar: View {
    let value: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("\(Int((value * 100).rounded()))%")
                .font(Theme.display(26))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    SlantShape(slant: 12).fill(Color.white.opacity(0.15))
                    TimelineView(.animation) { context in
                        let shift = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 28
                        Canvas { ctx, size in
                            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.accent))
                            var x = -28.0 + shift
                            while x < size.width + 28 {
                                var stripe = Path()
                                stripe.addLines([CGPoint(x: x, y: size.height), CGPoint(x: x + 12, y: size.height),
                                                 CGPoint(x: x + 26, y: 0), CGPoint(x: x + 14, y: 0)])
                                ctx.fill(stripe, with: .color(.white.opacity(0.22)))
                                x += 28
                            }
                        }
                    }
                    .frame(width: max(24, geo.size.width * value))
                    .clipShape(SlantShape(slant: 12))
                    .animation(.easeOut(duration: 0.25), value: value)
                }
            }
            .frame(height: 26)
        }
    }
}
