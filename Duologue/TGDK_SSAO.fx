// TGDK_SSAO.fx — Screen-stable SSAO (ReShade 5.x DX10/11/12)
// Jitter-resistant: no time dependence, pixel-grid snapping, golden-ratio spiral.
// Pass 1: AO -> R8 buffer. Pass 2: bilateral blur + composite.

#include "ReShade.fxh"

// ---------------- Buffers ----------------
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

// AO target
texture TGDK_AO
{
	Format = R8;
};
sampler TGDK_AO_S
{
	Texture = TGDK_AO;
	AddressU = Clamp;
	AddressV = Clamp;
	MinFilter = Linear;
	MagFilter = Linear;
	MipFilter = Linear;
};

// ---------------- Controls (no UI metadata to avoid parser quirks) ----------------
uniform float TGDK_Strength = 0.55; // final AO amount
uniform float TGDK_RadiusPx = 28.0; // sampling radius in pixels
uniform float TGDK_Bias = 0.0018; // self-occlusion bias (depth)
uniform float TGDK_Thickness = 0.025; // thickness allowance along ray
uniform int TGDK_Samples = 14; // 6..24 effective
uniform float TGDK_Falloff = 1.05; // distance falloff exponent

uniform float TGDK_BlurRadius = 2.0; // px (bilateral)
uniform float TGDK_Bilateral = 0.82; // 0..1 edge preservation

// Stability controls
uniform float TGDK_SnapPx = 120.0; // snap UVs to this pixel step (0 disables)
uniform float TGDK_PhiMix = 1.0; // 0..1: mix of standard vs golden sequence (1 = full golden)

// ---------------- Helpers ----------------
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

float2 SnapUV(float2 uv, float snapPx)
{
	if (snapPx <= 0.0)
		return uv;
	float2 pix = uv * ReShade::ScreenSize;
	pix = floor(pix / snapPx) * snapPx + snapPx * 0.5;
	return pix / ReShade::ScreenSize;
}

float Hash21(float2 p)
{
    // screen-stable hash (integer pixel coords preferred)
	p = frac(p * float2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return frac(p.x * p.y);
}

// Golden constants
static const float TAU = 6.28318530718; // 2π
static const float PHI = 1.61803398875; // golden ratio
static const float GA = 2.39996322973; // golden angle (~137.5°)

// Mixed spiral direction (blend between standard and golden)
float2 SpiralDirMixed(int i, float a0, float mixPhi)
{
    // base (uniform steps) vs golden (irrational steps)
	float a_std = a0 + (float) i * (TAU / 17.0); // any non-trivial step
	float a_phi = a0 + (float) i * (GA * PHI); // golden-irrational
	float a = lerp(a_std, a_phi, saturate(mixPhi));
	return float2(cos(a), sin(a));
}

// Single-direction occlusion (3 radii) with snapped offsets
float Horizon1(float2 uv, float2 dir, float radius_px, float d0, float snapPx)
{
	float2 p = px();
	float occ = 0.0, wsum = 0.0;

    [unroll]
	for (int r = 1; r <= 3; ++r)
	{
		float k = (float) r / 3.0;
		float2 suv = uv + dir * (radius_px * k) * p;
		suv = SnapUV(suv, snapPx);

		float ds = LinearDepth(suv);
		float valid = (ds > 0.0) ? 1.0 : 0.0;

		float allow = d0 - TGDK_Bias + TGDK_Thickness * k;
		float hit = (ds < allow) ? 1.0 : 0.0;

		float w = pow(1.0 - k, TGDK_Falloff);
		occ += hit * w * valid;
		wsum += w * valid;
	}

	return (wsum > 0.0) ? occ / wsum : 0.0;
}

// ---------------- Pass 1: Compute AO ----------------
struct PSIn
{
	float4 pos : SV_Position;
	float2 uv : TEXCOORD;
};

float4 PS_TGDK_SSAO_Compute(PSIn i) : SV_Target
{
    // Snap the base UV so the ray origins are grid-aligned
	float2 uv0 = SnapUV(i.uv, TGDK_SnapPx);

	float d0 = LinearDepth(uv0);
	if (d0 <= 0.0)
		return 0.0.xxxx;

    // Screen-stable starting phase from integer pixel
	float2 ip = floor(uv0 * ReShade::ScreenSize);
	float angle0 = Hash21(ip) * TAU;

	int N = clamp(TGDK_Samples, 6, 24);
	float occ = 0.0, wsum = 0.0;

    [unroll]
	for (int s = 0; s < 24; ++s)
	{
		float active = (s < N) ? 1.0 : 0.0;

		float2 dir = SpiralDirMixed(s, angle0, TGDK_PhiMix);
		float o = Horizon1(uv0, dir, TGDK_RadiusPx, d0, TGDK_SnapPx);

		occ += o * active;
		wsum += active;
	}

	float ao = (wsum > 0.0) ? saturate(occ / wsum) : 0.0;

    // Gentle clamp to reduce tiny speckle changes frame-to-frame
	ao = smoothstep(0.0, 1.0, ao);

	return ao.xxxx;
}

// ---------------- Pass 2: Bilateral blur + composite ----------------
float4 PS_TGDK_SSAO_Composite(PSIn i) : SV_Target
{
	float2 p = px();
	float3 col = tex2D(BackBuffer, i.uv).rgb;

	float rr = TGDK_BlurRadius;
	float wsum = 0.0, acc = 0.0;

    [unroll]
	for (int y = -2; y <= 2; ++y)
	{
        [unroll]
		for (int x = -2; x <= 2; ++x)
		{
			float2 off = float2(x, y) * rr * p;

            // Sample AO from the buffer (already stable)
			float a = tex2D(TGDK_AO_S, i.uv + off).r;

            // Bilateral weight guided by luma
			float3 c2 = tex2D(BackBuffer, i.uv + off).rgb;
			float dl = abs(Luma(c2) - Luma(col));
			float edge = exp(-dl * 12.0) * TGDK_Bilateral + (1.0 - TGDK_Bilateral);

			float w = edge * exp(-(x * x + y * y) * 0.35);
			acc += a * w;
			wsum += w;
		}
	}

	float ao = (wsum > 0.0) ? acc / wsum : tex2D(TGDK_AO_S, i.uv).r;

    // Composite multiplicatively
	float3 shaded = col * (1.0 - ao * TGDK_Strength);
	return float4(shaded, 1.0);
}

technique TGDK_SSAO_Stable
{
	pass Compute
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_TGDK_SSAO_Compute;
		RenderTarget = TGDK_AO;
	}
	pass Composite
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_TGDK_SSAO_Composite;
	}
}
