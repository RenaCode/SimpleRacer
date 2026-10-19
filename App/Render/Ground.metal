#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Grunt krainy: tekstura kafelkowana w układzie świata, a w oddali grunt płynnie znika i odsłania
// grunt ze zdjęcia panoramy — bez widocznej krawędzi „podłogi” na horyzoncie.
// custom_parameter: x = rozmiar kafla (m), y = odległość początku zanikania (m), z = 1 — zanikanie włączone
// (pierścień przezroczysty), 0 — środek nieprzezroczysty.
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

}

[[visible]]
void groundSurface(realitykit::surface_parameters params)
{
    constexpr sampler tiled(address::repeat, filter::linear, mip_filter::linear, max_anisotropy(16));
    float3 wp = params.geometry().world_position();
    float4 p = params.uniforms().custom_parameter();
    float tile = p.x;

    // Odległość od kamery z macierzy widoku — bez podmiany materiału co klatkę.
    float dist = length((params.uniforms().world_to_view() * float4(wp, 1.0)).xyz);

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

    params.surface().set_base_color(half3(saturate(color)));
    params.surface().set_roughness(1.0);
    params.surface().set_metallic(0.0);
    if (p.z > 0.5) {
        params.surface().set_opacity(half(1.0 - smoothstep(p.y, p.y * 2.5, dist)));
    }
}
