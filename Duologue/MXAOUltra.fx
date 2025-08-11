// MXAOUltra.fx — Screen-space AO with ultra buffering (ReShade 5.x)
// Pass 1: AO compute to R8 target; Pass 2: bilateral blur & composite.
// Put AFTER Wafeform, BEFORE color grade.

#include "ReShade.fxh"

// Backbuffer + depth
texture BackBufferTex : COLOR;
sampler BackBuffer { Texture = BackBufferTex; AddressU = Clamp; AddressV = Clamp; MinFilter = Linear; MagFilter = Linear; MipFilter = Linear; }

texture DepthTex : DEPTH;
sampler DepthSamp { Texture = DepthTex; AddressU = Clamp; AddressV = Clamp; MinFilter = Point; MagFilter = Point; MipFilter = Point; }

float2 px() { return 1.0 / ReShade::ScreenSize; }
float  LinearDepth(float2 uv) { return ReShade::GetLinearizedDepth(uv); }
static const float3 Lw = float3(0.2126,0.7152,0.0722);
float  Luma(float3 c){ return dot(c,Lw); }

// Controls
uniform float MXAO_Strength   = 0.55;   // final mix
uniform float MXAO_RadiusPx   = 35.0;   // world-ish in pixels
uniform float MXAO_Bias       = 0.002;  // self-occlusion bias
uniform float MXAO_Thickness  = 0.03;   // tolerance
uniform int   MXAO_Samples    = 12;     // 6..24
uniform float MXAO_Falloff    = 1.10;   // distance falloff
uniform float MXAO_Bilateral  = 0.85;   // blur preserve edges 0..1
uniform float MXAO_BlurRadius = 2.0;    // px

// AO buffer
texture AOBuffer { Format = R8; };
sampler AOBufferSamp { Texture = AOBuffer; AddressU = Clamp; AddressV = Clamp; MinFilter = Linear; MagFilter = Linear; MipFilter = Linear; }

// Directions (8 base, mirrored for more)
static const float2 DIRS[8] = {
    float2(1,0), float2(0,1), float2(-1,0), float2(0,-1),
    float2(0.7071,0.7071), float2(-0.7071,0.7071), float2(-0.7071,-0.7071), float2(0.7071,-0.7071)
};

float2 Rot(float2 v, float ang){ float c=cos(ang), s=sin(ang); return float2(c*v.x - s*v.y, s*v.x + c*v.y); }

float HorizonAO(float2 uv, float2 dir, float radius, float d0)
{
    // sample 3 radii along dir
    float2 p = px();
    float occ = 0.0, wsum = 0.0;

    [unroll] for(int r=1;r<=3;++r){
        float k = (float)r/3.0;
        float2 suv = uv + dir * (radius*k) * p;
        float ds = LinearDepth(suv);
        float valid = (ds > 0.0) ? 1.0 : 0.0;

        float allow = d0 - MXAO_Bias + MXAO_Thickness * k;
        float hit = (ds < allow) ? 1.0 : 0.0;

        float w = pow(1.0 - k, MXAO_Falloff);
        occ  += hit * w * valid;
        wsum += w   * valid;
    }
    return (wsum>0.0)? occ/wsum : 0.0;
}

// ---------- PASS 1: compute AO to AOBuffer ----------
struct PSIn { float4 pos:SV_Position; float2 uv:TEXCOORD; };

float4 PS_MXAO_Compute(PSIn i) : SV_Target
{
    float d0 = LinearDepth(i.uv);
    if (d0<=0.0) return 0.0.xxxx;

    float ang = frac(ReShade::Time * 0.23) * 6.28318; // tiny rotation for patterning
    int   N   = clamp(MXAO_Samples, 6, 24);

    float occ = 0.0, wsum = 0.0;
    [unroll] for(int s=0; s<24; ++s)
    {
        float active = (s < N) ? 1.0 : 0.0;
        float2 dir = DIRS[s & 7];
        dir = Rot(dir, ang + (s * 0.2618)); // spread
        float o = HorizonAO(i.uv, dir, MXAO_RadiusPx, d0);
        float w = 1.0;
        occ  += o * w * active;
        wsum += w * active;
    }
    float ao = (wsum>0.0)? saturate(occ/wsum) : 0.0;
    return ao.xxxx; // store in AOBuffer
}

// ---------- PASS 2: bilateral blur + composite ----------
float4 PS_MXAO_Composite(PSIn i) : SV_Target
{
    float2 p = px();
    float3 col = tex2D(BackBuffer, i.uv).rgb;

    // bilateral blur AO
    float rr = MXAO_BlurRadius;
    float wsum = 0.0, acc = 0.0;
    [unroll] for(int y=-2;y<=2;++y)
    {
        [unroll] for(int x=-2;x<=2;++x)
        {
            float2 off = float2(x,y) * rr * p;
            float  a   = tex2D(AOBufferSamp, i.uv + off).r;

            // edge preservation using color distance
            float3 c2  = tex2D(BackBuffer, i.uv + off).rgb;
            float   dl = abs(Luma(c2) - Luma(col));
            float   edge = exp(-dl * 12.0) * MXAO_Bilateral + (1.0 - MXAO_Bilateral);

            float   w = edge * exp(-(x*x + y*y) * 0.4);
            acc  += a * w;
            wsum += w;
        }
    }
    float ao = (wsum>0.0)? acc/wsum : tex2D(AOBufferSamp, i.uv).r;

    // composite multiplicatively
    float3 shaded = col * (1.0 - ao * MXAO_Strength);
    return float4(shaded,1.0);
}

technique MXAOUltra
{
    pass Compute   { VertexShader = PostProcessVS; PixelShader = PS_MXAO_Compute; RenderTarget = AOBuffer; }
    pass Composite { VertexShader = PostProcessVS; PixelShader = PS_MXAO_Composite; }
}
