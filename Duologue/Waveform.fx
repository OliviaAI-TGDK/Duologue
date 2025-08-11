// wafeform.fx — Ray Over-Tracing + RT Gamma Isolation (ReShade 5.x DX10/11/12)
// Screen-space contact-shadow extension with short depth rays,
// plus gamma-aware emissive protection and optional light spread.
// Place AFTER Driver/Vectorium, BEFORE color grading.

#include "ReShade.fxh"

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
}; // required

// ---------- Controls (no UI metadata; safest to compile) ----------
uniform float WAFE_Strength = 0.55; // 0..1 master mix
uniform int WAFE_Steps = 8; // 1..16
uniform float WAFE_RayLengthPx = 40.0; // pixels
uniform float WAFE_Bias = 0.0015; // depth bias
uniform float WAFE_Thickness = 0.020; // thickness allowance
uniform float WAFE_BaseAngleRad = 1.10; // -PI..PI (screen-space)
uniform int WAFE_Rays = 4; // 1..6
uniform float WAFE_WaveMix = 0.60; // 0..1 spread of ray angles
uniform float WAFE_IndirectMix = 0.20; // 0..0.5 indirect lift
uniform float WAFE_FallbackEdge = 0.08; // fallback darken (no depth)

// RT Gamma Isolation (emissive protection + soft reverse spread)
uniform bool WAFE_RTGIso_Enable = true;
uniform float WAFE_RTGIso_Gamma = 1.60; // 0.8..2.4
uniform float WAFE_RTGIso_Protect = 0.65; // 0..1
uniform float WAFE_RTGIso_Spread = 0.15; // 0..0.5
uniform int WAFE_RTGIso_Taps = 2; // 0..3

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

// ReShade provides linearized depth accessor
float LinearDepth(float2 uv)
{
    return ReShade::GetLinearizedDepth(uv);
}

float2 DirFromAngle(float a)
{
    float2 d = float2(cos(a), sin(a));
    return (length(d) > 0.0) ? normalize(d) : float2(1.0, 0.0);
}

// Fallback: edge magnitude without depth
float EdgeMag(float2 uv)
{
    float2 p = px();
    float3 a = tex2D(BackBuffer, uv + float2(-p.x, -p.y)).rgb;
    float3 b = tex2D(BackBuffer, uv + float2(0.0, -p.y)).rgb;
    float3 c = tex2D(BackBuffer, uv + float2(p.x, -p.y)).rgb;
    float3 d = tex2D(BackBuffer, uv + float2(-p.x, 0.0)).rgb;
    float3 f = tex2D(BackBuffer, uv + float2(p.x, 0.0)).rgb;
    float3 g = tex2D(BackBuffer, uv + float2(-p.x, p.y)).rgb;
    float3 h = tex2D(BackBuffer, uv + float2(0.0, p.y)).rgb;
    float3 i = tex2D(BackBuffer, uv + float2(p.x, p.y)).rgb;

    float la = Luma(a), lb = Luma(b), lc = Luma(c);
    float ld = Luma(d), lf = Luma(f);
    float lg = Luma(g), lh = Luma(h), li = Luma(i);

    float gx = (lc + 2.0 * lf + li) - (la + 2.0 * ld + lg);
    float gy = (lg + 2.0 * lh + li) - (la + 2.0 * lb + lc);
    return saturate(sqrt(gx * gx + gy * gy));
}

// Waveform angle offsets (inharmonic coverage)
float AngleOffset(int k)
{
    float fk = (float) k + 1.0;
    float o1 = sin(fk * 1.61803);
    float o2 = cos(fk * 2.41421);
    return (o1 * 0.7 + o2 * 0.3) * 0.6; // ~[-0.6..0.6]
}

