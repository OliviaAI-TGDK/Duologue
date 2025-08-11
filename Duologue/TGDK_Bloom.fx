// TGDK_Bloom.fx — Soft‑threshold HDR Bloom using MIP sampling (ReShade 5.x DX10/11/12)
// One pass, compile‑safe: fixed loops, no custom depth textures. Honors TGDK_OverlayOpacity.

#include "ReShade.fxh"

// Global master opacity (from TGDK_Clarity.fx). If you don't use Clarity, change 'extern' to 'uniform'.
extern float TGDK_OverlayOpacity;

// ---------- Backbuffer ----------
texture BackBufferTex : COLOR;
sampler BackBuffer
{
    Texture = BackBufferTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
};

// ---------- Controls (kept metadata‑free for max compatibility) ----------
uniform float TBL_Strength = 0.50; // final bloom amount
uniform float TBL_Threshold = 1.0; // linear luma threshold (≈1.0 = 100% white)
uniform float TBL_SoftKnee = 0.50; // 0..1 softness around threshold
uniform float TBL_RadiusPx = 18.0; // base radius in pixels (ring size)
uniform int TBL_Rings = 3; // 1..4 rings (wider blur = higher cost)
uniform float TBL_MipBias = 2.0; // 0..6 extra blur via lower mips
uniform float TBL_TintWarm = 0.00; // -0.2..+0.2 warm/cool shift
uniform float TBL_Clamp = 1.0; // clamp bloom luma (0=off, 1=neutral)

// ---------- Helpers ----------
float2 px()
{
    return 1.0 / ReShade::ScreenSize;
}
static const float3 Lw = float3(0.2126, 0.7152, 0.0722);
float Luma(float3 c)
{
    return dot(c, Lw);
}

// sRGB <-> Linear (branchless-ish)
float3 SRGB_to_Linear(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow(max((c + 0.055) / 1.055, 0.0.xxx), 2.4.xxx);
    float3 cut = step(0.04045.xxx, c);
    return lerp(lo, hi, cut);
}
float3 Linear_to_SRGB(float3 c)
{
    float3 lo = 12.92 * c;
    float3 hi = 1.055 * pow(max(c, 0.0.xxx), 1.0 / 2.4.xxx) - 0.055;
    float3 cut = step(0.0031308.xxx, c);
    return saturate(lerp(lo, hi, cut));
}

// Golden constants
static const float PHI = 1.61803398875;
static const float GA = 2.39996322973; // golden angle ~137.5°

// Soft threshold in linear light
float3 SoftThresholdLin(float3 lin, float th, float knee)
{
    float l = Luma(lin);
    float lo = max(th - knee, 0.0);
    float hi = th + knee;
    float w = saturate((l - lo) / max(1e-5, hi - lo)); // 0..1 blend through knee
    return lin * w;
}

// Small warm/cool tint (kept subtle)
float3 WarmCool(float3 c, float amt)
{
    // amt>0 warms (adds R, removes B); amt<0 cools
    float3 warm = float3(0.8, 1.0, 0.9);
    float3 cool = float3(0.9, 1.0, 1.1);
    float3 target = (amt >= 0.0) ? warm : cool;
    return lerp(c, c * target, abs(amt));
}

// ---------- Main ----------
struct PSIn
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

// Ring weights (fixed length)
static const int MAX_RINGS = 4;
static const int TAPS_PER_RING = 8; // 8 taps per ring
static const int MAX_TAPS = MAX_RINGS * TAPS_PER_RING;

float4 PS_TGDK_Bloom(PSIn i) : SV_Target
{
    // Base sample (sRGB in most games)
    float3 srgb = tex2D(BackBuffer, i.uv).rgb;
    float3 lin = SRGB_to_Linear(srgb);

    // Extract brights with soft knee
    float th = max(0.0, TBL_Threshold);
    float knee = saturate(TBL_SoftKnee) * th;
    float3 ext = SoftThresholdLin(lin, th, knee);

    // Early out if nothing bright
    if (Luma(ext) <= 1e-6)
        return float4(srgb, 1.0);

    // Accumulate blurred bloom using lower mips + golden ring taps
    float2 p = px();
    int R = clamp(TBL_Rings, 1, MAX_RINGS);

    float3 acc = 0.0.xxx;
    float wsum = 0.0;

    // Precompute base mip levels per ring (more outer ring => blurrier)
    float baseMip[MAX_RINGS];
    [unroll]
    for (int r = 0; r < MAX_RINGS; ++r)
    {
        baseMip[r] = (float) r * 1.5 + TBL_MipBias; // 0, 1.5, 3.0, 4.5 + bias
    }

    [unroll]
    for (int r = 0; r < MAX_RINGS; ++r)
    {
        float activeRing = (r < R) ? 1.0 : 0.0;

        // ring radius grows with r
        float ringRadius = TBL_RadiusPx * (1.0 + (float) r * 0.9);
        float2 stepv = p * ringRadius;
        float mipL = max(0.0, baseMip[r]); // lod to sample

        // 8 taps around the ring
        [unroll]
        for (int t = 0; t < TAPS_PER_RING; ++t)
        {
            float a = (float) t * GA; // golden angle stepping
            float2 d = float2(cos(a), sin(a)) * stepv; // offset in pixels
            float2 uv = i.uv + d;

            // guard borders (no sampling off-screen)
            uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));

            // sample lower mip to simulate blur
            float4 cLod = tex2Dlod(BackBuffer, float4(uv, 0.0, mipL));
            float3 linL = SRGB_to_Linear(cLod.rgb);

            // reapply threshold to avoid dark bleed
            float3 extL = SoftThresholdLin(linL, th, knee);

            // weight: outer rings slightly lighter, plus 1/r^2 falloff
            float w = activeRing * (1.0 / (1.0 + (float) r * 0.75));
            acc += extL * w;
            wsum += w;
        }
    }

    float3 bloom = (wsum > 0.0) ? (acc / wsum) : 0.0.xxx;

    // Optional gentle clamp to prevent over‑blooming
    if (TBL_Clamp < 1.0)
    {
        float bl = Luma(bloom);
        float cl = min(bl, TBL_Clamp);
        bloom *= (bl > 1e-6) ? (cl / bl) : 1.0;
    }

    // A tiny warm/cool bias (linear), then back to sRGB
    bloom = WarmCool(bloom, TBL_TintWarm);
    float3 out_lin = lin + bloom * TBL_Strength * TGDK_OverlayOpacity;
    float3 out_srgb = Linear_to_SRGB(out_lin);

    return float4(out_srgb, 1.0);
}

technique TGDK_Bloom
{
    pass P
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_TGDK_Bloom;
    }
}
