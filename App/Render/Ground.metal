#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Grunt krainy: tekstura kafelkowana w układzie świata, a w oddali grunt płynnie znika i odsłania
// grunt ze zdjęcia panoramy — bez widocznej krawędzi „podłogi” na horyzoncie.
// custom_parameter: x = rozmiar kafla (m), y = odległość początku zanikania (m; ujemna — bez zanikania, środek
// nieprzezroczysty), z = mgła (hazeAmount), w = wzmocnienie koloru (z tintem: barwa gruntu panoramy).
//
// Żeby nie było widać powtarzania kafla, ta sama tekstura idzie w dwóch skalach: drobnej (kafel) i dużej
// (~8,3 kafla, obróconej), a na to makro-szum jasności i odcienia w skali dziesiątek metrów — jak plamy
// wilgoci, wydeptane miejsca i różnice podłoża na prawdziwym terenie.

namespace {

// Szum wartości 2D (gładki, bez tekstury) — wystarczy do łagodnych plam.
float hash21(float2 p)
{
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float valueNoise(float2 p)
{
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 2.0 - 1.0;
}

// Mgła powietrzna (Haze.swift): `packed` = zasięg (m, część całkowita) + gęstość (część ułamkowa); 0 — bez mgły.
float hazeAmount(float dist, float packed)
{
    if (packed < 1.0) { return 0.0; }
    float scale = floor(packed), density = fract(packed);
    return density * (1.0 - exp(-dist / scale));
}

// Jasność emisji, przy której mgła daje kolor horyzontu panoramy po oświetleniu i tonemappingu
// (dobrana kanarkiem `-haze 0.99,20`: zamglony kadr w barwie nieba nad horyzontem).
constant float hazeEmission = 1.0;

// Mgła w oświetlanym materiale: kolor własny i odbicia gasną, a barwa mgły świeci (emisja) — tak samo,
// jak gdyby obraz zmieszać z kolorem mgły po oświetleniu.
void applyHaze(realitykit::surface_parameters params, float3 baseColor, float dist, float packed)
{
    float f = hazeAmount(dist, packed);
    float3 fog = float3(params.material_constants().emissive_color());
    params.surface().set_base_color(half3(saturate(baseColor * (1.0 - f))));
    params.surface().set_emissive_color(half3(fog * f * hazeEmission));
    params.surface().set_specular(half(0.5 * (1.0 - f)));
}

float viewDistance(realitykit::surface_parameters params)
{
    float3 wp = params.geometry().world_position();
    return length((params.uniforms().world_to_view() * float4(wp, 1.0)).xyz);
}

}

[[visible]]
void groundSurface(realitykit::surface_parameters params)
{
    constexpr sampler tiled(address::repeat, filter::linear, mip_filter::linear, max_anisotropy(16));
    float3 wp = params.geometry().world_position();
    float4 p = params.uniforms().custom_parameter();
    float tile = p.x;

    // Odległość od kamery z macierzy widoku — bez podmiany materiału co klatkę.
    float dist = viewDistance(params);

    auto tex = params.textures().base_color();
    // Średni kolor zdjęcia (najmniejszy mip) — względem niego liczymy, o ile duża skala rozjaśnia lub przyciemnia.
    float3 mean = max(float3(tex.sample(tiled, float2(0.5), level(16)).rgb), float3(0.02));

    float2 uvFine = wp.xz / tile;
    // Duża skala: obrót o ~37° i niewymierny stosunek skal, żeby siatki obu kafli się nie pokrywały.
    const float2x2 rot = float2x2(float2(0.7986, 0.6018), float2(-0.6018, 0.7986));
    float2 uvLarge = rot * (wp.xz / (tile * 8.27)) + float2(0.37, 0.71);
    float3 fine = float3(tex.sample(tiled, uvFine).rgb);
    float3 large = float3(tex.sample(tiled, uvLarge).rgb);

    // Drobny kafel niesie szczegół i kolor, duży — plamy jaśniejsze i ciemniejsze (tylko jasność: stosunek
    // kanałów wprowadzałby obce odcienie); w oddali, gdzie powtarzanie drobnego kafla widać najbardziej,
    // część koloru bierze duża skala.
    const float3 lumaW = float3(0.2126, 0.7152, 0.0722);
    float lm = max(dot(mean, lumaW), 0.02);
    float largeL = clamp(dot(large, lumaW) / lm, 0.7, 1.35), fineL = clamp(dot(fine, lumaW) / lm, 0.7, 1.35);
    float3 color = fine * mix(1.0, largeL, 0.5);
    color = mix(color, large * mix(1.0, fineL, 0.5), smoothstep(30.0, 160.0, dist) * 0.5);

    // Makro-szum: jasność ±~12 % w skali ~90 m i ~25 m, lekki odcień cieplej/chłodniej w skali ~140 m.
    float n1 = valueNoise(wp.xz / 90.0 + 17.0), n2 = valueNoise(wp.xz / 25.0 - 31.0), n3 = valueNoise(wp.xz / 140.0 + 5.0);
    color *= 1.0 + n1 * 0.09 + n2 * 0.04;
    color *= mix(float3(0.985, 1.0, 1.02), float3(1.02, 1.0, 0.97), n3 * 0.5 + 0.5);

    // Barwa dopasowana do gruntu na zdjęciu panoramy (tint — odcień, w — wzmocnienie; garaż: biały i 1).
    color *= float3(params.material_constants().base_color_tint()) * p.w;

    applyHaze(params, color, dist, p.z);
    params.surface().set_roughness(1.0);
    params.surface().set_metallic(0.0);
    if (p.y > 0.0) {
        params.surface().set_opacity(half(1.0 - smoothstep(p.y, p.y * 2.5, dist)));
    }
}

// Jezdnia: zdjęcie asfaltu (kafel 4 m, UV w metrach / kafel: u — w poprzek, v — wzdłuż) i to, czego kafel
// nie ma, a widać na każdej prawdziwej drodze: plamy jaśniejsze i ciemniejsze w skali kilkudziesięciu metrów,
// wyjeżdżone (gładsze, ciemniejsze) ślady kół na każdym pasie i jaśniejszy, matowy kurz przy krawężnikach.
// custom_parameter: x = kafel (m), y = połowa szerokości jezdni (m), z = mgła (hazeAmount).
[[visible]]
void roadSurface(realitykit::surface_parameters params)
{
    constexpr sampler tiled(address::repeat, filter::linear, mip_filter::linear, max_anisotropy(16));
    float4 p = params.uniforms().custom_parameter();
    float tile = p.x, hw = p.y;
    float2 uv = float2(params.geometry().uv0());
    float3 wp = params.geometry().world_position();
    // UV w RealityKit ma odwrócone v względem siatki — d bierzemy z u, które nie jest odwracane.
    float d = uv.x * tile;

    float3 color = float3(params.textures().base_color().sample(tiled, uv).rgb)
        * float3(params.material_constants().base_color_tint());
    float rough = float(params.textures().roughness().sample(tiled, uv).r) * 0.9;

    // Plamy: łatki, starsze i nowsze odcinki nawierzchni.
    float n1 = valueNoise(wp.xz / 38.0 + 3.0), n2 = valueNoise(wp.xz / 9.0 - 11.0);
    color *= 1.0 + n1 * 0.08 + n2 * 0.035;

    // Ślady kół: trzy pasy (granice na ±hw/3), w każdym dwa ślady 0,8 m od środka pasa.
    float lane = hw * 2.0 / 3.0;
    float inLane = fmod(d + hw + lane * 4.0, lane) - lane * 0.5; // odległość od środka pasa
    float wheel = 1.0 - smoothstep(0.18, 0.45, abs(abs(inLane) - 0.8));
    // Ślady nie są jednolite: wyraźniejsze i słabsze odcinki wzdłuż drogi.
    wheel *= 0.6 + 0.4 * (valueNoise(float2(d * 0.5, wp.x * 0.05 + wp.z * 0.05)) * 0.5 + 0.5);
    color *= 1.0 - wheel * 0.12;
    rough -= wheel * 0.12;
    // Środek pasa: olej kapiący z aut — lekko ciemniejszy pas.
    color *= 1.0 - (1.0 - smoothstep(0.15, 0.5, abs(inLane))) * 0.05;

    // Kurz i piasek przy krawężnikach: jaśniej, cieplej, matowo.
    float edge = smoothstep(hw - 1.1, hw - 0.1, abs(d));
    edge *= 0.7 + 0.3 * (valueNoise(wp.xz / 4.0) * 0.5 + 0.5);
    color = mix(color, color * float3(1.22, 1.16, 1.06), edge);
    rough = mix(rough, 1.0, edge * 0.6);

    applyHaze(params, color, viewDistance(params), p.z);
    params.surface().set_roughness(half(saturate(rough)));
    params.surface().set_metallic(0.0);
    float3 n = float3(params.textures().normal().sample(tiled, uv).rgb) * 2.0 - 1.0;
    params.surface().set_normal(normalize(n));
}

// Materiał PBR (mury, budynki, linie, krawężniki, rekwizyty) z mgłą — Haze.apply przepisuje na niego
// PhysicallyBasedMaterial z tymi samymi teksturami. custom_parameter: x = mgła, y = maska tekstur
// (1 — chropowatość, 2 — metaliczność, 4 — normalne, 8 — kolor); bez tekstury liczy się sama skala.
[[visible]]
void hazeSurface(realitykit::surface_parameters params)
{
    constexpr sampler tiled(address::repeat, filter::linear, mip_filter::linear, max_anisotropy(16));
    float4 p = params.uniforms().custom_parameter();
    int flags = int(p.y + 0.5);
    float2 uv = float2(params.geometry().uv0());
    uv.y = 1.0 - uv.y; // w shaderze v jest odwrócone względem materiału PBR
    auto mc = params.material_constants();
    float3 color = float3(mc.base_color_tint());
    if (flags & 8) { color *= float3(params.textures().base_color().sample(tiled, uv).rgb); }
    float rough = mc.roughness_scale();
    if (flags & 1) { rough *= float(params.textures().roughness().sample(tiled, uv).r); }
    float metal = mc.metallic_scale();
    if (flags & 2) { metal *= float(params.textures().metallic().sample(tiled, uv).r); }
    if (flags & 4) {
        float3 n = float3(params.textures().normal().sample(tiled, uv).rgb) * 2.0 - 1.0;
        params.surface().set_normal(normalize(n));
    }
    applyHaze(params, color, viewDistance(params), p.x);
    params.surface().set_roughness(half(saturate(rough)));
    params.surface().set_metallic(half(saturate(metal)));
}
