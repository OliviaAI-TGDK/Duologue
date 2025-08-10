# Duologue for Cyberpunk 2077 (ReShade)

**Duologue** is a single lightweight ReShade shader designed to work **with** Cyberpunk 2077's native ray tracing rather than replacing it.  
It combines **adaptive exposure**, **filmic tonemapping**, **micro-contrast shaping**, and **shadow/highlight control** into one pass, leaving other shaders for final polish.

---

## 📦 Features
- Adaptive exposure targeting mid-gray
- ACES or Hable filmic curve option
- Micro-contrast for added depth without over-sharpening
- Shadow lift and highlight roll-off to preserve detail in RT reflections
- Designed to slot between RTGI and finishing filters

---

## 📂 Installation
1. Install [ReShade](https://reshade.me) for Cyberpunk 2077 (DirectX 10/11/12 mode).
2. Copy `Duologue.fx` into:
Cyberpunk 2077/reshade-shaders/Shaders/
3. (Optional) Copy `Duologue.ini` preset into:
Cyberpunk 2077/bin/x64/
4. Launch the game, open ReShade (default **Home** key), and select the `Duologue.ini` preset.

---

## ⚙ Recommended Technique Order
**For best results with RT and other shaders:**
1. `qUINT_RTGI` *(if purchased from [Marty McFly Patreon](https://www.patreon.com/mcflypg))*  
2. `Duologue`  
3. `qUINT_Lightroom`  
4. `PD80_04_Contrast_Brightness_Saturation`  
5. `Technicolor2`  
6. `Deband`  
7. `Clarity`

---

## 🎛 Controls
- **DUO_Strength** – Overall effect strength
- **DUO_TargetGray** – Target mid-gray luminance
- **DUO_MinEV / DUO_MaxEV** – Exposure range limits
- **DUO_Contrast** – Micro-contrast amount
- **DUO_ShadowLift** – Lifts shadow detail
- **DUO_HighlightRoll** – Rolls off highlight clipping
- **DUO_UseACES** – Toggle ACES or Hable filmic curve

---

## 📌 Tips
- Keep **RTGI** strength moderate to avoid double-lighting (game already has RTGI).
- Use **Lightroom** for fine tint/temperature adjustments after Duologue.
- Keep sharpening subtle; Duologue already boosts local contrast.

---

## 📜 License
This shader is provided for personal use. Do not redistribute without credit.

---

**Author:** Adapted for Cyberpunk 2077 visual realism with RT integration.  
**Version:** 0.1  
