# Eyes adjustment controls: approved Wide slider

2026-10-24 (America/Toronto), `ui-a`. The user requested commit/push of the reviewed Wide slider after the reset-spacing, dot-revert and endpoint-wording revisions. The approved Eyes presentation is implemented in `ContentView.swift`; Labeled slider remains an alternative. Read `DESIGN.md` for implementation boundaries and native validation requirements.

Private preview: `design/mockups/yumiro-eyes-controls-local.html`. The inline copy is a regular file at `C:/Users/Jason/.codex/visualizations/2026/10/24/01a16cbd-75e4-7df3-aa0a-c421b001d992/yumiro-eyes-controls-local.html`. Both contain the existing supplied photo; do not commit or publish them. The editor chrome, approved Stacked rails, canvas proportions, photograph, illustrative face guides and main Focus rail are reused from the approved navigation mockup.

## Alternatives

- **Labeled slider:** selected adjustment name remains beside the slider, followed by the approved value badge and reset control. Familiar, explicit labeling, with a shorter slider.
- **Wide slider (approved and implemented):** the selected option in the approved rail identifies the adjustment; the duplicate name beside the slider is omitted. This makes the continuous slider substantially wider without changing the intended default-size panel budget. Range, value, reset and gesture behavior remain the same.

Both reuse the existing native slider appearance, a 44 x 32 pt monospaced 15 pt medium value badge with 10 pt corners, and the approved neutral 44 x 44 pt reset target with 14 pt corners. Edited values are signed and accented; neutral 0 uses a neutral surface. A persistent stem below the track identifies its 50% midpoint even when the neutral thumb covers the track. Plain direction words now sit directly below the left and right ends of the slider; the separate “Eye length · 0 neutral / − Shorter · + Longer” helper block has been removed. Width shows **Shorter** on the left and **Longer** on the right; the same endpoint pattern uses each option's existing directions. Neutral information remains in the midpoint tooltip and slider accessibility value. No physical units, numeric field, stepper, quantization, new effect or new canvas gesture is proposed.

The revised default-size content budget stays 184 pt: two approved 44 pt navigation rows, a 44 pt control row, a 4 pt gap and a 28 pt helper/Reset all row, plus Eyes-only 8 pt top / 12 pt bottom padding. The 4 pt gap separates selected Reset from Reset all without changing canvas size. Guidance uses the existing 13 pt footnote hierarchy. These are browser dimensions; native Dynamic Type and layout still require validation before treating the geometry as final.

## Five existing controls

| Existing option | Model property | Guidance | Negative / positive |
|---|---|---|---|
| Size | `eyes` | Eye size | Smaller / Larger |
| Width | `eyeWidth` | Eye length, corner to corner | Shorter / Longer |
| Height | `eyeHeight` | Eye opening | Less open / More open |
| Tilt | `eyeTilt` | Outer corners | Down / Up |
| Distance | `eyeDistance` | Eye spacing | Closer / Farther |

All five remain continuous **−1...1**, neutral **0**, displayed as rounded signed **−100...+100** (unitless). Preserve `ValueSlider`'s existing center catch, `abs(v) < 0.03`, for these two-way ranges, plus its zero haptic. Selected Reset retains its existing disabled check `abs(value) < 0.001`, not a check on the rounded badge. Reset returns only the selected parameter to zero. Existing Reset all retains its scope over all Face sliders for the selected face, including other categories; it must not become an Eyes-only reset.

The category and option order, selected/edited styling, 6 pt dots, 44 pt targets and navigation memory remain the approved Stacked rails. Original dot behavior is retained: dots appear only for edited settings and take no layout space at neutral. Other categories are shown only for context in this Eyes mockup. They are not redesigned or simulated as editable.

## Availability and state preservation

- **Default:** all five values zero; current selection stays highlighted, midpoint visible, reset unavailable.
- **Adjusted:** Size +18, Width −12, Height +24, Tilt −16, Distance +10; signed readout and independent edit dots remain visible. Sample values are for control review only; the photograph is fixed.
- **Face mapping unavailable:** Width starts selected with −12 retained. Width, Height, Tilt and Distance require the selected face's mesh and their slider/reset are unavailable when it is missing. Their option buttons remain selectable, as in the current app. Size uses the existing Vision landmark fallback and remains available. Do not add a blanket no-face restriction.
- **Processing:** the existing editor-wide busy lock disables navigation, slider and reset actions while keeping values, selection and edit dots visible. The preview adds concise processing guidance without proposing a new processing behavior.

