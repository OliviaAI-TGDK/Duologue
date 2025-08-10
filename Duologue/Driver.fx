// Driver.fx — ReShade 5.x (DX10/11/12)
// One-technique chain with Adaptive Exposure → Filmic → Micro-Contrast → Deband → Sharpen
// Includes "Diversity Indexing" (variance + edge energy) to auto-tune strength safely.
// Place AFTER RTGI (if used). Turn OFF in-game sharpening/film grain/CA.

#include "ReShade.fxh"

// ------------------------------------------------------------
// Backbuffer
// ------------------------------------------------------------
texture BackBufferTex : COLOR;
sampler BackBuffer { Texture = BackBufferTex; AddressU = Clamp; AddressV = Clamp; MinFilter = Linear; MagFilter = Linear; MipFilter = Linear; }

// ------------------------------------------------------------
// UI / Controls
// ------------------------------------------------------------
uniform float DRV_Strength       < ui_label="Master Strength", ui_min=0.0, ui_max=1.0, ui_step=0.01 > = 1.0;

// Exposure / Tonemap
uniform float DRV_TargetGray     < ui_label="Target Mid-Gray", ui_min=0.05, ui_max=0.30, ui_step=0.005 > = 0.18;
uniform float DRV_MinEV          < ui_label="EV Min",          ui_min=-4.0, ui_max=2.0,  ui_step=0.1 > = -1.5;
uniform float DRV_MaxEV          < ui_label="EV Max",          ui_min=-2.0, ui_max=4.0,  ui_step=0.1 > =  1.5;
uniform bool  DRV_UseACES        < ui_label="Use ACES (else Hable)" > = true;

// Tone shaping
uniform float DRV_ShadowLift     < ui_label="Shadow Lift",     ui_min=-0.20, ui_max=0.30, ui_step=0.01 > = 0.04;
uniform float DRV_HighlightRoll  < ui_label="Highlight Roll-off", ui_min=0.0, ui_max=1.0, ui_step=0.01 > = 0.35;
uniform float DRV_MicroContrast  < ui_label="Micro-Contrast",  ui_min=-0.40, ui_max=0.40, ui_step=0.01 > = 0.08;
uniform float DRV_Saturation     < ui_label="Saturation",      ui_min=0.70, ui_max=1.20, ui_step=0.01 > = 0.96;

// Deband
uniform float DRV_DebandStrength < ui_label="Deband Strength", ui_min=0.0, ui_max=1.0, ui_step=0.01 > = 0.35;
uniform float DRV_DebandThreshold< ui_label="Deband Threshold",ui_min=0.001, ui_max=0.02, ui_step=0.001 > = 0.008;
uniform float DRV_DebandRange    < ui_label="Deband Range",    ui_min=2.0, ui_max=32.0, ui_step=1.0 > = 16.0;
uniform int   DRV_DebandIters    < ui_label="Deband Iterations", ui_min=0, ui_max=3 > = 1;

// Sharpen (edge‑aware)
uniform float DRV_SharpStrength  < ui_label="Sharpen Strength",ui_min=0.0, ui_max=1.0, ui_step=0.01 > = 0.27;
uniform float DRV_SharpRadius    < ui_label="Sharpen Radius (px)", ui_min=0.5, ui_max=3.0, ui_step=0.1 > = 2.0;
uniform float DRV_SharpEdgeGuard < ui_label="Edge Guard",      ui_min=0.0, ui_max=1.0, ui_step=0.01 > = 0.35;

// Performance mode
uniform int   DRV_PerfMode       < ui_label="Perf Mode (0 Low / 1 Med / 2 High)", ui_min=0, ui_max=2 > = 1;

// Diversity Indexing
uniform bool  DRV_DiversityEnable< ui_label="Enable Diversity Indexing" > = true;
uniform float DRV_DiversityWeight< ui_label="Diversity Weight", ui_min=0.0, ui_max=1.0, ui_step=0.01 > = 0.65;
uniform float DRV_DiversityBias  < ui_label="Diversity Bias (0 flat..1 busy)", ui_min=0.0, ui_max=1.0, ui_step=0.01 > = 0.50;

