// Wavespace.fx — Enhanced Wavespace Detail (ReShade 5.x)
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

float2 px()
{
    return 1.0 / ReShade::ScreenSize;
}
static const float3 Lw = float3(0.2126, 0.7152, 0.0722);
float Luma(float3 c)
{
    return dot(c, Lw);
}

uniform float WSP_Strength = 0.35;
uniform float WSP_Radius = 1.75;
uniform float WSP_RingDamp = 0.60;
uniform float WSP_DetailBias = 0.10;

float3 OrientedBand(float2 uv, float2 dir, float radius)
{
    float2 p = px();
    float2 r = normalize(dir) * radius * p;
    float3 c0 = tex2D(BackBuffer, uv).rgb;
    float3 c1 = tex2D(BackBuffer, uv + r).rgb;
    float3 c2 = tex2D(BackBuffer, uv - r).rgb;
    float3 c3 = tex2D(BackBuffer, uv + r * 0.5).rgb;
    float3 c4 = tex2D(BackBuffer, uv - r * 0.5).rgb;
    float3 band = (c1 + c2) * 0.28 + (c3 + c4) * 0.22 - c0 * 1.00;
    return band;
}

struct PSIn
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

float4 PS_Wavespace(PSIn i) : SV_Target
{
    float3 base = tex2D(BackBuffer, i.uv).rgb;
    float3 b0 = OrientedBand(i.uv, float2(1, 0), WSP_Radius);
    float3 b1 = OrientedBand(i.uv, float2(0, 1), WSP_Radius);
    float3 b2 = OrientedBand(i.uv, float2(0.7071, 0.7071), WSP_Radius);
    float3 b3 = OrientedBand(i.uv, float2(-0.7071, 0.7071), WSP_Radius);
    float3 band = (b0 + b1 + b2 + b3) * 0.25;

    float3 guard = 1.0 - smoothstep(0.85, 1.0, base);
    band *= lerp(1.0, 0.6, WSP_RingDamp) * guard;

    float g = Luma(base);
    float mid = 1.0 - abs(g - 0.5) * 2.0;
    band *= (1.0 + WSP_DetailBias * mid);

    float3 outc = base + band * WSP_Strength;
    return float4(saturate(outc), 1.0);
}

technique Wavespace
{
    pass P
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Wavespace;
    }
}
