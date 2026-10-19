#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Grunt krainy: tekstura kafelkowana w układzie świata, a w oddali grunt płynnie znika i odsłania
// grunt ze zdjęcia panoramy — bez widocznej krawędzi „podłogi” na horyzoncie.
// custom_parameter: xy = pozycja kamery (x, z), z = rozmiar kafla (m), w = odległość początku zanikania (m).
[[visible]]
void groundSurface(realitykit::surface_parameters params)
{
    constexpr sampler tiled(address::repeat, filter::linear, mip_filter::linear, max_anisotropy(16));
    float3 wp = params.geometry().world_position();
    float4 p = params.uniforms().custom_parameter();
    half3 color = params.textures().base_color().sample(tiled, wp.xz / p.z).rgb;
    float dist = distance(wp.xz, p.xy);
    float alpha = 1.0 - smoothstep(p.w, p.w * 2.5, dist);
    params.surface().set_base_color(color);
    params.surface().set_roughness(1.0);
    params.surface().set_metallic(0.0);
    params.surface().set_opacity(half(alpha));
}