// ------------------------------------------------------------
// Helpers
// ------------------------------------------------------------
float3 Lw = float3(0.2126, 0.7152, 0.0722);
float  Luma709(float3 c) { return dot(c, Lw); }
float2 px() { return 1.0 / ReShade::ScreenSize; }
float  Hash21(float2 p) { p = frac(p * float2(123.34,345.45)); p += dot(p,p+34.345); return frac(p.x*p.y); }

// Filmic
float3 TonemapACES(float3 x){ const float a=2.51,b=0.03,c=2.43,d=0.59,e=0.14; return saturate((x*(a*x+b))/(x*(c*x+d)+e)); }
float3 TonemapHable(float3 x){ const float A=0.22,B=0.30,C=0.10,D=0.20,E=0.01,F=0.30; return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F; }

// Average luminance via low mips
float AverageLuma(float2 uv)
{
    float a = Luma709(tex2Dlod(BackBuffer, float4(uv,0,2)).rgb);
    float b = Luma709(tex2Dlod(BackBuffer, float4(uv,0,4)).rgb);
    float c = Luma709(tex2Dlod(BackBuffer, float4(uv,0,6)).rgb);
    return max(1e-4, (a*0.2 + b*0.35 + c*0.45));
}

// Diversity Index: 0 = flat, 1 = very detailed
float DiversityIndex(float2 uv)
{
    float2 p = px();

    // Local variance (at coarse mip to avoid noise)
    float l0 = Luma709(tex2Dlod(BackBuffer, float4(uv,0,3)).rgb);
    float l1 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2( p.x, 0),0,3)).rgb);
    float l2 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2(-p.x, 0),0,3)).rgb);
    float l3 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2(0,  p.y),0,3)).rgb);
    float l4 = Luma709(tex2Dlod(BackBuffer, float4(uv + float2(0, -p.y),0,3)).rgb);

    float m  = (l0+l1+l2+l3+l4)/5.0;
    float var= ((l0-m)*(l0-m)+(l1-m)*(l1-m)+(l2-m)*(l2-m)+(l3-m)*(l3-m)+(l4-m)*(l4-m))/5.0;

    // Edge energy (Sobel-lite on full-res)
    float lc = Luma709(tex2D(BackBuffer, uv).rgb);
    float ln = Luma709(tex2D(BackBuffer, uv + float2(0,-p.y)).rgb);
    float ls = Luma709(tex2D(BackBuffer, uv + float2(0, p.y)).rgb);
    float le = Luma709(tex2D(BackBuffer, uv + float2( p.x,0)).rgb);
    float lw = Luma709(tex2D(BackBuffer, uv + float2(-p.x,0)).rgb);
    float edge = abs(lc-ln)+abs(lc-ls)+abs(lc-le)+abs(lc-lw);

    // Normalize & combine
    float v  = saturate(var * 24.0);   // scale to ~0..1
    float e  = saturate(edge * 2.0);   // scale to ~0..1
    float di = saturate(0.6*e + 0.4*v);

    // Optional bias blend
    return saturate(lerp(DRV_DiversityBias, di, DRV_DiversityEnable ? 1.0 : 0.0));
}

// Shadow/Highlight shaping
float3 ShadowHighlight(float3 c, float lift, float roll)
{
    float3 s  = pow(saturate(c), 1.0 / (1.0 + max(0.0,lift)*2.0));
    float3 hi = 1.0 - exp2(-(1.0 - s) * (1.0 + roll*4.0));
    return lerp(c, saturate(hi), 0.6) + lift;
}

// Micro-contrast (around mid-gray)
float3 MicroContrast(float3 c, float strength, float mid)
{
    return c + (c - mid) * strength;
}

// Edge-aware sharpen (bilateral-guarded USM)
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
    float edge  = saturate(1.0 - grad * 2.0);      // 0 hard edge / 1 flat
    float guard = lerp(edge, 1.0, edge_guard);     // protect edges

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
    float n = Hash21(uv * ReShade::ScreenSize); // tiny dither
    sm += ((n-0.5)/255.0);

    return lerp(base, sm, strength);
}

