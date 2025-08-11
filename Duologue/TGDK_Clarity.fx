// TGDK_Clarity.fx — Global Overlay Opacity Controller (ReShade 5.x)
// Exposes TGDK_OverlayOpacity as a shared uniform. Other TGDK shaders read it (extern)
// and scale their own effect mix accordingly. This pass itself is a no-op copy.

#include "ReShade.fxh"

// Global master: 0 = disable all TGDK effects, 1 = full strength
uniform float TGDK_OverlayOpacity <
    ui_label = "TGDK Overlay Opacity";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 1.0;

// Simple copy (no-op) so this effect shows up in ReShade and the slider is available
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

struct PSIn
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

float4 PS_TGDK_Clarity_Copy(PSIn i) : SV_Target
{
    return float4(tex2D(BackBuffer, i.uv).rgb, 1.0);
}

technique TGDK_Clarity
{
    pass P
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_TGDK_Clarity_Copy;
    }
}
