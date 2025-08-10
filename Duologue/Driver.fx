// Driver.fx — Failsafe compile version (ReShade 5.x DX10/11/12)
// Chain: Exposure -> Filmic -> Micro-Contrast -> Deband -> Sharpen
// Includes Diversity Indexing for adaptive behavior.

#include "ReShade.fxh"

// ---------------- Backbuffer ----------------
texture BackBufferTex : COLOR;
sampler BackBuffer
{
    Texture   = BackBufferTex;
    AddressU  = Clamp;
    AddressV  = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
}; // <- required

// ---------------- Controls (no UI annotations) ----------------
uniform float DRV_Strength        = 1.0;

// Exposure / Tonemap
uniform float DRV_TargetGray      = 0.18;
uniform float DRV_MinEV           = -1.5;
uniform float DRV_MaxEV           =  1.5;
uniform bool  DRV_UseACES         = true;

// Tone shaping
uniform float DRV_ShadowLift      = 0.04;
uniform float DRV_HighlightRoll   = 0.35;
uniform float DRV_MicroContrast   = 0.08;
uniform float DRV_Saturation      = 0.96;

// Deband
uniform float DRV_DebandStrength  = 0.35;
uniform float DRV_DebandThreshold = 0.008;
uniform float DRV_DebandRange     = 16.0;
uniform int   DRV_DebandIters     = 1;

// Sharpen
uniform float DRV_SharpStrength   = 0.27;
uniform float DRV_SharpRadius     = 2.0;
uniform float DRV_SharpEdgeGuard  = 0.35;

// Performance
uniform int   DRV_PerfMode        = 1;   // 0/1/2 low/med/high

// Diversity indexing
uniform bool  DRV_DiversityEnable = true;
uniform float DRV_DiversityWeight = 0.65;
uniform float DRV_DiversityBias   = 0.50;

// ---------------- Helpers ----------------
static const float3 Lw = float3(0.2126, 0.7152, 0.0722);
float  Luma709(float3 c) { return dot(c, Lw); }
float2 px() { return 1.0 / ReShade::ScreenSize; }

float  Hash21(float2 p)
{
    p = frac(p * float2(123.34,345.45));
    p += dot(p,p+34.345);
    return frac(p.x*p.y);
}

// Filmic
float3 TonemapACES(float3 x)
{
    const float a=2.51,b=0.03,c=2.43,d=0.59,e=0.14;
    return saturate((x*(a*x+b))/(x*(c*x+d)+e));
}
float3 TonemapHable(float3 x)
{
    const float A=0.22,B=0.30,C=0.10,D=0.20,E=0.01,F=0.30;
    return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F;
}

// Average luminance via low mips
float AverageLuma(float2 uv)
{
    float a = Luma709(tex2Dlod(BackBuffer, float4(uv,0,2)).rgb);
    float b = Luma709(tex2Dlod(BackBuffer, float4(uv,0,4)).rgb);
    float c = Luma709(tex2Dlod(BackBuffer, float4(uv,0,6)).rgb);
    return max(1e-4, (a*0.2 + b*0.35 + c*0.45));
}

// Diversity Index 0..1 (flat..busy)
float DiversityIndex(float2 uv)
{
    float2 p = px();

    // Coarse variance
    float l0 = Luma709(tex2Dlod(BackBuffer, float4(uv,0,3)).rgb);
    float l1 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2( p.x, 0),0,3)).rgb);
    float l2 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2(-p.x, 0),0,3)).rgb);
    float l3 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2(0,  p.y),0,3)).rgb);
    float l4 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2(0, -p.y),0,3)).rgb);
    float m  = (l0+l1+l2+l3+l4)/5.0;
    float var= ((l0-m)*(l0-m)+(l1-m)*(l1-m)+(l2-m)*(l2-m)+(l3-m)*(l3-m)+(l4-m)*(l4-m))/5.0;

    // Edge energy
    float lc = Luma709(tex2D(BackBuffer, uv).rgb);
    float ln = Luma709(tex2D(BackBuffer, uv + float2(0,-p.y)).rgb);
    float ls = Luma709(tex2D(BackBuffer, uv + float2(0, p.y)).rgb);
    float le = Luma709(tex2D(BackBuffer, uv + float2( p.x,0)).rgb);
    float lw = Luma709(tex2D(BackBuffer, uv + float2(-p.x,0)).rgb);
    float edge = abs(lc-ln)+abs(lc-ls)+abs(lc-le)+abs(lc-lw);

    float v  = saturate(var  * 24.0);
    float e  = saturate(edge * 2.0);
    float di = saturate(0.6*e + 0.4*v);

    return DRV_DiversityEnable ? saturate(lerp(DRV_DiversityBias, di, 1.0)) : DRV_DiversityBias;
}

// Shadow/Highlight shaping
float3 ShadowHighlight(float3 c, float lift, float roll)
{
    float3 s  = pow(saturate(c), 1.0 / (1.0 + max(0.0,lift)*2.0));
    float3 hi = 1.0 - exp2(-(1.0 - s) * (1.0 + roll*4.0));
    return lerp(c, saturate(hi), 0.6) + lift;
}

// Micro-contrast
float3 MicroContrast(float3 c, float strength, float mid) { return c + (c - mid) * strength; }

