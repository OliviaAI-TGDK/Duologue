// TGDK_SSR.fx — Golden‑phi Screen‑Space Reflections (ReShade 5.x)
// Fixed‑length, predicated loops (no 'break'); compiler‑friendly. φ‑jitter per‑pixel.

#include "ReShade.fxh"

// If TGDK_Clarity.fx is present, keep extern. Otherwise change to 'uniform'.
extern float TGDK_OverlayOpacity;

// ---- Backbuffer ----
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

// ---- Controls ----
uniform float TGDK_SSR_Strength = 0.65;
uniform int TGDK_SSR_MaxSteps = 32; // 1..48 (capped)
uniform float TGDK_SSR_MaxDistPx = 180.0;
uniform float TGDK_SSR_Thickness = 0.020;
uniform float TGDK_SSR_StepPx = 4.0;
uniform int TGDK_SSR_BinarySteps = 4; // 0..8 (capped)
uniform float TGDK_SSR_FresnelPow = 5.0;
uniform float TGDK_SSR_EdgeFadePx = 24.0;
uniform float TGDK_SSR_Roughness = 0.15;
uniform float TGDK_SSR_LumaClamp = 0.85;
uniform float TGDK_SSR_Desat = 0.10;

// ---- Helpers ----
float2 px()
{
    return 1.0 / ReShade::ScreenSize;
}
float LinearDepth(float2 uv)
{
    return ReShade::GetLinearizedDepth(uv);
}
static const float3 Lw = float3(0.2126, 0.7152, 0.0722);
float Luma(float3 c)
{
    return dot(c, Lw);
}

// Golden constants
static const float PHI = 1.61803398875;
static const float GA = 2.39996322973; // golden angle
#define SSR_STEPS 48                    // hard constant for unrolling
#define REFINE_STEPS 8

// Screen-stable hash
float Hash21(float2 p)
{
    p = frac(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return frac(p.x * p.y);
}

float EdgeFade(float2 uv, float fadePx)
{
    float2 d = min(uv, 1.0 - uv) * ReShade::ScreenSize;
    float m = min(d.x, d.y);
    return saturate(m / max(1.0, fadePx));
}

// Normal from depth gradients
float3 ApproxNormal(float2 uv)
{
    float2 p = px();
    float zc = LinearDepth(uv);
    float zx = LinearDepth(uv + float2(p.x, 0.0)) - zc;
    float zy = LinearDepth(uv + float2(0.0, p.y)) - zc;
    return normalize(float3(-zx * ReShade::ScreenSize.x, -zy * ReShade::ScreenSize.y, 1.0));
}

// Screen-projected reflection dir with φ-jitter cone
float2 ScreenRayDir(float2 uv, float3 n, float rough)
{
    float3 V = normalize(float3(0.0, 0.0, -1.0));
    float3 R = reflect(-V, n);
    float2 dir = normalize(R.xy + 1e-6);

    float2 ip = floor(uv * ReShade::ScreenSize);
    float j = Hash21(ip) * GA * PHI;
    float cs = cos(j), sn = sin(j);
    float2 rot = float2(dir.x * cs - dir.y * sn, dir.x * sn + dir.y * cs);
    return normalize(lerp(dir, rot, saturate(rough)));
}

// Fresnel (Schlick)
float Fresnel(float3 n, float3 v, float power)
{
    float f0 = 0.02;
    float ct = saturate(1.0 - abs(dot(n, v)));
    return saturate(f0 + (1.0 - f0) * pow(ct, power));
}

// Reflection sample with restraint
float3 SSR_Reflect(float2 uv_hit)
{
    float3 r = tex2D(BackBuffer, uv_hit).rgb;
    float l = Luma(r);
    if (TGDK_SSR_LumaClamp < 1.0)
    {
        float cl = min(l, TGDK_SSR_LumaClamp);
        r *= (l > 1e-6) ? (cl / l) : 1.0;
    }
    r = lerp(r, l.xxx, saturate(TGDK_SSR_Desat));
    return r;
}

// ---- Main pass ----
struct PSIn
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

float4 PS_TGDK_SSR(PSIn i) : SV_Target
{
    float3 base = tex2D(BackBuffer, i.uv).rgb;

    float z0 = LinearDepth(i.uv);
    if (z0 <= 0.0)
        return float4(base, 1.0);

    float3 n = ApproxNormal(i.uv);
    float3 V = normalize(float3(0.0, 0.0, -1.0));
    float2 dir = ScreenRayDir(i.uv, n, TGDK_SSR_Roughness);
    float2 p = px();

    // Clamp runtime knobs
    int MaxStep = clamp(TGDK_SSR_MaxSteps, 1, SSR_STEPS);
    float MaxDist = max(1.0, TGDK_SSR_MaxDistPx);
    float StepPx = max(0.5, TGDK_SSR_StepPx);

    // Predicated fixed-length march (no breaks)
    float2 uv = i.uv;
    float2 hit_uv = uv;
    bool hit = false;
    float dist_px = 0.0;
    bool done = false;

    [unroll]
    for (int it = 0; it < SSR_STEPS; ++it)
    {
        bool itActive = (it < MaxStep) && (!done);
        float2 uv_next = uv + dir * (StepPx * p);

        bool off = any(uv_next <= float2(0.0, 0.0)) || any(uv_next >= float2(1.0, 1.0));
        float dist_n = dist_px + StepPx;
        bool overdist = (dist_n > MaxDist);

        bool canSample = itActive && !off && !overdist && !hit;

        float z = canSample ? LinearDepth(uv_next) : 0.0;
        bool okDepth = canSample && (z > 0.0);
        bool hitNow = okDepth && (z < (z0 - TGDK_SSR_Thickness));

        // Latch hit UV once
        hit_uv = hit ? hit_uv : (hitNow ? uv_next : hit_uv);
        hit = hit || hitNow;

        // Advance only while active and not done
        bool advance = itActive && !off && !overdist && !hitNow;
        uv = advance ? uv_next : uv;
        dist_px = advance ? dist_n : dist_px;

        // Stop future iterations from doing work
        done = done || off || overdist || hitNow || (it + 1 >= MaxStep);
    }

    // Predicated binary refine (fixed length, no breaks)
    int R = clamp(TGDK_SSR_BinarySteps, 0, REFINE_STEPS);
    float2 a = i.uv, b = hit_uv;

    [unroll]
    for (int j = 0; j < REFINE_STEPS; ++j)
    {
        bool active = hit && (j < R);
        float2 m = (a + b) * 0.5;

        float zm = active ? LinearDepth(m) : 0.0;
        float za = active ? LinearDepth(a) : 0.0;
        bool closer = active && (zm < za);

        a = closer ? a : (active ? m : a);
        b = closer ? m : (active ? b : b);
    }
    hit_uv = b;

    // Compose
    float edge = EdgeFade(i.uv, TGDK_SSR_EdgeFadePx);
    float F = Fresnel(n, V, TGDK_SSR_FresnelPow);

    float3 outc = base;
    if (hit)
    {
        float3 refl = SSR_Reflect(hit_uv);
        float mixv = TGDK_SSR_Strength * TGDK_OverlayOpacity * edge;
        outc = lerp(base, refl, saturate(mixv * F));
    }

    return float4(outc, 1.0);
}

technique TGDK_SSR
{
    pass P
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_TGDK_SSR;
    }
}
