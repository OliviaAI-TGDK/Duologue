// Skylight.fx — Adaptive White Balance & Tint (ReShade 5.x DX10/11/12)
// Put this AFTER Driver. Very lightweight. No UI metadata to avoid parser quirks.

#include "ReShade.fxh"

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

// Controls
uniform bool SKY_AutoWB = true; // auto white balance on/off
uniform float SKY_TempKelvin = 6500.0; // manual: 2500..12000 (only used if SKY_AutoWB=false)
uniform float SKY_Tint = 0.0; // -1..1 green-magenta
uniform float SKY_Strength = 1.0; // 0..1 master mix

// Helpers
static const float3 LW = float3(0.2126, 0.7152, 0.0722);
float Luma(float3 c)
{
    return dot(c, LW);
}
float2 px()
{
    return 1.0 / ReShade::ScreenSize;
}

// Approximate RGB gains from color temperature
float3 GainsFromKelvin(float K)
{
    // Clamp to sane range
    K = clamp(K, 2500.0, 12000.0) / 100.0;

    float R, G, B;

    // Red
    R = (K <= 66.0) ? 1.0 : clamp(1.292936186062745f * pow(K - 60.0, -0.1332047592f), 0.0, 1.0);

    // Green
    G = (K <= 66.0)
        ? clamp(0.3900815787690196f * log(K) - 0.6318414437886275f, 0.0, 1.0)
        : clamp(1.129890860895294f * pow(K - 60.0, -0.0755148492f), 0.0, 1.0);

    // Blue
    B = (K >= 66.0) ? 1.0 : (K <= 19.0 ? 0.0 : clamp(0.5432067891101961f * log(K - 10.0) - 1.19625408914f, 0.0, 1.0));

    return float3(R, G, B);
}

// Auto white estimate from coarse mips (chromaticity bias)
float3 AutoWhiteGains(float2 uv)
{
    // Sample coarse mips to avoid noise; derive average color
    float3 a = tex2Dlod(BackBuffer, float4(uv, 0, 3)).rgb;
    float3 b = tex2Dlod(BackBuffer, float4(uv, 0, 5)).rgb;
    float3 c = tex2Dlod(BackBuffer, float4(uv, 0, 6)).rgb;
    float3 avg = max(1e-4, (a * 0.3 + b * 0.4 + c * 0.3));

    // Normalize to luminance: desired neutral gray at same luma
    float l = Luma(avg);
    float3 target = float3(l, l, l);

    // Gains push avg toward neutral
    float3 gains = target / avg;

    // Normalize so max gain = 1 (avoid clipping)
    float gmax = max(gains.r, max(gains.g, gains.b));
    return gains / gmax;
}

// Apply tint in an orthogonal channel (green-magenta axis)
float3 ApplyTint(float3 c, float tintAmount)
{
    // Split into luma + chroma; push G vs (R+B)
    float l = Luma(c);
    float3 chroma = c - l;
    float3 axis = float3(-0.5, 1.0, -0.5); // +green / -magenta
    chroma += axis * tintAmount * 0.08; // gentle
    return saturate(l + chroma);
}

struct PSIn
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

float3 SkylightProcess(float2 uv)
{
    float3 col = tex2D(BackBuffer, uv).rgb;

    // Get gains
    float3 gains = SKY_AutoWB ? AutoWhiteGains(uv) : GainsFromKelvin(SKY_TempKelvin);
    float3 wrk = saturate(col * gains);

    // Optional tint
    wrk = ApplyTint(wrk, SKY_Tint);

    // Master mix (non-destructive)
    return lerp(col, wrk, SKY_Strength);
}

float4 PS_Skylight(PSIn i) : SV_Target
{
    return float4(SkylightProcess(i.uv), 1.0);
}

technique Skylight
{
    pass P
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Skylight;
    }
}
