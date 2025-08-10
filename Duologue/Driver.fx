// Driver.fx  —  One-technique post chain (exposure + filmic + micro-contrast + deband + sharpen)
// Works with current ReShade (DX10/11/12). No external deps. Designed for RT-friendly realism.
//
// Order suggestion (top → bottom):
//   1) qUINT_RTGI (if you own it)
//   2) Driver (this file)
//   3) Optional tiny color trims (Lightroom/PD80) if you really need them
//
// Notes:
// - Keep game sharpening OFF (DLSS/FSR sharpen off too). Let Driver do it.
// - Film grain / chromatic aberration OFF in game.
// - If performance dips, lower Deband Iterations or set DebandStrength=0.

#include "ReShade.fxh"

// --------------------------------------------------------------------------------------
// BACKBUFFER & DEPTH (depth not required; kept for future guidance)
// --------------------------------------------------------------------------------------
texture BackBufferTex : COLOR;
sampler BackBuffer { Texture = BackBufferTex; AddressU = Clamp; AddressV = Clamp; MinFilter = Linear; MagFilter = Linear; MipFilter = Linear; };

texture DepthTex : DEPTH;
sampler DepthSamp { Texture = DepthTex; AddressU = Clamp; AddressV = Clamp; MinFilter = Point; MagFilter = Point; MipFilter = Point; };

// --------------------------------------------------------------------------------------
// UI / CONTROLS
// --------------------------------------------------------------------------------------
uniform float DRV_Strength       < ui_label = "Master Strength", ui_min = 0.0, ui_max = 1.0, ui_step = 0.01 > = 1.0;

// Exposure / Tonemap
uniform float DRV_TargetGray     < ui_label = "Target Mid-Gray", ui_min = 0.05, ui_max = 0.30, ui_step = 0.005 > = 0.18;
uniform float DRV_MinEV          < ui_label = "EV Min",          ui_min = -4.0, ui_max =  2.0, ui_step = 0.1   > = -1.5;
uniform float DRV_MaxEV          < ui_label = "EV Max",          ui_min = -2.0, ui_max =  4.0, ui_step = 0.1   > =  1.5;
uniform bool  DRV_UseACES        < ui_label = "Use ACES (else Hable)" > = true;

// Tone shaping
uniform float DRV_ShadowLift     < ui_label = "Shadow Lift",     ui_min = -0.20, ui_max = 0.30, ui_step = 0.01 > = 0.04;
uniform float DRV_HighlightRoll  < ui_label = "Highlight Roll-off", ui_min = 0.0, ui_max = 1.0, ui_step = 0.01 > = 0.35;
uniform float DRV_MicroContrast  < ui_label = "Micro-Contrast",  ui_min = -0.40, ui_max = 0.40, ui_step = 0.01 > = 0.08;
uniform float DRV_Saturation     < ui_label = "Saturation",      ui_min = 0.70, ui_max = 1.20, ui_step = 0.01 > = 0.96;

// Deband
uniform float DRV_DebandStrength < ui_label = "Deband Strength", ui_min = 0.0, ui_max = 1.0, ui_step = 0.01 > = 0.35;
uniform float DRV_DebandThreshold< ui_label = "Deband Threshold",ui_min = 0.001, ui_max = 0.02, ui_step = 0.001 > = 0.008;
uniform float DRV_DebandRange    < ui_label = "Deband Range",    ui_min = 2.0, ui_max = 32.0, ui_step = 1.0 > = 16.0;
uniform int   DRV_DebandIters    < ui_label = "Deband Iterations", ui_min = 0, ui_max = 3 > = 1;

// Sharpen (edge‑aware)
uniform float DRV_SharpStrength  < ui_label = "Sharpen Strength",ui_min = 0.0, ui_max = 1.0, ui_step = 0.01 > = 0.27;
uniform float DRV_SharpRadius    < ui_label = "Sharpen Radius (px)", ui_min = 0.5, ui_max = 3.0, ui_step = 0.1 > = 2.0;
uniform float DRV_SharpEdgeGuard < ui_label = "Edge Guard",      ui_min = 0.0, ui_max = 1.0, ui_step = 0.01 > = 0.35;

