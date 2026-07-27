# Gamma Reference Pattern — Science

The gamma calibration page shows a split pattern:

```
+------------------+------------------+
|   solid grey     |  black & white   |
|   50% (0.5)      |  alternating     |
|                  |  1px vertical    |
|                  |  lines (50%     |
|                  |  duty cycle)     |
+------------------+------------------+
```

The user adjusts the gamma slider until the two halves have the same perceived brightness. At that point the display is calibrated to the target gamma (2.2 by default).

## How it works

1. The LUT transforms each pixel independently before the display renders it.
2. Black pixels (0.0) and white pixels (1.0) are **unchanged** by any reasonable gamma LUT (0^(1/γ) = 0, 1^(1/γ) = 1).  
   → The striped half always outputs an average luminance of **0.5**, regardless of the gamma setting.
3. The grey pixel (0.5) passes through: `LUT(0.5) = 0.5^(1/γ)`, then the display applies its native gamma (≈2.2): `display = (0.5^(1/γ))^2.2 = 0.5^(2.2/γ)`.
4. The two halves match when: `0.5^(2.2/γ) = 0.5` → **γ = 2.2**.

## Why 0.5 and not 0.73?

Earlier versions used 0.73. That was wrong. Tracing the full signal chain:

| Grey value | Match at γ | Result |
|------------|-----------|--------|
| 0.73 | γ = 1.0 | Pattern told user to set gamma to 1.0 |
| **0.50** | **γ = 2.2** | Pattern matches at the correct target |

## Sources

- **Charles Poynton, "Digital Video and HD" (2nd ed.)** — definitive treatment of gamma in imaging systems. Chapter on "Gamma" derives the power-law relationship between pixel code values and displayed luminance.
  - Available at: https://poynton.ca/notes/color/Gamma.html

- **International Colour Consortium (ICC) — "Gamma and Tone Reproduction"** — explains how gamma encoding and the display's electro-optical transfer function (EOTF) interact.
  - https://www.color.org/whitepapers/ICC_White_Paper13_Gamma_and_Tone_Reproduction.pdf

- **Microsoft — "Gamma Correction"** — the Windows colour management documentation covering gamma LUTs, the signal chain from framebuffer to display, and why 0^(1/γ) and 1^(1/γ) are invariant.
  - https://learn.microsoft.com/en-us/windows/win32/direct3darticles/gamma-correct-precision

- **Apple — "Display Calibrator Assistant Algorithm" (Technical Note TN2044, archived)** — describes the split-pattern method used by macOS's Display Calibrator Assistant. The grey value is chosen so that at the target gamma the two halves match, and the user homes in on the correct value by adjusting the slider.
  - Archived at: https://web.archive.org/web/20150906045302/https://developer.apple.com/library/mac/technotes/tn2044/

- **X.Org Foundation — "X Rendering Extension (XRE) — Gamma Ramp API"** — documents XRRSetCrtcGamma and how the per-channel gamma ramp maps 16-bit input values to DAC values.
  - https://www.x.org/releases/X11R7.7/doc/randrproto/randrproto.txt

- **NVIDIA — "Display Gamma"** — explains the hardware gamma correction pipeline and how the GPU LUT interacts with the display's native response.
  - https://developer.nvidia.com/gpugems/gpugems3/part-iv-image-effects/chapter-24-gpu-gamma-and-correction
