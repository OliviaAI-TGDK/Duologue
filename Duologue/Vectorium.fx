// Vectorium.fx — Directional vector-field projection (ReShade 5.x DX10/11/12)
// Purpose: build a screen-space "vector field" from gradients, then project planar taps
// along that field to (1) suppress shimmer / perceived motion, and (2) enhance fidelity
// orthogonal to edges. No history buffers or real motion vectors required.
// Place AFTER Driver, BEFORE Skylight/finishing.

#include "ReShade.fxh"

// Backbuffer
texture BackBufferTex : COLOR;
sampler BackBuffer {
    Texture = BackBufferTex;
    AddressU = Clamp; AddressV = Clamp;
    MinFilter = Linear; MagFilter = Linear; MipFilter = Linear;
};

// Controls (kept metadata-free for max compatibility)
uniform float VEC_Strength        = 0.65; // master mix 0..1
uniform float VEC_SharpBoost      = 0.20; // edge-orthogonal micro-sharpen 0..0.5
uniform float VEC_BlurAlong       = 0.85; // edge-parallel projection amount 0..1
uniform float VEC_Radius          = 1.75; // tap radius in pixels
uniform float VEC_EdgeThreshold   = 0.08; // gradient threshold for "edge"
uniform float VEC_NoiseFloor      = 0.01; // luma floor to avoid overreacting in fog
uniform float VEC_Cadence         = 1.00; // 0..1: extra smoothing "cadence" (visual pacing)
uniform int   VEC_Quality         = 1;    // 0=low (2 taps) / 1=med (4) / 2=high (6)

// Helpers
static const float3 Lw = float3(0.2126, 0.7152, 0.0722);
float  Luma(float3 c) { return dot(c, Lw); }
float2 px() { return 1.0 / ReShade::ScreenSize; }

// Sobel gradients (single pass)
void Sobel(float2 uv, out float gx, out float gy)
{
    float2 p = px();
    float3 a = tex2D(BackBuffer, uv + float2(-p.x,-p.y)).rgb;
    float3 b = tex2D(BackBuffer, uv + float2( 0.0 , -p.y)).rgb;
    float3 c = tex2D(BackBuffer, uv + float2( p.x, -p.y)).rgb;
    float3 d = tex2D(BackBuffer, uv + float2(-p.x, 0.0 )).rgb;
    float3 f = tex2D(BackBuffer, uv + float2( p.x, 0.0 )).rgb;
    float3 g = tex2D(BackBuffer, uv + float2(-p.x, p.y)).rgb;
    float3 h = tex2D(BackBuffer, uv + float2( 0.0 , p.y)).rgb;
    float3 i = tex2D(BackBuffer, uv + float2( p.x, p.y)).rgb;

    float la = Luma(a), lb = Luma(b), lc = Luma(c);
    float ld = Luma(d), lf = Luma(f);
    float lg = Luma(g), lh = Luma(h), li = Luma(i);

    gx = (lc + 2.0*lf + li) - (la + 2.0*ld + lg);
    gy = (lg + 2.0*lh + li) - (la + 2.0*lb + lc);
}

// Build a normalized direction (edge tangent) and energy
void VectorField(float2 uv, out float2 dir_tangent, out float energy)
{
    float gx, gy; Sobel(uv, gx, gy);

    // Edge normal is (gx, gy); tangent is perpendicular
    float2 n = float2(gx, gy);
    float len = max(length(n), 1e-6);
    float2 t = float2(-n.y, n.x) / len; // tangent

    // Energy scaled to 0..1 range
    energy = saturate(len * 0.5);
    dir_tangent = t;
}

// Project planar taps along the tangent direction; cross taps for sharpening
float3 ProjectedComposite(float2 uv, float2 tangent, float energy, float radius, int quality, float blurAlong, float sharpBoost)
{
    float2 p = px();
    float2 r = tangent * radius * p;               // along-edge direction
    float2 o = float2(-tangent.y, tangent.x) * radius * 0.75 * p; // orthogonal

    // Base sample
    float3 base = tex2D(BackBuffer, uv).rgb;

    // Quality sets tap count
    int along_pairs = (quality == 0 ? 1 : (quality == 1 ? 2 : 3));

    float3 along_acc = base;
    float  along_w   = 1.0;

    // Along-edge smoothing (reduces perceived motion/jitter)
    [unroll] for (int i = 0; i < 3; ++i)
    {
        if (i >= along_pairs) break;
        float k = (float)(i+1);
        float2 off = r * k;
        float3 s1 = tex2D(BackBuffer, uv + off).rgb;
        float3 s2 = tex2D(BackBuffer, uv - off).rgb;

        // Heavier weight when energy is high (busy / fast-changing areas)
        float w = lerp(0.25, 0.65, energy) * blurAlong;

        along_acc += s1 * w + s2 * w;
        along_w   += 2.0 * w;
    }
    float3 along_avg = along_acc / max(1e-4, along_w);

    // Cross-edge micro-sharpen (preserve edge fidelity)
    float3 cross1 = tex2D(BackBuffer, uv + o).rgb;
    float3 cross2 = tex2D(BackBuffer, uv - o).rgb;
    float3 cross_boost = (base * 2.0 - (cross1 + cross2) * 0.5);

    // Combine: more smoothing when energy high, more sharpen when energy low
    float smooth_amt = saturate(energy);
    float sharp_amt  = (1.0 - smooth_amt);

    float3 composed = lerp(base, along_avg, smooth_amt);
    composed = composed + cross_boost * sharpBoost * sharp_amt;

    return composed;
}

struct PSIn { float4 pos : SV_Position; float2 uv : TEXCOORD; };

float3 VectoriumProcess(float2 uv)
{
    float3 col = tex2D(BackBuffer, uv).rgb;

    // Early exit on low-contrast scenes to save work
    float l = Luma(col);
    if (l < VEC_NoiseFloor) return col;

    float2 t; float e;
    VectorField(uv, t, e);

    // Thresholding & cadence: amplify or relax effect
    float edge = step(VEC_EdgeThreshold, e);
    float cadence = lerp(1.0, 1.15, saturate(VEC_Cadence)); // gentle pacing factor

    float3 proj = ProjectedComposite(uv, t, e, VEC_Radius * cadence, VEC_Quality, VEC_BlurAlong, VEC_SharpBoost);

    // Master mix gated by edge presence (do very little in flat foggy areas)
    float m = VEC_Strength * edge;
    return lerp(col, proj, m);
}

float4 PS_Vectorium(PSIn i) : SV_Target
{
    return float4(VectoriumProcess(i.uv), 1.0);
}

technique Vectorium
{
    pass P { VertexShader = PostProcessVS; PixelShader = PS_Vectorium; }
}