// Performance preset (affects internal mixes)
uniform int   DRV_PerfMode       < ui_label = "Perf Mode (0 Low / 1 Med / 2 High)", ui_min = 0, ui_max = 2 > = 1;

// --------------------------------------------------------------------------------------
// HELPERS
// --------------------------------------------------------------------------------------
#define PI 3.14159265

float3 LumaWeights709 = float3(0.2126, 0.7152, 0.0722);
float  Luma709(float3 c) { return dot(c, LumaWeights709); }

float2 px() { return 1.0 / ReShade::ScreenSize; }

// Hash / noise (cheap)
float Hash21(float2 p)
{
    p = frac(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return frac(p.x * p.y);
}

// Filmic curves
float3 TonemapACES(float3 x)
{
    // Narkowicz ACES approx
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}
float3 TonemapHable(float3 x)
{
    // Hable/U2
    const float A = 0.22, B = 0.30, C = 0.10, D = 0.20, E = 0.01, F = 0.30;
    return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F)) - E/F;
}

// Adaptive exposure using low mips
float AverageLuma()
{
    float2 uv = ReShade::GetTexCoord();
    float a = Luma709(tex2Dlod(BackBuffer, float4(uv, 0, 2)).rgb);
    float b = Luma709(tex2Dlod(BackBuffer, float4(uv, 0, 4)).rgb);
    float c = Luma709(tex2Dlod(BackBuffer, float4(uv, 0, 6)).rgb);
    return max(1e-4, (a * 0.2 + b * 0.35 + c * 0.45));
}

// Shadow/Highlight shaping
float3 ShadowHighlight(float3 col, float lift, float roll)
{
    float3 s  = pow(saturate(col), 1.0 / (1.0 + max(0.0, lift) * 2.0)); // open shadows
    float3 hi = 1.0 - exp2(-(1.0 - s) * (1.0 + roll * 4.0));           // compress highlights
    return lerp(col, saturate(hi), 0.6) + lift;
}

// Micro‑contrast around mid‑gray
float3 MicroContrast(float3 c, float strength, float mid)
{
    return c + (c - mid) * strength;
}

// Edge‑aware sharpen (bilateral‑guarded USM)
float3 SharpenBilateral(float2 uv, float radius, float strength, float edge_guard)
{
    float2 p = px();
    float2 r = p * radius;

    float3 c  = tex2D(BackBuffer, uv).rgb;
    float3 n  = tex2D(BackBuffer, uv + float2(0, -r.y)).rgb;
    float3 s  = tex2D(BackBuffer, uv + float2(0,  r.y)).rgb;
    float3 e  = tex2D(BackBuffer, uv + float2( r.x, 0)).rgb;
    float3 w  = tex2D(BackBuffer, uv + float2(-r.x, 0)).rgb;

    float  lc = Luma709(c);
    float  ln = Luma709(n), ls = Luma709(s), le = Luma709(e), lw = Luma709(w);

    float3 blur = (n + s + e + w + c) / 5.0;

    // Edge mask: lower weight where large gradient (prevents halos)
    float grad = abs(lc - ln) + abs(lc - ls) + abs(lc - le) + abs(lc - lw);
    float edge = saturate(1.0 - grad * 2.0);    // 0 = hard edge, 1 = flat
    float guard = lerp(edge, 1.0, edge_guard);  // protect strong edges

    float3 usm = c + (c - blur) * (strength * guard);
    return saturate(usm);
}

