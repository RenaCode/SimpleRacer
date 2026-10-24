#include <metal_stdlib>
using namespace metal;

// Obróbka obrazu wyścigu (RacePostEffect.swift): poświata jasnych miejsc (bloom), mgła powietrzna
// liczona z bufora głębi, delikatna korekcja tonów i winieta — jeden przebieg na pełnym ekranie
// plus mały przebieg jasnych miejsc w ćwiartce rozdzielczości.

struct PostUniforms {
    float4 fog;          // rgb — kolor mgły (kolor horyzontu z panoramy), a — największa gęstość
    float2 depth;        // projekcja: m[2][2], m[3][2] — do odległości z głębi
    float fogScale;      // odległość (m), na której mgła osiąga ~63% gęstości
    float fogEnd;        // za tą odległością mgły już nie ma (kopuła panoramy jest dalej)
    float bloom;         // siła poświaty
    float vignette;
    float saturation;
    float contrast;
    float linear;        // 1 — kolory w przestrzeni liniowej (tekstura sRGB / HDR), 0 — w gamma
};

// Jasne miejsca zmniejszone 4× (średnia z 4 próbek z filtrowaniem = 16 pikseli źródła).
kernel void postBright(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float &threshold [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float2 px = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = src.sample(s, uv + px * float2(-1, -1)).rgb
             + src.sample(s, uv + px * float2( 1, -1)).rgb
             + src.sample(s, uv + px * float2(-1,  1)).rgb
             + src.sample(s, uv + px * float2( 1,  1)).rgb;
    c *= 0.25;
    float l = max(c.r, max(c.g, c.b));
    float k = smoothstep(threshold, threshold + 0.3, l);
    dst.write(float4(c * k, 1), gid);
}

struct PostVertex {
    float4 position [[position]];
    float2 uv;
};

// Jeden trójkąt zakrywający cały ekran.
vertex PostVertex postVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    PostVertex out;
    out.position = float4(p * 2 - 1, 0, 1);
    out.uv = float2(p.x, 1 - p.y);
    return out;
}

static float3 toGamma(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }
static float3 toLinear(float3 c) { return pow(max(c, 0.0), 2.2); }

fragment float4 postComposite(PostVertex in [[stage_in]],
                              texture2d<float, access::sample> src [[texture(0)]],
                              texture2d<float, access::sample> glow [[texture(1)]],
                              depth2d<float, access::sample> depth [[texture(2)]],
                              constant PostUniforms &u [[buffer(0)]]) {
    constexpr sampler point(filter::nearest, address::clamp_to_edge);
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float4 base = src.sample(point, in.uv);
    float3 c = base.rgb;

    // Mgła powietrzna: odległość z głębi (odwrócona głębia: 0 = nieskończoność). Przy wyłączonej mgle
    // (dziś w wyścigu) bez odczytu głębi — to cały ekran próbek w każdej klatce na darmo.
    float z = u.fog.a > 0 ? depth.sample(point, in.uv) : 0;
    float denom = z + u.depth.x;
    if (u.fog.a > 0 && denom > 1e-6) {
        float dist = u.depth.y / denom;
        float f = u.fog.a * (1 - exp(-dist / u.fogScale));
        f *= 1 - smoothstep(u.fogEnd * 0.85, u.fogEnd, dist);
        c = mix(c, u.fog.rgb, saturate(f));
    }

    // Poświata: rozmyte jasne miejsca dodane ekranowo (nie przepala bieli).
    float3 g = glow.sample(lin, in.uv).rgb * u.bloom;
    c = 1 - (1 - c) * (1 - saturate(g));

    // Korekcja tonów w przestrzeni gamma: łagodna krzywa S, nasycenie, winieta.
    // `saturate`: krzywa S poza [0, 1] daje wartości ujemne (źródło HDR); dziś źródło jest 8-bitowe.
    float3 d = saturate(u.linear > 0.5 ? toGamma(c) : c);
    d = mix(d, d * d * (3 - 2 * d), u.contrast);
    float luma = dot(d, float3(0.2126, 0.7152, 0.0722));
    d = mix(float3(luma), d, u.saturation);
    float2 q = in.uv - 0.5;
    d *= 1 - u.vignette * smoothstep(0.25, 0.75, dot(q, q) * 2.2);
    // Dithering (±½ kroku 8 bitów): gładkie niebo bez schodków po korekcji tonów.
    float n = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    d += n / 255.0;
    c = u.linear > 0.5 ? toLinear(d) : d;
    return float4(saturate(c), base.a);
}
