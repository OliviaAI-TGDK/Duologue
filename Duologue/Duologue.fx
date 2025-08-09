// Duologue.fx — minimal adaptive exposure + filmic tonemap + micro-contrast
// Plays nice with RT; avoids fake AO/SSR. Order this BEFORE sharpen, AFTER RTGI.

#include "ReShade.fxh"

// Backbuffer sampler (linear space recommended if your chain is linearized)
texture2D BackBufferTex < source = "COLOR"; >;
sampler BackBuffer = sampler_state
{
    Texture = BackBufferTex;
    AddressU = Clamp;
    AddressV = Clamp;
};

// === Controls ===
uniform float DUO_Strength < ui_min = 0.0;ui_max = 1.0; ui_step = 0.01; ui_label = "Master Strength"; > = 1.0;
uniform float DUO_TargetGray < ui_min = 0.05;ui_max = 0.30; ui_step = 0.005; ui_label = "Target Mid-Gray"; > = 0.18;
uniform float DUO_MinEV < ui_min = -4.0;ui_max = 2.0; ui_step = 0.1; ui_label = "EV Min"; > = -1.5;
uniform float DUO_MaxEV < ui_min = -2.0;ui_max = 4.0; ui_step = 0.1; ui_label = "EV Max"; > = 1.5;
uniform float DUO_Contrast < ui_min = -0.5;ui_max = 0.5; ui_step = 0.01; ui_label = "Micro-Contrast"; > = 0.08;
uniform float DUO_ShadowLift < ui_min = -0.2;ui_max = 0.3; ui_step = 0.01; ui_label = "Shadow Lift"; > = 0.04;
uniform float DUO_HighlightRoll < ui_min = 0.0;ui_max = 1.0; ui_step = 0.01; ui_label = "Highlight Roll-off"; > = 0.35;
uniform bool DUO_UseACES < ui_label = "Use ACES Filmic Curve"; > = true;

// Luma helper (BT.709)
float Luma709(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Cheap average luminance using mip sampling (no state persistence needed)
float AvgLuma(float2 texelSize)
{
    // Sample a few low mips to approximate scene average quickly
    float2 uv = ReShade::PosToUV(ReShade::GetTexCoord());
    float a = Luma709(tex2Dlod(BackBuffer, float4(uv, 0, 2)).rgb);
    float b = Luma709(tex2Dlod(BackBuffer, float4(uv, 0, 4)).rgb);
    float c = Luma709(tex2Dlod(BackBuffer, float4(uv, 0, 6)).rgb);
    // Weighted average (bias toward coarser mip to reduce noise)
    return max(1e-4, (a * 0.2 + b * 0.35 + c * 0.45));
}

// Filmic curves
float3 TonemapACES(float3 x)
{
    // Narkowicz ACES approximation
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

float3 TonemapHable(float3 x)
{
    // John Hable’s Uncharted 2 curve (slightly tweaked)
    const float A = 0.22, B = 0.30, C = 0.10, D = 0.20, E = 0.01, F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

// Micro-contrast around mid-gray
float3 MicroContrast(float3 c, float strength, float mid)
{
    float3 d = c - mid;
    return c + d * strength;
}

float3 ShadowHighlightShape(float3 c, float lift, float roll)
{
    // Lift shadows slightly and compress highlights gently
    float3 shadows = pow(saturate(c), 1.0 / (1.0 + max(0.0, lift) * 2.0));
    float3 highlights = 1.0 - exp2(-(1.0 - shadows) * (1.0 + roll * 4.0));
    // Blend back toward original to avoid over-processing
    return lerp(c, saturate(highlights), 0.6) + lift;
}

float3 ProcessPixel(float2 uv)
{
    float3 col = tex2D(BackBuffer, uv).rgb;

    // Adaptive exposure
    float avgL = AvgLuma(1.0 / ReShade::ScreenSize);
    float EV = clamp(log2(DUO_TargetGray / avgL), DUO_MinEV, DUO_MaxEV);
    float exposure = exp2(EV);

    float3 exposed = col * exposure;

    // Highlight roll-off first to avoid clipping neon
    float3 shaped = ShadowHighlightShape(exposed, DUO_ShadowLift, DUO_HighlightRoll);

    // Filmic tonemap
    float3 mapped = DUO_UseACES ? TonemapACES(shaped) : TonemapHable(shaped);

    // Micro-contrast around mid-gray
    float3 outc = MicroContrast(mapped, DUO_Contrast, DUO_TargetGray);

    // Master mix (non-destructive)
    return lerp(col, outc, DUO_Strength);
}

float4 PS_Duologue(float4 pos : SV_Position, float2 uv : TexCoord) : SV_Target
{
    return float4(ProcessPixel(uv), 1.0);
}

technique Duologue <
    ui_label = "Duologue (Adaptive Exposure + Filmic + Micro-Contrast)";
    ui_tooltip = "Place before sharpen and color finishing; after RTGI if you use it.";
>
{
    pass
    {
        VertexShader =
PostProcessVS;
        PixelShader = PS_Duologue;
    }
}