// Deband (iterative neighborhood search + blue-noise dither)
float3 Deband(float2 uv, float threshold, float range, int iterations, float strength)
{
    float2 p = px();
    float3 col = tex2D(BackBuffer, uv).rgb;

    if (iterations <= 0 || strength <= 0.0) return col;

    float3 acc = col;
    float wsum = 1.0;

    [unroll]
    for (int i = 0; i < 3; ++i) // cap unroll at 3; iterations UI clamps 0..3
    {
        if (i >= iterations) break;
        float a = (float)(i + 1);
        float2 off = float2(cos(a * 2.399), sin(a * 2.399)) * (range * a) * p;
        float3 s1 = tex2D(BackBuffer, uv + off).rgb;
        float3 s2 = tex2D(BackBuffer, uv - off).rgb;

        float dl1 = abs(Luma709(s1) - Luma709(col));
        float dl2 = abs(Luma709(s2) - Luma709(col));
        float w1 = saturate(1.0 - dl1 / threshold);
        float w2 = saturate(1.0 - dl2 / threshold);

        acc += s1 * w1 + s2 * w2;
        wsum += w1 + w2;
    }

    float3 smoothed = acc / max(1e-4, wsum);

    // Blue‑noise style dither to hide residual bands
    float n = Hash21(uv * ReShade::ScreenSize);
    float dither = (n - 0.5) / 255.0; // very small
    smoothed += dither;

    return lerp(col, smoothed, strength);
}

// Saturation in perceptual-ish way
float3 ApplySaturation(float3 c, float sat)
{
    float g = Luma709(c);
    return lerp(g.xxx, c, sat);
}

// --------------------------------------------------------------------------------------
// CORE PROCESS
// --------------------------------------------------------------------------------------
struct PSIn { float4 pos : SV_Position; float2 uv : TEXCOORD; };

float3 DriverCore(float2 uv)
{
    float3 col = tex2D(BackBuffer, uv).rgb;

    // Adaptive exposure
    float avgL = AverageLuma();
    float EV   = clamp(log2(DRV_TargetGray / avgL), DRV_MinEV, DRV_MaxEV);
    float exposure = exp2(EV);
    float3 expc = col * exposure;

    // Tone shaping before mapping (protect neon highlights)
    float3 shaped = ShadowHighlight(expc, DRV_ShadowLift, DRV_HighlightRoll);

    // Filmic tonemap
    float3 mapped = (DRV_UseACES ? TonemapACES(shaped) : TonemapHable(shaped));

    // Local micro-contrast
    float3 mc = MicroContrast(mapped, DRV_MicroContrast, DRV_TargetGray);

    // Saturation adjust
    float3 outc = ApplySaturation(mc, DRV_Saturation);

    // Master mix with original
    return lerp(col, outc, DRV_Strength);
}

float4 PS_DriverCore(PSIn i) : SV_Target
{
    return float4(DriverCore(i.uv), 1.0);
}

float4 PS_DriverDeband(PSIn i) : SV_Target
{
    float3 col = Deband(i.uv, DRV_DebandThreshold,
                        DRV_DebandRange * (DRV_PerfMode == 0 ? 0.5 : (DRV_PerfMode == 2 ? 1.25 : 1.0)),
                        DRV_DebandIters, DRV_DebandStrength);
    return float4(col, 1.0);
}

float4 PS_DriverSharpen(PSIn i) : SV_Target
{
    float ss = DRV_SharpStrength * (DRV_PerfMode == 0 ? 0.75 : (DRV_PerfMode == 2 ? 1.15 : 1.0));
    float rr = DRV_SharpRadius;
    float eg = DRV_SharpEdgeGuard;

    float3 col = SharpenBilateral(i.uv, rr, ss, eg);
    return float4(col, 1.0);
}

// --------------------------------------------------------------------------------------
// TECHNIQUE (three passes in fixed order)
// --------------------------------------------------------------------------------------
technique Driver < ui_label = "Driver (Exposure • Filmic • Contrast • Deband • Sharpen)"; >
{
    pass Core
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_DriverCore;
    }
    pass Deband
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_DriverDeband;
    }
    pass Sharpen
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_DriverSharpen;
    }
}