// Perceptual-ish saturation
float3 ApplySaturation(float3 c, float sat) { float g = Luma709(c); return lerp(g.xxx, c, sat); }

// ------------------------------------------------------------
// Core process
// ------------------------------------------------------------
struct PSIn { float4 pos : SV_Position; float2 uv : TEXCOORD; };

float3 DriverCore(float2 uv)
{
    float3 col = tex2D(BackBuffer, uv).rgb;

    // Adaptive exposure (global-ish)
    float avgL = AverageLuma(uv);
    float EV   = clamp(log2(DRV_TargetGray / avgL), DRV_MinEV, DRV_MaxEV);
    float exposure = exp2(EV);
    float3 expc = col * exposure;

    // Diversity-driven adaptives
    float di = DiversityIndex(uv);          // 0 flat .. 1 busy
    float w  = DRV_DiversityWeight;         // how strongly to adapt

    // More help in flat scenes, gentler in busy areas
    float adaptDetail  = lerp(1.0, 1.0 + 0.6*w, (1.0 - di)); // contrast/sharpen boost
    float adaptDeband  = lerp(1.0, 1.0 + 0.35*w, (1.0 - di));
    float adaptEdgeG   = lerp(0.0, 0.30*w, di);              // protect edges more when busy

    // Tone shaping before mapping
    float3 shaped = ShadowHighlight(expc, DRV_ShadowLift, DRV_HighlightRoll);

    // Filmic
    float3 mapped = DRV_UseACES ? TonemapACES(shaped) : TonemapHable(shaped);

    // Micro-contrast & saturation
    float3 mc  = MicroContrast(mapped, DRV_MicroContrast * adaptDetail, DRV_TargetGray);
    float3 out = ApplySaturation(mc, DRV_Saturation);

    // Stash adaptive factors in globals for later passes
    ReShade::SetUniform("g_adaptDeband", adaptDeband);
    ReShade::SetUniform("g_adaptEdgeBoost", adaptEdgeG);
    ReShade::SetUniform("g_adaptSharpen", adaptDetail);

    // Mix
    return lerp(col, out, DRV_Strength);
}

// Lightweight uniform “mailbox” between passes
uniform float g_adaptDeband     < source = "unknown"; > = 1.0;
uniform float g_adaptEdgeBoost  < source = "unknown"; > = 0.0;
uniform float g_adaptSharpen    < source = "unknown"; > = 1.0;

// ------------------------------------------------------------
// Pass shaders
// ------------------------------------------------------------
float4 PS_DriverCore(PSIn i) : SV_Target { return float4(DriverCore(i.uv), 1.0); }

float4 PS_DriverDeband(PSIn i) : SV_Target
{
    float rng = DRV_DebandRange * (DRV_PerfMode==0 ? 0.5 : (DRV_PerfMode==2 ? 1.25 : 1.0));
    float str = DRV_DebandStrength * g_adaptDeband;
    float3 c = Deband(i.uv, DRV_DebandThreshold, rng, DRV_DebandIters, str);
    return float4(c,1.0);
}

float4 PS_DriverSharpen(PSIn i) : SV_Target
{
    float ss = DRV_SharpStrength * g_adaptSharpen * (DRV_PerfMode==0 ? 0.75 : (DRV_PerfMode==2 ? 1.15 : 1.0));
    float eg = saturate(DRV_SharpEdgeGuard + g_adaptEdgeBoost);
    float3 c = SharpenBilateral(i.uv, DRV_SharpRadius, ss, eg);
    return float4(c,1.0);
}

// ------------------------------------------------------------
// Technique
// ------------------------------------------------------------
technique Driver < ui_label="Driver (Exposure • Filmic • Contrast • Deband • Sharpen • Diversity)"; >
{
    pass Core    { VertexShader = PostProcessVS; PixelShader = PS_DriverCore; }
    pass Deband  { VertexShader = PostProcessVS; PixelShader = PS_DriverDeband; }
    pass Sharpen { VertexShader = PostProcessVS; PixelShader = PS_DriverSharpen; }
}