// March one ray; fixed loop with weight gating (no dynamic breaks)
float RayOcclusion(float2 uv, float2 dir_px, float rayLenPx, int steps, float bias, float thickness)
{
    float d0 = LinearDepth(uv);
    if (d0 <= 0.0)
        return 0.0;

    int s = clamp(steps, 1, 16);
    float occ = 0.0;
    float wsum = 0.0;

    [unroll]
    for (int i = 0; i < 16; ++i)
    {
        float active = (i < s) ? 1.0 : 0.0;
        float k = (float) (i + 1) / (float) s;

        float2 suv = uv + dir_px * (rayLenPx * k);
        float ds = LinearDepth(suv);
        float valid = (ds > 0.0) ? 1.0 : 0.0;

        float allow = d0 - bias + thickness * k; // allow slightly nearer blockers
        float hit = (ds < allow) ? 1.0 : 0.0;

        float w = (1.0 - k); // near samples weigh more
        occ += hit * w * active * valid;
        wsum += w * active * valid;
    }

    return (wsum > 0.0) ? saturate(occ / wsum) : 0.0;
}

// Multi-ray accumulation
float OcclusionMulti(float2 uv)
{
    int R = clamp(WAFE_Rays, 1, 6);
    float baseA = WAFE_BaseAngleRad;
    float rayLen = max(1.0, WAFE_RayLengthPx);
    float2 p = px();

    float acc = 0.0;
    float wsum = 0.0;

    [unroll]
    for (int k = 0; k < 6; ++k)
    {
        float active = (k < R) ? 1.0 : 0.0;
        float a = baseA + AngleOffset(k) * WAFE_WaveMix;

        float2 dir_px = DirFromAngle(a) * p;
        float o = RayOcclusion(uv, dir_px, rayLen, WAFE_Steps, WAFE_Bias, WAFE_Thickness);

        float w = (k == 0) ? 1.0 : 0.85;
        acc += o * w * active;
        wsum += w * active;
    }

    return (wsum > 0.0) ? saturate(acc / wsum) : 0.0;
}

// ----- RT Gamma Isolation -----
float EmissiveMask(float3 color)
{
    float l = Luma(color);
    float iso = pow(saturate(l), WAFE_RTGIso_Gamma);
    return saturate(iso);
}

float IlluminationSpread(float2 uv, float baseAngle, float spreadGain, int taps)
{
    if (taps <= 0 || spreadGain <= 0.0)
        return 0.0;

    float2 p = px();
    float2 rd = DirFromAngle(baseAngle) * p;
    float acc = 0.0;
    float wsum = 0.0;

    int T = clamp(taps, 0, 3);

    [unroll]
    for (int i = 0; i < 3; ++i)
    {
        float active = (i < T) ? 1.0 : 0.0;
        float k = (float) (i + 1);

        // reverse direction to "carry" light outward
        float2 suv = uv - rd * (k * (WAFE_RayLengthPx * 0.15));
        float3 c = tex2D(BackBuffer, suv).rgb;
        float em = EmissiveMask(c);

        float w = 1.0 / (k + 0.5);
        acc += em * w * active;
        wsum += w * active;
    }

    float spread = (wsum > 0.0) ? (acc / wsum) : 0.0;
    return spread * spreadGain;
}

// ---------- Main ----------
struct PSIn
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

float3 WafeProcess(float2 uv)
{
    float3 col = tex2D(BackBuffer, uv).rgb;

    float d = LinearDepth(uv);
    bool depth_ok = (d > 0.0);

    float shade = 0.0;

    if (depth_ok)
    {
        float occ = OcclusionMulti(uv);

        // base shadow with gentle indirect lift
        float indirect = WAFE_IndirectMix * (1.0 - occ);
        float shadow = saturate(occ * (1.0 - WAFE_IndirectMix) + indirect);

        if (WAFE_RTGIso_Enable)
        {
            float em = EmissiveMask(col);
            shadow *= (1.0 - em * WAFE_RTGIso_Protect);

            float spread = IlluminationSpread(uv, WAFE_BaseAngleRad, WAFE_RTGIso_Spread, WAFE_RTGIso_Taps);
            shadow = saturate(shadow - spread * 0.5);
        }

        shade = shadow;
    }
    else
    {
        shade = saturate(EdgeMag(uv) * WAFE_FallbackEdge);
    }

    float3 shaded = col * (1.0 - shade);
    return lerp(col, shaded, WAFE_Strength);
}

float4 PS_Wafe(PSIn i) : SV_Target
{
    return float4(WafeProcess(i.uv), 1.0);
}

technique Wafeform
{
    pass P
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Wafe;
    }
}
