# Gamma Reference Pattern — Science

The gamma calibration page displays a split reference pattern:

```
+------------------+------------------+
|   solid grey     |  black & white   |
|   50% (0.5)      |  alternating     |
|                  |  1px vertical    |
|                  |  lines (50%      |
|                  |  duty cycle)     |
+------------------+------------------+
```

The user adjusts the gamma slider until the two halves appear to have the same brightness.

Under the standard display model described below, this occurs when the display's **effective system gamma** matches the selected target gamma.

For modern desktop systems (Windows, Linux, and macOS 10.6 Snow Leopard and later), the recommended default target is **γ = 2.2**, which corresponds to the standard sRGB viewing environment. Earlier Macintosh systems (before Mac OS X 10.6) commonly used **γ = 1.8**, but this has been obsolete since 2009 and should only be used for legacy compatibility.

---

## How it works

The derivation assumes:

- the GPU lookup table (LUT) applies a power-law correction:

  ```
  x → x^(1/γ)
  ```

- the display's electro-optical transfer function (EOTF) is approximately:

  ```
  x → x^2.2
  ```

- the alternating black and white stripes are sufficiently fine that the eye (or optical blur) spatially averages them.

Under these assumptions:

### 1. The LUT transforms every pixel independently.

Each framebuffer value is first mapped through the GPU gamma LUT before reaching the display.

### 2. Black and white remain unchanged.

Power-law gamma corrections leave the endpoints unchanged:

```
0^(1/γ) = 0
1^(1/γ) = 1
```

Therefore:

- black still produces minimum luminance;
- white still produces maximum luminance.

The striped region contains equal areas of black and white, so its normalized average luminance is

```
(0 + 1) / 2 = 0.5
```

independent of the LUT gamma.

### 3. The gray patch changes with gamma.

A gray value `g` passes through both stages:

```
LUT output     = g^(1/γ)

Display output = (g^(1/γ))^2.2
               = g^(2.2/γ)
```

### 4. The two halves match when

```
g^(2.2/γ) = 0.5
```

Solving for γ gives

```
γ = 2.2 × log(g) / log(0.5)
```

### 5. Choosing a 50% gray patch

Setting

```
g = 0.5
```

gives

```
γ = 2.2
```

Thus, under the standard power-law model, **50% gray is the mathematically correct reference value for calibrating to a target gamma of 2.2.**

---

## Choosing the target gamma

The correct target depends on the intended color space and workflow.

| Environment | Target gamma |
|-------------|-------------:|
| Windows (sRGB) | ≈2.2 |
| Linux desktop (sRGB) | ≈2.2 |
| macOS 10.6 (Snow Leopard) and later | ≈2.2 |
| Adobe RGB (1998) | 2.2 |
| IEC sRGB | Effective ≈2.2 (piecewise transfer function) |
| Legacy Macintosh (before 2009) | 1.8 |

**Unless compatibility with legacy Macintosh workflows is required, the recommended default target is γ = 2.2.**

---

## Practical considerations

The derivation above is exact only for the idealized power-law model.

Real displays differ in several ways:

- **sRGB is not a pure gamma-2.2 curve.** It uses a piecewise transfer function that is approximately equivalent to γ ≈ 2.2 over most of its range.
- LCD, OLED, mini-LED, and other display technologies have different electro-optical characteristics, especially near black.
- GPU gamma ramps are implemented as sampled lookup tables rather than exact analytical power functions, introducing small quantization errors.
- The perceived match depends on stripe frequency, display resolution, viewing distance, optical blur, and the observer's visual system.

These practical effects may slightly shift the perceptual match point but do not change the mathematical derivation or the conclusion that **50% gray is the correct reference value for a 2.2 calibration target**.

---

# References

1. **Charles Poynton.**
   *Digital Video and HD: Algorithms and Interfaces*, 2nd Edition.
   Morgan Kaufmann, 2012.
   ISBN: 978-0123919267.

2. **International Color Consortium (ICC).**
   *Gamma and Tone Reproduction.*
   https://www.color.org/whitepapers/ICC_White_Paper13_Gamma_and_Tone_Reproduction.pdf

3. **Microsoft.**
   *Windows Color System (WCS).*
   https://learn.microsoft.com/en-us/windows/win32/wcs/windows-color-system

4. **Apple.**
   *Technical Note TN2044 – Display Calibrator Assistant* (archived).
   https://web.archive.org/web/20150906045302/https://developer.apple.com/library/mac/technotes/tn2044/

5. **X.Org Foundation.**
   *xrandr(1) Manual.*
   https://www.x.org/archive/X11R7.5/doc/man/man1/xrandr.1.html

6. **GPU Gems 3.**
   Chapter 24: *The Importance of Being Linear.*
   https://developer.nvidia.com/gpugems/gpugems3/part-iv-image-effects/chapter-24-importance-being-linear
