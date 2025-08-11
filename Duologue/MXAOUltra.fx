// MXAOUltra.fx — Screen-space AO with ultra buffering (ReShade 5.x)
#include "ReShade.fxh"

// Time source provided by ReShade
extern float timer; // seconds since effect start

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

texture DepthTexMXAO : DEPTH;
sampler DepthSampMXAO
{
    Texture = DepthTexMXAO;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Point;
    MagFilter = Point;
    MipFilter = Point;
};

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

// Controls
uniform float MXAO_Strength = 0.55;
uniform float MXAO_RadiusPx = 35.0;
uniform float MXAO_Bias = 0.002;
uniform float MXAO_Thickness = 0.03;
uniform int MXAO_Samples = 12; // 6..24 effective
uniform float MXAO_Falloff = 1.10;
uniform float MXAO_Bilateral = 0.85;
uniform float MXAO_BlurRadius = 2.0;

// AO buffer
texture AOBuffer
{
    Format = R8;
};
sampler AOBufferSamp
{
    Texture = AOBuffer;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
};

static const float2 DIRS[8] =
{
    float2(1, 0), float2(0, 1), float2(-1, 0), float2(0, -1),
    float2(0.7071, 0.7071), float2(-0.7071, 0.7071), float2(-0.7071, -0.7071), float2(0.7071, -0.7071)
};

float2 Rot(float2 v, float a)
{
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float HorizonAO(float2 uv, float2 dir, float radius, float d0)
{
    float2 p = px();
    float occ = 0.0, wsum = 0.0;

    [unroll]
    for (int r = 1; r <= 3; ++r)
    {
        float k = (float) r / 3.0;
        float2 suv = uv + dir * (radius * k) * p;
        float ds = LinearDepth(suv);
        float valid = (ds > 0.0) ? 1.0 : 0.0;

        float allow = d0 - MXAO_Bias + MXAO_Thickness * k;
        float hit = (ds < allow) ? 1.0 : 0.0;

        float w = pow(1.0 - k, MXAO_Falloff);
        occ += hit * w * valid;
        wsum += w * valid;
    }

    return (wsum > 0.0) ? occ / wsum : 0.0;
}

struct PSIn
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

float4 PS_MXAO_Compute(PSIn i) : SV_Target
{
    float d0 = LinearDepth(i.uv);
    if (d0 <= 0.0)
        return 0.0.xxxx;

    // Use ReShade timer for gentle pattern rotation
    const float TAU = 6.2831853;
    float ang = frac(timer * 0.23) * TAU;

    int N = clamp(MXAO_Samples, 6, 24);
    float occ = 0.0, wsum = 0.0;

    [unroll]
    for (int s = 0; s < 24; ++s)
    {
        float active = (s < N) ? 1.0 : 0.0;
        float2 dir = Rot(DIRS[s & 7], ang + (s * 0.2618)); // ~15° steps
        float o = HorizonAO(i.uv, dir, MXAO_RadiusPx, d0);

        occ += o * active;
        wsum += active;
    }

    float ao = (wsum > 0.0) ? saturate(occ / wsum) : 0.0;
    return ao.xxxx;
}

float4 PS_MXAO_Composite(PSIn i) : SV_Target
{
    float2 p = px();
    float3 col = tex2D(BackBuffer, i.uv).rgb;

    // bilateral blur (5x5) guided by luma
    float rr = MXAO_BlurRadius;
    float wsum = 0.0, acc = 0.0;

    [unroll]
    for (int y = -2; y <= 2; ++y)
    {
        [unroll]
        for (int x = -2; x <= 2; ++x)
        {
            float2 off = float2(x, y) * rr * p;
            float a = tex2D(AOBufferSamp, i.uv + off).r;

            float3 c2 = tex2D(BackBuffer, i.uv + off).rgb;
            float dl = abs(Luma(c2) - Luma(col));
            float edge = exp(-dl * 12.0) * MXAO_Bilateral + (1.0 - MXAO_Bilateral);

            float w = edge * exp(-(x * x + y * y) * 0.4);
            acc += a * w;
            wsum += w;
        }
    }

    float ao = (wsum > 0.0) ? acc / wsum : tex2D(AOBufferSamp, i.uv).r;

    // Composite multiplicatively
    float3 shaded = col * (1.0 - ao * MXAO_Strength);
    return float4(shaded, 1.0);
}

technique MXAOUltra
{
    pass Compute
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MXAO_Compute;
        RenderTarget = AOBuffer;
    }
    pass Composite
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MXAO_Composite;
    }
}