Per-face storage remains `sliderShape(keeping:)` / `storeShape()` / `showSliders(_:)`. Do not make any Eyes parameter global or add a face picker. Preserve the existing tap-on-canvas face switching, guide geometry and caption for multiple faces. Future guidance should append/preserve the existing “Face N of M · tap another face to switch” context when multiple faces exist; the mockup uses the existing single-person photo.

Each slider drag must continue to bracket the existing `model.sliderEditing(true/false)` callbacks and remain one undo step. Selected Reset and Reset all retain their current undo/render callbacks. These proposals do not modify the model, shader or rendering pipeline.

## Mobbin references

- [VSCO](https://mobbin.com/screens/df9557ce-8461-4c68-a07f-823919f788ca): signed numeric strength close to the adjustment; informs associating the readout with the slider.
- [Halide Mark III](https://mobbin.com/screens/094dc15f-2903-401e-9984-d97633308ae4): signed exposure and a reference on the scale; informs the zero landmark. Its ruler/histogram are not proposed for Yumiro.
- [Shopee](https://mobbin.com/screens/e0a34c4b-29b8-4bdf-aced-9fb455d9aa09): an active beauty tool, numeric strength and separate Reset. Informs keeping selection, strength and reset distinct.

No reference app assets were imported. Native effect ranges, hints, mesh availability, per-face storage and undo grouping were inspected in `ContentView.swift`, `Adjustments.swift` and `EditorModel.swift`. Browser verification should cover both layouts, light/dark, default/adjusted/unavailable states, every option's guidance, signed endpoints, zero catch, selected Reset, narrow widths and no editor/canvas geometry change. Native build, device layout and XCTest are outside this design-only review on Windows.

## Browser validation completed

- Both layouts render with the approved editor chrome and navigation. At a 390 px phone width, the labeled slider track measured 172 px and the wide track 252 px; these are browser measurements, not native device measurements.
- Default, adjusted, missing-map and processing presentations were checked in light and dark appearances. All five options show the correct guidance and signed sample values. +100 / −100 endpoints and the zero catch were exercised through the range control.
- Selected Reset restored only the selected value to 0, disabled itself at neutral and left the other edited values intact. Missing-map Width retained −12 with slider/reset disabled and option navigation enabled; selecting Size left its slider available. Processing disabled option buttons, slider, selected Reset and Reset all while retaining values.
- At a 320 px browser viewport, all five explanations fit without overlap, the page had no horizontal overflow, and the panel/canvas remained 184/449 px. The labeled slider becomes shorter at this width, which supports recommending Wide slider for precision.
- No browser warnings/errors were reported. The initial design-only review left application source unchanged from `dd97cc7`. The subsequent approved native implementation is described below. The private inline copy matches the ignored worktree mockup.

## Reset spacing revision

Both mockups retain the requested 4 px vertical reset-button gap, using Eyes-only 8 pt top / 12 pt bottom padding to preserve the 184 px panel and 449 px canvas. The user asked to revert the dot changes while keeping this spacing correction. Original dot visibility/layout, option auto-reveal and value-badge sizing have been restored.

Reset spacing and unchanged mockup panel/canvas dimensions were checked in light/dark appearances and at a 320 px browser viewport before native implementation.

## Endpoint wording revision

At the user's request, normal-state guidance is reduced to plain endpoint words directly under the actual slider track, left/right aligned. There is no separate meaning/neutral sentence or minus/plus prefix. Mockup endpoint words use 13 px type, with the approved 11 px endpoint scale at narrow widths; multiword labels can wrap within the existing footer area. Unavailable/processing messages still occupy the helper area when relevant. The mockup retains the 4 px reset-button gap, original dot behavior, 184 px panel and fixed canvas.

## Approved native implementation

- Only `area == .eyes` uses the new wide control, signed badge, midpoint stem, selected Reset and plain endpoint words. Original controls remain for every other Face category.
- `ValueSlider` is reused without source changes, with the existing continuous range, zero catch/haptic and drag editing callbacks. Selected Reset retains `sliderEditing(true/false)` and the original `< 0.001` disabled threshold. Reset all retains `resetFaceSliders()` and its availability/scope.
- Original category/option navigation and dot behavior are unchanged. Eyes-only top padding is 8 pt, bottom padding 12 pt, with a 4 pt reset-row gap. The 184 pt intended budget remains a minimum; native text and multi-face context can require additional space. Endpoint text uses semantic footnote typography.
- Missing-map/no-face captions and per-face switching context are retained. Size keeps its landmark fallback; the other four controls keep the mesh guard. The inherited editor busy lock and per-face model storage are unchanged.
- Source scope comparisons and whitespace checks passed. Shared slider/model/range/mapping code, canvas, guides, gestures, other tools and video are unchanged. Xcode, native build and XCTest are unavailable on this Windows host; Mac build and device validation remain necessary.
