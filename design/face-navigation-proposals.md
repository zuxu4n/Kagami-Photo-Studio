# Face navigation: approved Stacked rails

The user explicitly selected **Stacked rails** in a written message on 2026-10-24 (America/Toronto), and it is implemented in `ui-a`. Category picker remains an unselected alternative. Read `DESIGN.md` for the implementation boundaries and validation status.

Preview: `design/mockups/yumiro-face-navigation-local.html`. This ignored local file reuses the supplied preview photograph; do not force-add, publish, or import the photograph into the application. This chat's readable inline copy is at `C:/Users/Jason/.codex/visualizations/2026/10/24/01a16cbd-75e4-7df3-aa0a-c421b001d992/yumiro-face-navigation-local.html`.

## Two directions

**Stacked rails (approved and implemented):** a scrolling category row over a scrolling option row. Both levels remain visible. A partially visible next item and a small edge fade communicate horizontal overflow. Selection scrolls into view, and each category remembers its last option. This favors quick repeated adjustment.

**Category picker:** a full-width current-category control opens an anchored, two-column chooser containing all eight categories in the original row-major order. Selecting a category closes the chooser; the option row continues to scroll horizontally. The mockup initially opens the chooser to show its structure. This favors discoverability and direct access to distant categories, with an extra tap and a temporary overlay on the lower canvas. Escape or tapping the canvas closes the chooser in the preview; this does not add a gesture to app code.

Both directions preserve the existing option order and bindings. No extra category, option, search, reset, or face-switching control is proposed.

## Visual specification

- System typography: category labels 15 pt, option labels 13 pt; selected labels semibold. These browser sizes model the existing subheadline/footnote hierarchy.
- Selection: approved soft accent backing, accent text, 14 pt corners, and a 14 x 2 pt underline. Selection remains visible at zero.
- Applied edits: a separate 6 pt neutral dot, including on the selected option and selected category. A category dot means any of its mapped options has edits. The dot does not indicate selection.
- The preview uses the light/dark palette from `DESIGN.md`. App implementation would use existing semantic colors and SF Symbols, not browser colors/icons as assets.
- Each navigation row has 44 pt targets. A 32 pt visible backing sits within the target, leaving 12 pt between the two rows' visible backings. Horizontal item gaps are 4 pt.
- Default panel budget: category 44 + options 44 + unchanged slider row 44 + existing helper/reset row 28 = 160 pt, plus existing 12 pt top/bottom padding = 184 pt. The illustrative canvas stays 449 px in the 844 px editor shell, matching earlier reviews.
- The category chooser overlays the canvas; it does not expand the panel or resize the image.
- Only navigation is interactive in this review. The original inline slider/value/reset arrangement and helper/Reset all row are shown for context. Face guides are illustrative; native guide geometry and all canvas interactions remain untouched.

## Exact inventory

| Category | Options in existing order |
|---|---|
| Face | Size, Width, Smile, Position, Perspective, Smirk |
| Head | Size, Width, Height |
| Jaw | Jaw, Jawline, Chin, Size, Define, Length |
| Nose | Size, Width, Narrow, Lift, Tip |
| Eyes | Size, Width, Height, Tilt, Distance |
| Lips | Size, Height, Width |
| Eyebrows | Thick, Lift, Shape, Tilt, Raise |
| Forehead | Height |

Eight categories, 34 options. Face/Head Size and Width share model properties; edits and category dots must continue to reflect those aliases. Position continues to use the existing oval instead of a slider. Existing per-face state, change threshold, ranges, haptics, resets, undo grouping, processing guards, sliders, guides, rendering, and canvas gestures are outside this redesign.

## Focused Mobbin research

- [WhatsApp avatar editor](https://mobbin.com/screens/a6e343ee-c1a6-419b-a22c-f962884c951d): two navigation levels, category selection above a horizontally scrolling subcategory row. Informs Stacked rails.
- [VSCO tools](https://mobbin.com/screens/8aa78b87-281b-4e81-bb2e-a1d9e1d931f9): related adjustments organized by category. Informs maintaining a clear hierarchy instead of flattening all 34 options.
- [Azar beauty editor](https://mobbin.com/screens/8f295b8c-0d6e-4715-879d-af53d7f8352d): an active-tool ring and separate dots on other edited tools. Informs separating selected state from applied edits.
- [Halide Quick Edit](https://mobbin.com/screens/298d9809-7e34-4cb6-9c07-4a0fa712c8ba): a compact mode row above horizontally arranged choices. Reinforces the two-level hierarchy.

The category popover is a Yumiro proposal using the approved control vocabulary; it is not a copied Mobbin screen. No reference images or third-party app assets were imported.

## Validation

Browser mockup checks cover both directions, light/dark, all eight categories and all 34 options, selected-neutral and selected-edited states, category edit dots, shared Face/Head changes, remembered category options, overflow access, 44 pt navigation targets, the 184 px panel, and narrow-width layout. JavaScript syntax and inventory comparisons were checked separately. These are browser results, not native device measurements.

Native implementation source checks passed: only Face layout/navigation changed; the original slider/Position controls, help/reset behavior, inventory and model mappings remain intact. Shared slider/model code and the canvas/guide/gesture code are unchanged. `git diff --check` passed. Xcode and Swift are unavailable here, so the implementation still needs a Mac build and native light/dark, Dynamic Type, VoiceOver, per-face, scrolling and undo/reset checks. The later Eyes-control design request was deferred by the user and is not implemented.