// Edge-aware sharpen
float3 SharpenBilateral(float2 uv, float radius, float strength, float edge_guard)
{
    float2 p = px(), r = p * radius;
    float3 c = tex2D(BackBuffer, uv).rgb;
    float3 n = tex2D(BackBuffer, uv + float2(0,-r.y)).rgb;
    float3 s = tex2D(BackBuffer, uv + float2(0, r.y)).rgb;
    float3 e = tex2D(BackBuffer, uv + float2( r.x,0)).rgb;
    float3 w = tex2D(BackBuffer, uv + float2(-r.x,0)).rgb;

    float lc = Luma709(c), ln=Luma709(n), ls=Luma709(s), le=Luma709(e), lw=Luma709(w);
    float3 blur = (n+s+e+w+c)/5.0;

    float grad  = abs(lc-ln)+abs(lc-ls)+abs(lc-le)+abs(lc-lw);
    float edge  = saturate(1.0 - grad * 2.0);   // 0 hard edge / 1 flat
    float guard = lerp(edge, 1.0, edge_guard);  // protect edges

    float3 usm = c + (c - blur) * (strength * guard);
    return saturate(usm);
}

// Deband + blue-noise
float3 Deband(float2 uv, float threshold, float range, int iterations, float strength)
{
    if (iterations <= 0 || strength <= 0.0) return tex2D(BackBuffer, uv).rgb;

    float2 p = px();
    float3 base = tex2D(BackBuffer, uv).rgb, acc = base;
    float wsum = 1.0;

    [unroll] for (int i=0;i<3;++i)
    {
        if (i>=iterations) break;
        float a = (float)(i+1);
        float2 off = float2(cos(a*2.399), sin(a*2.399)) * (range*a) * p;
        float3 s1 = tex2D(BackBuffer, uv + off).rgb;
        float3 s2 = tex2D(BackBuffer, uv - off).rgb;

        float dl1 = abs(Luma709(s1)-Luma709(base));
        float dl2 = abs(Luma709(s2)-Luma709(base));
        float w1 = saturate(1.0 - dl1/threshold);
        float w2 = saturate(1.0 - dl2/threshold);

        acc += s1*w1 + s2*w2; wsum += w1 + w2;
    }

    float3 sm = acc / max(1e-4, wsum);
    float n = Hash21(uv * ReShade::ScreenSize);
    sm += ((n-0.5)/255.0); // tiny dither

    return lerp(base, sm, strength);
}

// Perceptual-ish saturation
float3 ApplySaturation(float3 c, float sat) { float g = Luma709(c); return lerp(g.xxx, c, sat); }

// ---------------- Core & Pass Shaders ----------------
struct PSIn { float4 pos : SV_Position; float2 uv : TEXCOORD; };

float3 DriverCore(float2 uv)
{
    float3 col = tex2D(BackBuffer, uv).rgb;

    // Exposure
    float avgL = AverageLuma(uv);
    float EV   = clamp(log2(DRV_TargetGray / avgL), DRV_MinEV, DRV_MaxEV);
    float exposure = exp2(EV);
    float3 expc = col * exposure;

    // Diversity adapt
    float di = DiversityIndex(uv);
    float w  = DRV_DiversityWeight;

    float adaptDetail = lerp(1.0, 1.0 + 0.6*w, (1.0 - di));

    // Tone & map
    float3 shaped = ShadowHighlight(expc, DRV_ShadowLift, DRV_HighlightRoll);
    float3 mapped = DRV_UseACES ? TonemapACES(shaped) : TonemapHable(shaped);
    float3 mc     = MicroContrast(mapped, DRV_MicroContrast * adaptDetail, DRV_TargetGray);
    float3 out    = ApplySaturation(mc, DRV_Saturation);

    return lerp(col, out, DRV_Strength);
}

float4 PS_DriverCore(PSIn i) : SV_Target { return float4(DriverCore(i.uv), 1.0); }

float4 PS_DriverDeband(PSIn i) : SV_Target
{
    float di = DiversityIndex(i.uv);
    float w  = DRV_DiversityWeight;
    float adaptDeband = lerp(1.0, 1.0 + 0.35*w, (1.0 - di));

    float rng = DRV_DebandRange * (DRV_PerfMode==0 ? 0.5 : (DRV_PerfMode==2 ? 1.25 : 1.0));
    float str = DRV_DebandStrength * adaptDeband;

    float3 c = Deband(i.uv, DRV_DebandThreshold, rng, DRV_DebandIters, str);
    return float4(c, 1.0);
}

float4 PS_DriverSharpen(PSIn i) : SV_Target
{
    float di = DiversityIndex(i.uv);
    float w  = DRV_DiversityWeight;
    float adaptDetail = lerp(1.0, 1.0 + 0.6*w, (1.0 - di));
    float adaptEdgeG  = lerp(0.0, 0.30*w, di);

    float ss = DRV_SharpStrength * adaptDetail * (DRV_PerfMode==0 ? 0.75 : (DRV_PerfMode==2 ? 1.15 : 1.0));
    float eg = saturate(DRV_SharpEdgeGuard + adaptEdgeG);

    float3 c = SharpenBilateral(i.uv, DRV_SharpRadius, ss, eg);
    return float4(c, 1.0);
}

// ---------------- Technique ----------------
technique Driver
{
    pass Core    { VertexShader = PostProcessVS; PixelShader = PS_DriverCore; }
    pass Deband  { VertexShader = PostProcessVS; PixelShader = PS_DriverDeband; }
    pass Sharpen { VertexShader = PostProcessVS; PixelShader = PS_DriverSharpen; }
}
