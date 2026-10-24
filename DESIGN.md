# Yumiro design A handoff

Updated 2026-10-24 (America/Toronto). This is the design A source of truth for approved colors, typography, spacing, component states, references, and implementation boundaries. The seven earlier approved UI changes were pushed through **5efeebaa03558c9687f4e263502bf784233a3bfa**, and Stacked rails navigation through **dd97cc7**. Eyes now uses the reviewed Wide slider with endpoint labels and reset spacing described below. Retouch remains a proposal. Read this document before continuing design A.

## Worktree, branch, and authorization

- Work only in `C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a`, on branch `ui-a`. Use absolute paths for file operations.
- Remote: `https://github.com/zuxu4n/Yumiro.git`.
- The user authorized committing to `ui-a` and pushing with `git push origin ui-a`. This supersedes the earlier instruction not to push until told.
- Never merge into main or push to `main` or `ui-b`. Do not edit `C:/Users/Jason/OneDrive/Desktop/Code/js/photoStudioClaude` (main) or `C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-b` (the other design session).
- New UI areas follow the established workflow: research with Mobbin, show two editor-context mockups, wait for the user's selection, then implement the approved area only. Do not treat switching a preview carousel as implementation approval.
- Early exploration, before the worktree instructions, changed the separate original `C:/Users/Jason/OneDrive/Desktop/Code/js/photoStudio/Yumiro` checkout. It may retain an uncommitted duplicate Focus rail edit; its status was not rechecked for this handoff. It is not the design A worktree. No edits were made to `photoStudioClaude`.

This Windows PC has no Xcode, model packages, or `Local.xcconfig`. The user builds on a Mac, from their checkout containing those local assets:

```sh
tools/install_variant.sh a
```

The script fetches/pulls `ui-a` and installs a separate app named **Yumiro A**, bundle ID `com.zuxu4n.photostudio.a`. Do not change signing, model assets, bundle IDs, or the install script for visual work.

## Implementation status

All nine approved components below are implemented. This change adds the reviewed Eyes controls following the user's commit/push request. No Retouch redesign is implemented, and choosing an option in a mockup alone does not approve implementation.

| Area | Approved direction | UI commit | Status |
|---|---|---|---|
| Bottom photo-editor tool picker | Focus rail | `1799676` | Implemented and pushed |
| Photo-editor top bar | Balanced bar | `93155a5` | Implemented and pushed |
| Canvas Compare, Original badge, fit-to-screen | Soft controls | `63b357c` | Implemented and pushed |
| Smooth panel | Quiet row | `e8d5a3d` | Implemented and pushed |
| Photo Adjust → Crop controls | Shape rail | `48ff495` | Implemented and pushed |
| Photo Adjust → Rotate & Straighten | Action row | `c9b55d6` | Implemented and pushed |
| Photo Adjust → Brightness, Contrast, Saturation, Warmth | Focused slider hybrid | `5efeeba` | Implemented and pushed |
| Face → category and subcategory navigation | Stacked rails | `dd97cc7` | Implemented and pushed; native validation pending |
| Face → Eyes controls | Wide slider with endpoint labels | This change | Implemented; native validation pending |
| Retouch panel | Compact rows preferred | None | Mockup only; latest spacing revision awaits acceptance |

The first four UI changes are in [ContentView.swift](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/PhotoStudio/ContentView.swift). Crop, Rotate, and light/color styling are in [Adjustments.swift](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/PhotoStudio/Adjustments.swift), with explicit photo-only opt-ins (`photoCropStyle`, `photoRotateStyle`, `photoColorStyle`) at the `AdjustPanel` call in `ContentView.swift`. The shared video panel keeps its original presentation. Smoothing and retouch rendering, per-face storage, canvas gestures, camera, video editor, and home screen were not changed. Retouch still uses the original three `sliderRow` calls in app code.

## Visual foundations

### Colors and materials

Use SwiftUI semantic colors and system materials in app code. The following hex values are the browser mockups' approximate light/dark palette, not a new hardcoded application theme.

| Role | Light mockup | Dark mockup | Application source of truth |
|---|---|---|---|
| Editor surface | `#FFFFFF` | `#000000` | System background |
| Secondary controls/canvas backing | `#F2F2F7` | `#1C1C1E` | `Color(.secondarySystemBackground)` |
| Primary text | `#171719` | `#F5F5F7` | `Color.primary` |
| Secondary text/helper copy | `#696971` | `#A1A1AA` | `Color.secondary` |
| Disabled foreground | `#B6B6BE` | `#55555D` | `Color(.tertiaryLabel)` / native disabled state |
| Separator | `#D9D9DE` | `#38383A` | `Divider` / system separator |
| Accent | `#007AFF` | `#0A84FF` | `Color.accentColor` |
| Soft selected backing | `#E9F3FF` | `#092B4C` | Accent at 12% opacity |
| Stronger blue text in previews | `#0064CC` | `#6BB5FF` | Mockup approximation; existing app uses accent color |
| Canvas overlay backing | `#F8F8FA` | `#242426` | `.regularMaterial` |

Save has a solid accent background and white text. Secondary controls use neutral surfaces. Selection combines blue with shape/underline; it should not depend on hue alone. Preview material fills are approximately 94% opaque with blur, but native material rendering is system-managed. No native color-contrast audit has been completed.

### Typography and icons

Use the system font and SF Symbols in the app. Browser mockups use system-font fallbacks and Lucide approximations; those icons are not assets to import into SwiftUI.

| Element | Implemented typography |
|---|---|
| Save | `.body.weight(.semibold)` (about 17 pt at default size) |
| Top-bar / canvas action icons | System 20 pt |
| Focus rail icons | `.title3`, within a 24 pt icon frame |
| Focus rail labels | `.caption2` (about 11 pt), regular; selected semibold |
| Smooth label and value | `.subheadline.weight(.medium)` (about 15 pt); value uses monospaced digits |
| Helper text | `.footnote` (about 13 pt), secondary foreground |
| Original badge | `.caption.weight(.semibold)` (about 12 pt) |
| Fit zoom value | `.footnote.weight(.medium)`, monospaced digits |
| Crop header | `.body.weight(.medium)` (about 17 pt) |
| Crop Cancel / Done | `.subheadline` (about 15 pt), regular / semibold |
| Crop ratios | `.caption2` (about 11 pt), regular; selected semibold |
| Rotate action icons / short captions | System 20 pt / `.caption2` (about 11 pt) |
| Straighten label / angle | `.subheadline.weight(.medium)` (about 15 pt); angle uses monospaced digits |
| Compact Straighten label / angle; Reset all | `.footnote` (about 13 pt); compact angle uses monospaced digits |
| Light/color header / active value / edited tile number | `.subheadline.weight(.medium)` (about 15 pt); numbers use monospaced digits |
| Light/color neutral tile icons / captions | System 20 pt / `.caption2` (about 11 pt), regular; selected caption semibold |
| Light/color slider endpoint labels | `.caption2.monospacedDigit()` (about 11 pt), secondary |
| Face category / subcategory labels | `.subheadline` (about 15 pt) / `.footnote` (about 13 pt); selected semibold |
| Eyes value / endpoint words / multi-face context | `.subheadline.weight(.medium).monospacedDigit()` / `.footnote` / `.caption2` |

The photo editor already caps Dynamic Type at `.xLarge`; that limit was preserved. Default browser text sizes do not establish native Dynamic Type behavior. Retouch's compact mockup labels/value badges are 13 px; check native legibility before treating that as final SwiftUI typography.

### Spacing and geometry

Existing `Space` constants: `xs = 4`, `s = 8`, `m = 12`, `l = 16`, `xl = 24`, `xxl = 32`.

- Top bar: 52 pt high; 12 pt horizontal insets; icon targets at least 44 x 44 pt.
- Save: at least 76 x 44 pt; 17 pt horizontal label padding; 14 pt continuous corner radius.
- Primary neutral control radius: 14 pt. Value badge radius: 10 pt.
- Bottom picker: 66 pt high. Each tool has a 58 pt visual backing inside a 66 pt target, minimum width 66 pt, 6 pt horizontal content padding.
- Picker item spacing: 2 pt. Horizontal outer padding: 8 pt. Group dividers: 24 pt high with 5 pt horizontal padding.
- Selected picker underline: 14 x 2 pt, 3 pt above the backing's bottom edge. Changed-tool dots: 6 x 6 pt on non-selected tools.
- Canvas controls: bottom-left/bottom-right, 12 pt inset. Original stays top-center with a 10 pt top inset.
- Tool panel: existing minimum 184 pt area, generally 16 pt horizontal and 12 pt vertical padding. Preserve canvas proportions when changing a panel.
- Native sliders keep system track/thumb rendering and a 44 pt interaction frame. The mockup's 4 px track and 26 px thumb are illustrative.
- Adjust panels use 6 pt vertical gaps. Crop and Rotate retain their original subtool row; the light/color hybrid uses a 46 pt strip. Crop ratio tiles use 4 pt gaps; light/color numeric tiles use 2 pt gaps.
- Light/color control budget: header 44 + gap 6 + slider/endpoints 58 + gap 6 + strip 46 = 160 pt, plus the existing 24 pt vertical padding = 184 pt. Endpoint labels occupy 14 pt below the slider. This is the intended default-size budget, not a native layout measurement.
- Rotate and light/color Reset all targets are 64 × 44 pt, or 46 × 44 pt in their compact variant. Header item spacing is 8 pt; Rotate's transform-action spacing is 4 pt.

### Selected, changed, and unavailable states

| State | Approved treatment |
|---|---|
| Selected main-rail tool, Crop ratio, or light/color tile | Soft 12% accent backing, accent foreground, semibold caption, short underline; selection remains visible at neutral. The original Crop/Rotate subtool row retains its existing accent-only selection |
| Changed tool | Existing 6 pt dots on the main rail and non-selected Crop/Rotate subtools; light/color tiles instead replace the icon with a signed number |
| Neutral light/color setting | SF Symbol in the tile; active value badge shows 0 on a neutral surface; selected Reset is unavailable |
| Edited light/color setting | Signed number occupies the same 44 × 24 pt icon slot; active badge is accented; selected Reset restores only this parameter and its icon |
| Unavailable action / busy panel | Native disabled controls and tertiary action foreground; ratio/numeric tiles use 45% opacity and retain current values and selection |
| Pressed custom action / tile | 70% opacity where the approved button style supplies it |

Reset availability follows existing model checks, not the rounded text: light/color uses `abs(value) > 0.001`; Rotate uses its existing geometry check; Crop uses its current ratio check. Reset all remains unavailable when all Adjust settings are off and continues to reset the entire Adjust model, including crop and rotation. Do not silently change these scopes as part of styling.

## Approved components and behavior

### Focus rail

One horizontally scrolling strip, in the existing order and groups:

1. Enhance, Adjust.
2. Smooth, Retouch, Face, Warp.
3. Heal, Background.

Selected tool: soft blue rounded backing, accent icon/text, semibold label, short underline. Other tools stay neutral; tools with edits retain their existing changed dots. Auto-centering on selection, selection haptics, accessibility labels/selected traits, and tool behavior are retained. Do not add tools or categories.

### Balanced top bar

Close left, Undo/Redo truly centered as a pair with 4 pt spacing, Save right. Save is the primary action. Separate neutral 44 pt rounded icon targets match the rail's geometry. Undo/Redo use the existing availability/busy guards; unavailable actions use tertiary foreground. Save's disabled backing uses accent at 35% opacity; pressed controls use 70% opacity. Existing discard confirmation and export behavior are retained. VoiceOver priorities order Close, Undo, Redo, Save.

### Soft canvas controls

- Compare: 44 x 44 pt, rounded rectangle radius 14; hold to compare, not a toggle. Active appearance adds accent foreground and a 12% tint.
- Original: non-interactive top-center badge; minimum height 28 pt; horizontal padding 12 pt, vertical padding 5 pt, radius 14.
- Fit: appears only for `zoom > 1.01`; inward arrows plus the current one-decimal zoom factor; minimum 44 pt height; horizontal padding 12 pt; icon/value spacing 7 pt. Tap resets zoom to 1 and pan to zero.
- Shared backing: regular material, subtle 1 pt border (primary at 8%, active accent at 28%), black shadow at 8% opacity, radius 2, y-offset 1.

Image aspect-fit sizing, clipping, pinch/pan calculations, photo hold behavior, and crop/busy control visibility are unchanged. Compare retains its original zero-duration press handling and 60 pt maximum distance. Native press and gesture behavior still requires device verification.

### Smooth Quiet row

Header has Smooth skin, a fixed blue numeric value badge, and Reset. A full-width native slider sits below, then helper text, with 8 pt vertical spacing. Header and slider have 44 pt interaction frames; value badge is at least 44 x 32 pt.

Behavior that must remain intact:

- Continuous internal range `0...1`, shown as rounded `0...100`.
- First entry into Smooth on a photo starts at `0.3` (display **30**) and records the existing automatic edit. Returning to the tool does not reapply it.
- Reset goes to **0**, not 30. It is disabled near zero (`abs(smooth) < 0.001`) or while busy.
- Each drag is bracketed by `model.sliderEditing(editing)`; Reset brackets its assignment with `sliderEditing(true/false)`. Each actual drag/reset remains one undo step.
- Native slider availability follows the existing busy lock. No new no-face restriction was added.
- Helper: “Edges, eyes and lips stay sharp”; no-face: “No face found in this photo”; busy: “Available when processing finishes”.

## Adjust → Crop: approved Shape rail

The user explicitly selected **Shape rail** after reviewing two editor-context proposals, Shape rail and Pinned modes, on 2026-10-24. Only the photo editor opts into the new styling (`photoCropStyle: true`); video retains its original panel.

- All ten options stay in their existing order: Original, Free, 1:1, 4:5, 3:4, 2:3, 9:16, 4:3, 3:2, 16:9.
- Each ratio has its existing 26 pt outline/icon above an 11 pt system caption, in a minimum 58 × 58 pt tile with a 14 pt continuous radius. Selection adds a 12% accent fill, accent foreground, semibold caption, and a 14 × 2 pt underline 3 pt above the bottom. Tiles have 4 pt spacing and retain horizontal scrolling and initial centering on the current ratio.
- Crop, Reset, Cancel, and Done share a 44 pt header. Reset is a neutral 44 × 44 pt icon control. Cancel and Done have at least 60 × 44 pt targets; Done uses the solid accent treatment. All colors are semantic for light/dark appearance, and controls respect the existing busy lock.
- The existing 58 pt ratio area, 6 pt panel gaps, Adjust subtool row, and outer panel padding remain. The default-size content fits the existing 184 pt minimum panel budget; native sizing at larger Dynamic Type still requires device verification.
- Selecting a ratio still clears `cropRect` through the existing `change` callback and remains one undo step. Original means no crop; Free remains unrestricted. Reset still restores Original and clears `cropRect`, and is unavailable when the crop is Original. Cancel restores the ratio and frame captured on entry; Done retains the crop. Both exit to the previous Adjust subtool and retain existing haptics.
- The crop frame, masks, handles, geometry, rendering callbacks, canvas gestures, and video controls were not changed.

The approved review includes light/dark, Original/reset unavailable, changed/reset available, existing crop/Cancel restore, and busy states. The browser mockup is illustrative; no native screenshot, Xcode build, or iOS runtime verification has been completed on this Windows host. JavaScript syntax validation passed; the browser could not reach the local preview server for visual QA in this chat.

## Adjust → Rotate & Straighten: approved Action row

The user explicitly selected **Action row** after reviewing Action row and Split controls. This styling is enabled only for the photo editor (`photoRotateStyle: true`); video and the other Adjust sections keep their existing controls.

- Four 44 × 44 pt controls show Turn left, Turn right, Flip across, and Flip upside down. Their short captions are Left, Right, Across, and Up/down. Turns are momentary actions; active flips have soft accent fill and a short underline, computed in the displayed orientation.
- Reset Rotate clears turns, both flips and straighten through the original `AdjustTool.rotate.reset` and undo callback. It does not clear crop or color settings. Reset all retains its existing scope over all Adjust settings. Existing availability and busy guards remain.
- A labeled native straighten slider and a 60 × 32 pt signed angle badge occupy the next row. The slider still uses the existing `ValueSlider` binding, continuous -1...1 range (±15°), zero catch, haptics, drag callbacks and degree formatter. `showsValue: false` hides only the duplicate inline output for this use; every existing caller retains the default output.
- Controls retain semantic colors, 14 pt action radii and a 10 pt value-badge radius. The angle is neutral at displayed zero and accented otherwise.
- `ViewThatFits` provides a compact version: the five transform/reset controls remain in the first row, Reset all moves beside the slider, and the angle moves beside the Straighten label. Both layouts retain 44 pt touch targets, the 44 + 6 + 58 pt control budget, existing subtool row and outer panel padding. Native Dynamic Type/layout verification remains necessary on a Mac.
- Quarter turns still clear `cropRect`. Flips retain their orientation-aware callbacks. Reset Rotate preserves `cropRect`. The crop frame, canvas, gestures, rendering callbacks, other panels and video behavior were not changed.

The user supplied a replacement preview photo. It is embedded only in local, ignored Rotate and light/color mockups and in this chat's local previews; do not add the photo or its embedded bytes to Git or publish them. Future previews should reuse that local image instead of the astronaut. The original public-image proposal remains available in the prior chat history. The supplied photo is not an app asset or an editor default.

References: [Apple Photos](https://mobbin.com/screens/3a719f66-2139-427b-99c5-2ebc19fc044c), [Instagram](https://mobbin.com/screens/720bfb83-b9d4-4577-a1b9-814ca1646d24), [GoPro Quik](https://mobbin.com/screens/c628e27c-ed54-440e-9e80-4a64333d73b8).

Mockup QA covered default and adjusted light/dark appearances, quarter turns, flip orientation, signed ±15° endpoints, Reset availability, narrow reflow, a 184 px panel and 44 px reset target. These are browser mockup checks, not native runtime tests. Xcode and XCTest are unavailable on this Windows host.

## Adjust → Light and color: approved Focused slider hybrid

The user reviewed two editor-context proposals, chose the focused slider with visible changed values, then approved the combined mockup and requested commit/push. Only the photo editor opts in (`photoColorStyle: true`), and only while Brightness, Contrast, Saturation, or Warmth is selected. Crop and Rotate retain their approved controls and subtool row; video retains its original presentation.

- The selected tool has a 44 pt header with a 15 pt medium label, a 44 × 32 pt signed value badge, a 44 × 44 pt Reset control, and the existing Reset all action. Neutral values use secondary styling; edited values use accent foreground and a 12% accent backing. Action corners remain 14 pt and value-badge corners 10 pt. A compact Reset all width is available through `ViewThatFits`.
- One full-width native `ValueSlider` sits below, with −100 / 0 / +100 endpoint labels. All four retain their continuous internal **−1...1** ranges, **0** neutral, rounded signed −100...+100 display, existing zero catch, haptics, bindings, rendering callbacks, and per-drag undo grouping. The shared slider implementation is unchanged; only its duplicate inline output is hidden here.
- In the adjustment strip, each neutral tool shows its SF Symbol. A changed tool replaces only that icon with its signed numeric value in the same 44 × 24 pt slot. There is no additional changed dot for these four tools. Resetting a tool to neutral restores its icon; other edited tools keep their values.
- Selection remains separate from edit state: a 12% accent tile, semibold caption, and 14 × 2 pt underline identify the selected tool even at zero. Edited peer numbers remain accented. Numeric tiles are at least 52 × 46 pt and scroll horizontally at narrow widths while preserving selected-tool visibility. Crop and Rotate keep their original icons, labels, and changed dots alongside this group.
- Reset uses the existing selected-tool reset and undo callback and is unavailable at neutral. Reset all keeps its original scope over **all Adjust settings**, including geometry. The existing busy lock disables the controls without discarding the displayed values. Semantic colors provide light/dark appearances; disabled numeric tiles dim while retaining their icons or values.
- The 44 + 6 + 58 + 6 + 46 pt content fits the existing 184 pt panel with the unchanged outer padding. Canvas, crop frame, gestures, image processing, other editor panels, and video are unchanged. Native layout and accessibility still need device verification.

The approved private preview is `design/mockups/yumiro-focused-slider-hybrid-local.html`; the earlier two-option comparison is `design/mockups/yumiro-adjust-colors-local.html`. Both embed the supplied photo and remain ignored by Git. The photo is neither an app asset nor part of the pushed implementation.

Mobbin references: [VSCO](https://mobbin.com/screens/adea8809-53d5-419b-9ceb-67d4f0def085) for light/color grouping, [Google Photos](https://mobbin.com/screens/9b042739-12d6-41ac-a180-2d438133cba1) for adjacent adjustments and changed indicators, and [Apple Photos](https://mobbin.com/screens/75d7aa74-5770-4c83-a4b5-8afd6555ae7f) for a focused adjustment strip.

Mockup QA covered all-neutral icons, mixed signed values, selection independent of edits, Reset restoring an icon while preserving peer edits, disabled values, light/dark appearances, narrow scrolling, and signed endpoints. Implementation validation compares the model, shared slider, original Crop/Rotate controls, canvas, video, and rendering/undo callbacks against the previous commit. These are browser and source checks; Xcode and iOS runtime checks are unavailable on this Windows host.

## Face navigation: approved Stacked rails

The user explicitly selected **Stacked rails** in a written message after reviewing both editor-context mockups. Category picker remains an unselected alternative. The `dd97cc7` implementation changed only category/subcategory navigation and its Face-specific layout grouping in `ContentView.swift`. The subsequent Eyes control implementation is described separately below.

- Two horizontal rails retain all eight categories and all 34 options in their original order. Each category still remembers its selected subcategory. Both rails reveal their selected item on appearance; categories center on selection, and subcategories center on selection or when their category is reopened.
- Categories use system subheadline and subcategories use footnote, regular or selected semibold. Each button has at least a 54 pt category / 58 pt subcategory width and a 44 pt target. Its visible backing is 32 pt high with 14 pt continuous corners; item spacing is 4 pt and horizontal label padding is 12 pt.
- Selection uses accent text, a 12% accent backing and a 14 x 2 pt underline, including at neutral. A separate 6 pt secondary-colored dot identifies applied edits, including on selected categories/options. The existing selected-face change detector is unchanged: ordinary features use `abs(value) > 0.001`, and Position uses `positionMoved`. Face/Head Size and Width continue to share model properties and changed states.
- The native scroll views retain horizontal overflow. Small leading/trailing fades appear only where content actually continues, using iOS 18 scroll geometry (the existing project deployment target is iOS 18). Fades ignore hit testing and accessibility. No canvas gesture was added or changed.
- The two 44 pt rails, 44 pt control slot and minimum 28 pt footer model the existing 160 pt content / 184 pt panel budget. The Face-only stack removes redundant inter-row gaps; the original slider/Position view and helper/Reset all contents are retained. The panel remains a minimum rather than a fixed height, so native text sizing may require more room. No native height measurement has been performed here.
- The original slider/value/reset styling, effect ranges, bindings, selected-face storage, render callbacks, reset scopes, undo grouping, selection haptics, mesh availability and editor processing lock are unchanged. The shared `Chip` and `ValueSlider` implementations were not modified. Canvas, face guides, other tool panels, camera and video are unchanged.
- VoiceOver receives the original label, selected trait, and an explicit “Edits applied” value when changed. Decorative dots/fades are hidden. Custom buttons use the approved 70% pressed opacity and 45% disabled opacity while retaining selection and edit indicators. Semantic colors support light/dark appearance, and the existing xLarge Dynamic Type cap remains.

Local private mockup: `design/mockups/yumiro-face-navigation-local.html` (ignored, contains the supplied photo). The inline preview is served from the chat-owned regular-file copy at `C:/Users/Jason/.codex/visualizations/2026/10/24/01a16cbd-75e4-7df3-aa0a-c421b001d992/yumiro-face-navigation-local.html`; use that path for this chat's visualization reference. Do not force-add either private preview. Full inventory and research are in `design/face-navigation-proposals.md`.

Mobbin references: [WhatsApp](https://mobbin.com/screens/a6e343ee-c1a6-419b-a22c-f962884c951d) for the two-level hierarchy, [VSCO](https://mobbin.com/screens/8aa78b87-281b-4e81-bb2e-a1d9e1d931f9) for grouped adjustments, and [Azar](https://mobbin.com/screens/8f295b8c-0d6e-4715-879d-af53d7f8352d) for independent selection/edit indicators.

Validation: `git diff --check` passed. A source comparison confirmed changes are confined to the Face layout/navigation regions, with the original slider/Position controls, helper/reset behavior, Face inventory and feature mappings preserved. Everything outside those regions in `ContentView.swift`, including canvas/gestures/guides, is unchanged. No native build or XCTest run is possible on this Windows host. On the Mac, verify both appearances, narrow widths, Dynamic Type through xLarge, VoiceOver, selecting offscreen items, reopening each category's remembered option, selected-neutral/selected-edited states, shared Face/Head dots, per-face switching, busy lock, Position and unchanged slider undo/reset behavior.

## Eyes controls: approved Wide slider

After reviewing the Eyes mockups and requesting reset spacing, restoring original dots, and replacing helper prose with endpoint words, the user requested commit/push. The reviewed Wide slider is implemented only for Face → Eyes in `ContentView.swift`. Labeled slider remains an unselected alternative.

- All five options remain Size, Width, Height, Tilt, Distance with their existing bindings and continuous **−1...1** ranges, neutral **0**, and signed rounded **−100...+100** output. The existing `ValueSlider` is reused with only its duplicate inline value hidden. Its zero catch, zero haptic and drag callbacks are unchanged.
- The approved category/option rails identify the current control, so the duplicate slider title is omitted. A semantic 44 x 32 pt value badge uses 10 pt corners, monospaced subheadline digits, neutral styling at zero and accent styling for an edit. Unavailable controls retain their signed value in tertiary styling.
- Plain endpoint words align with the actual slider edges: Smaller/Larger, Shorter/Longer, Less open/More open, Down/Up, Closer/Farther. The separate meaning/neutral helper paragraph and minus/plus prefixes were removed. A non-interactive midpoint stem and the slider's accessibility hint identify zero as neutral.
- Selected Reset reuses the approved 44 pt neutral icon-button styling. It returns only the selected parameter to zero through the original `sliderEditing(true/false)` undo boundary. Its original `abs(value) < 0.001` disabled threshold is preserved. Reset all still calls `resetFaceSliders()`, with its existing availability and scope over all Face shape settings for the selected face; Retouch and other faces retain their existing behavior.
- The reset rows have a 4 pt gap. Only Eyes uses 8 pt top / 12 pt bottom padding; other panels/categories retain 12 pt vertical insets. The intended default-size budget is two 44 pt navigation rows + 44 pt controls + 4 pt gap + minimum 28 pt footer + 20 pt padding = 184 pt. Footer space for the 44 pt value, 44 pt reset and two 8 pt gaps keeps endpoint words aligned with the slider. The panel remains a minimum and may grow for native text sizing or multi-face context; no native height measurement has been performed.
- Original navigation and dot behavior are unchanged, as requested. No fixed dot slots or rail-stability revision was applied to app code. The shared `Chip`, `ValueSlider`, other Face controls, rendering model, effect ranges, per-face storage, canvas, guides, gestures, camera and video are unchanged.
- Width/Height/Tilt/Distance retain the existing mesh requirement; Size retains its Vision landmark fallback. There is no new blanket no-face lock. Existing unavailable/no-face captions remain, and the busy state shows concise processing guidance. Multi-face context (“Face N of M · tap another face to switch”) is retained below the endpoint words. The editor-wide processing lock remains intact.

Validation: `git diff --check` passed. Source comparison confirmed that only the Eyes presentation branch, new Eyes presentation helpers and Eyes-specific top padding changed. The original controls for every other Face category and all navigation/dot code remain identical. The shared slider, adjustment/model files, undo boundaries, per-face storage, canvas/guide/gesture code and all feature mappings/ranges are unchanged. The final browser review covered endpoint alignment, reset spacing, signs, default/adjusted/unavailable states, light/dark and narrow widths. Those are browser results, not native screenshots. Xcode/build/XCTest are unavailable on this Windows host; the Mac must validate native layout, Dynamic Type, VoiceOver, mesh fallback, per-face switching and drag/reset undo/redo.

Private preview: `design/mockups/yumiro-eyes-controls-local.html` (ignored, contains the supplied photo). The inline regular-file copy is at `C:/Users/Jason/.codex/visualizations/2026/10/24/01a16cbd-75e4-7df3-aa0a-c421b001d992/yumiro-eyes-controls-local.html`. Do not force-add either preview. Research, inventory and review notes are in `design/eyes-controls-proposals.md`.

## Retouch: preferred proposal, not implemented

The user prefers **Compact rows**, then requested two spacing corrections. The latest revision has been shown but has not received explicit final acceptance. Do not implement or push Retouch UI merely because Compact rows is the carousel's selected preview.

Latest mockup details:

- All three adjustments stay visible: Whiten Teeth, Brighten Eyes, Even Tone.
- Each row contains label, native-style slider, value badge, and its own 44 x 44 reset button with 14 pt corners.
- A soft row highlight and short leading accent marker identify the adjustment being edited. Nonzero values are blue; zero values are neutral. Selection and a nonzero effect are distinct concepts.
- Rows are 44 pt high, with **4 pt gaps between rows/reset buttons**.
- Helper text has an **8 pt gap below the last row**. This fixes the original cramped footer without merging the reset buttons.
- Default-size panel budget: `3 * 44 + 2 * 4 + 8 + 18 = 166` pt content, plus **6 pt top / 12 pt bottom padding = 184 pt**. Horizontal padding stays 16 pt.
- If implemented, account for the shared panel's existing vertical padding with a Retouch-specific layout change. Do not shrink the touch targets or change padding for every other tool to make it fit.
- No-face state uses the existing message and control availability; sliders are currently not locked just because no face was detected. Zero resets stay disabled as usual. The preview simulates detection state without changing its sample photo.

The alternative **Adjustment tabs** is not selected: all three values remain visible in a tab row, with one full-width slider and a reset for the selected adjustment.

Retouch behavior to preserve:

- Effects are color-only: Whiten Teeth, Brighten Eyes, Even Tone. Do not alter masks, shaders, rendering order, or face shape.
- All three defaults are zero; each uses the existing continuous `0...1` range / rounded 0–100 display. Reset affects only its own adjustment and returns it to zero.
- `teeth`, `brightEyes`, and `tone` are the selected face's settings. `FaceRetouch` is stored inside each face's shape; `storeShape()` saves them and `showSliders()` restores them when the selected face changes.
- Face switching remains the existing tap-on-canvas interaction. With multiple faces, preserve the existing “Face N of M · tap another face to switch” caption and guides. Do not add an all-faces reset or make values global across faces.
- Retain the existing per-drag and per-reset undo grouping, render-on-change callbacks, busy guards, and unchanged tool behavior.

## Mockups and where to find them

Portable copies are saved in `design/mockups/`. These are interactive HTML fragments for Codex's visualization surface, not standalone apps or native screenshots. Older committed proposals use public NASA portrait imagery. New previews with the user-supplied photo are local-only and ignored by Git. Slider previews change controls/values, not the photo-processing pipeline.

| Mockup path on this PC | Direction to inspect | Status |
|---|---|---|
| [yumiro-toolbar-options.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-toolbar-options.html) | Focus rail | Original approved rail; Grouped shelf is an unselected alternative |
| [yumiro-picker-light-dark.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-picker-light-dark.html) | Focus rail | Light/dark rail follow-up; Labeled chips is unselected |
| [yumiro-top-bar-options.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-top-bar-options.html) | Balanced bar | Approved; Action cluster is unselected |
| [yumiro-canvas-controls.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-canvas-controls.html) | Soft controls | Approved; normal/comparing/zoomed, light/dark; Labeled controls is unselected |
| [yumiro-smooth-panel-options.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-smooth-panel-options.html) | Quiet row | Approved; default/adjusted/processing, light/dark; Soft card is unselected |
| [yumiro-retouch-panel-options.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-retouch-panel-options.html) | Compact rows | Latest preferred proposal and corrected spacing, not implemented; light/dark, adjusted/all-off/no-face |
| [yumiro-crop-options.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-crop-options.html) | Shape rail | Explicitly selected and implemented for photo Crop; Pinned modes is the unselected alternative |
| [yumiro-rotate-local.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-rotate-local.html) | Action row | Selected and implemented; local-only preview contains the supplied photo and is intentionally ignored by Git |
| [yumiro-adjust-colors-local.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-adjust-colors-local.html) | Focused slider / Value tabs | Earlier comparison; local-only and ignored because it contains the supplied photo |
| [yumiro-focused-slider-hybrid-local.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-focused-slider-hybrid-local.html) | Focused slider with changed values | Approved and implemented; local-only and ignored because it contains the supplied photo |
| [yumiro-face-navigation-local.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-face-navigation-local.html) | Stacked rails / Category picker | Stacked rails explicitly selected and implemented; local-only and ignored because it contains the supplied photo |
| [yumiro-eyes-controls-local.html](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-eyes-controls-local.html) | Wide slider / Labeled slider | Reviewed Wide slider implemented with endpoint words and 4 pt reset gap; original dots retained; private and ignored |

Absolute portable-copy directory on this PC:

`C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/`

Original toolbar, top-bar, canvas, Smooth, and Retouch conversation artifacts (outside Git):

`C:/Users/Jason/.codex/visualizations/2026/10/24/01a16bec-b7ee-70d3-9fdf-41f62dc294d9/`

Current Crop, Rotate, and light/color conversation artifacts (outside Git):

- [Crop Shape rail / Pinned modes](C:/Users/Jason/.codex/visualizations/2026/10/24/01a16c81-7e78-7cc2-94fb-eb94cd773c4b/yumiro-crop-options.html).
- [Rotate Action row / Split controls](C:/Users/Jason/.codex/visualizations/2026/10/24/01a16c81-7e78-7cc2-94fb-eb94cd773c4b/yumiro-rotate-options.html).
- [Light/color original comparison](C:/Users/Jason/.codex/visualizations/2026/10/24/01a16c81-7e78-7cc2-94fb-eb94cd773c4b/yumiro-adjust-colors.html).
- [Approved Focused slider hybrid](C:/Users/Jason/.codex/visualizations/2026/10/24/01a16c81-7e78-7cc2-94fb-eb94cd773c4b/yumiro-focused-slider-hybrid.html).

The current Rotate and light/color artifacts contain the private supplied photo. Their repo copies use the ignored `*-local.html` suffix. Never force-add these files. The original photo stays at `C:/Users/Jason/OneDrive/Pictures/Pfp/e9f7a063d2e8c7e60bf6781376e2c5f1.jpg`.

No native app screenshots were provided or saved in this chat. Browser screenshots were inspected during preview QA but were not persisted as files. The mockups approximate UIKit colors/icons; native code is authoritative for the implementation.

To preview a fragment locally on this Windows host, use the visualize skill's renderer, for example:

```powershell
python 'C:/Users/Jason/.codex/plugins/cache/openai-bundled/visualize/1.0.50/skills/visualize/scripts/render.py' 'C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/design/mockups/yumiro-retouch-panel-options.html' --serve
```

The preview server reads the fragment when it starts: restart it after editing, rather than assuming a page reload picked up the file. The HTML fragments need the host/renderer for carousel, icon, and optional design-control support. Do not modify app code merely to make a mockup render.

## Mobbin reference library

Use the canonical links below. Expiring image-download URLs are intentionally not part of this handoff.

### Bottom tool picker

- [CapCut](https://mobbin.com/screens/dba73525-e68a-4540-93cf-dd839c82f16b): consistent icon/label rhythm and a partially visible next tool.
- [VSCO](https://mobbin.com/screens/8aa78b87-281b-4e81-bb2e-a1d9e1d931f9): related-tool grouping.
- [Unfold](https://mobbin.com/screens/1a6347cb-9ce7-4c7a-8dbb-b0604eb89e19): clear individual tool targets.
- [Canva](https://mobbin.com/screens/6bedcf20-70f8-4c24-bbfc-96ed72eb2671): consistent icons and spacing in a long row.
- [Instagram](https://mobbin.com/screens/142955aa-23c8-4d74-a51c-ce34919c1385): separate tool backings.

### Top bar

- [Pinterest](https://mobbin.com/screens/e0a593e7-f1ac-4750-aa7b-66cde5001d46): separate Close, history, and completion roles.
- [Unfold](https://mobbin.com/screens/dde89b67-c1d2-48c8-adda-cebe19196387): paired Undo/Redo with different emphasis for availability.
- [Photoroom](https://mobbin.com/screens/54bde2a7-8801-44a4-8c0f-fba99fd8f9fc): compact grouping of related top actions.

### Canvas controls

- [Apple Photos](https://mobbin.com/screens/1a3464f9-d5e6-4b3a-a8d1-1411eff8a26e): compact Original indication.
- [Photoroom](https://mobbin.com/screens/c81968f1-67c1-4652-bd13-bf8595e8605c): explicit before/after orientation; its comparison slider is not being adopted.
- [LinkedIn](https://mobbin.com/screens/1390e851-257b-48df-87ed-90a8e42a0b46): visible zoom magnitude.

### Smooth panel

- [VSCO](https://mobbin.com/screens/df9557ce-8461-4c68-a07f-823919f788ca): numeric strength close to the active slider.
- [Shopee](https://mobbin.com/screens/e0a34c4b-29b8-4bdf-aced-9fb455d9aa09): Smooth strength with a separate Reset action.
- [(Not Boring) Camera](https://mobbin.com/screens/4a350c13-9234-42a0-97ea-acef9019fb76): title, value, helper, and slider grouped in a compact panel.

### Crop aspect-ratio selection

- [Unfold](https://mobbin.com/screens/e65a8df7-97f0-4b12-b429-955b64c919ee): outlined ratio shapes with labels in a horizontal strip.
- [Apple Photos](https://mobbin.com/screens/5bcf365a-c53b-471d-95e5-08dc4d9fa79d): compact aspect labels with a selected backing.
- [Google Maps](https://mobbin.com/screens/4aaecdc2-8367-4027-8a2c-a76390f4e527): explicit checkmarked aspect selection in its iOS crop picker.

### Rotate & Straighten

- [Apple Photos](https://mobbin.com/screens/3a719f66-2139-427b-99c5-2ebc19fc044c): adjacent orientation actions and a focused straighten control.
- [Instagram](https://mobbin.com/screens/720bfb83-b9d4-4577-a1b9-814ca1646d24): compact controls beneath the photo.
- [GoPro Quik](https://mobbin.com/screens/c628e27c-ed54-440e-9e80-4a64333d73b8): keep rotation/flip actions distinct from continuous straightening.

### Brightness, Contrast, Saturation, and Warmth grouping

- [VSCO](https://mobbin.com/screens/adea8809-53d5-419b-9ceb-67d4f0def085): related light/color adjustments in one group.
- [Google Photos](https://mobbin.com/screens/9b042739-12d6-41ac-a180-2d438133cba1): adjacent adjustment choices with changed-state visibility.
- [Apple Photos](https://mobbin.com/screens/75d7aa74-5770-4c83-a4b5-8afd6555ae7f): one focused slider tied to the selected adjustment.

The icon-to-signed-number swap is the user's approved synthesis of the Focused slider and visible changed-value directions. The alternative Value tabs layout is not the implementation.

### Retouch grouping

- [Azar](https://mobbin.com/screens/8f295b8c-0d6e-4715-879d-af53d7f8352d): distinguish the selected adjustment from neighboring tools.
- [Shopee](https://mobbin.com/screens/fbda85d0-d09e-4a6c-af5d-61a00f498c00): associate the selected adjustment with strength, value, and Reset.
- [Apple Photos](https://mobbin.com/screens/0dc105f4-8259-4396-bb88-979b3c4d9a66): compact adjustment navigation with one focused slider.

These references inform layout details; they do not authorize importing application assets, features, or code.

## Validation completed and remaining

Completed:

- `git diff --check` and the staged whitespace check passed for the latest implementation. Local `ui-a` and `origin/ui-a` both resolve to `5efeebaa03558c9687f4e263502bf784233a3bfa`; the worktree was clean before this documentation update. Earlier UI pushes were also confirmed.
- Source-scope comparisons confirmed that each UI commit only changed its approved area. The Smooth check also confirmed `EditorModel.swift` was unchanged.
- Native behavior was inspected in source: selection, undo/reset grouping, smoothing default, per-face values, busy/crop guards, gesture calculations, and fit reset. These were source checks, not runtime tests.
- Mockup JavaScript passed syntax checks. Browser previews were visually inspected for light/dark, selected/unselected or enabled/disabled states, and the requested panel states.
- Browser interactions confirmed Smooth reset to zero, value updates, processing locks; Retouch independent values/tab switching, reset of only one adjustment, and no-face presentation; canvas fit returning to normal; and top-bar history availability changes.
- Latest Retouch browser geometry was measured: **184 px panel height, 44 px reset targets, 4 px reset-button gaps, 8 px helper-text gap**. Browser pixels model native points at the intended preview scale; this is not native layout validation.
- Rotate mockup checks covered default/adjusted light and dark, signed ±15° endpoints, flip orientation, Reset availability, narrow layout, 184 px panel sizing, and 44 px reset targets.
- The light/color hybrid mockup showed all-neutral icons and mixed edited values in light/dark; resetting Brightness restored its icon while leaving Contrast's signed value visible. Selected highlight remained distinct from edit state. Disabled controls retained values. The comparison also covered narrow scrolling and −100/+100 endpoints.
- The `5efeeba` source audit compared the adjustment model, original Crop/Rotate controls, shared `ValueSlider`, reset/undo callbacks, crop frame, `EditorModel.swift`, and `VideoEditView.swift` against its parent. They were unchanged. `ContentView.swift` changed only by enabling `photoColorStyle: true`; rendering callbacks, busy lock and canvas code were unchanged. The commit contains only `Adjustments.swift`, `ContentView.swift`, and this handoff.
- All three private repo previews (Rotate, original light/color comparison, hybrid) were verified to embed the exact supplied JPEG bytes, remain ignored/untracked, and stay out of the implementation diff. No native app photo asset was added.
- Crop's JavaScript syntax/source checks passed, but its initial browser visual-QA attempt could not reach the local renderer. Do not count later successful Rotate/light/color QA or preview selections as completed Crop visual/runtime validation.

Still unfinished:

1. Get acceptance of the latest Retouch spacing revision before implementing Compact rows. Retouch remains the original UI in the app.
2. Build/install the pushed design A on the user's Mac with `tools/install_variant.sh a`. No Xcode build, XCTest, or phone install has been run in this chat. No compiler-success claim is justified.
3. Run the relevant existing regression tests on a Mac; see [TESTING.md](C:/Users/Jason/OneDrive/Desktop/Code/js/yumiro-ui-a/TESTING.md). Smooth's automatic default/undo/redo tests are especially relevant. Do not add tests that only mirror cosmetic view code.
4. Inspect native light/dark appearance, smaller supported phone widths, Dynamic Type through the existing xLarge cap, VoiceOver order/announcements, and real material legibility. Check Compare hold/release, pinch/pan, zoomed fit reset, Save, Undo/Redo, Smooth reset, and per-face Retouch persistence.
5. Verify Crop on iOS: all ten ratios, Original/Free, selected states, Reset availability, Cancel restoring an existing frame, Done returning to the previous tool, undo grouping, processing locks, light/dark, and Dynamic Type. Confirm the frame and pinch/pan behavior are unchanged.
6. Verify Rotate on iOS: left/right quarter turns, orientation-aware flips, ±15° straighten, zero catch and haptics, geometry-only Reset, global Reset all, undo/redo, busy lock, narrow reflow, and selected flip states in light/dark.
7. Verify all four light/color tools on iOS: default icons, icon-to-number replacement, signed display, selected-neutral versus edited-peer states, Reset restoring the icon and preserving peers, Reset all scope, unchanged range/neutral/zero snapping, per-drag undo/redo, disabled availability, scroll-to-selection, VoiceOver values, and light/dark at narrow widths and xLarge Dynamic Type.
8. Complete native contrast/material legibility checks and save actual device screenshots if requested. No native build, XCTest result, native screenshot, or device layout measurement is available in this handoff.
9. Keep home, camera, video editor, face/other tool panels, effects, and image geometry outside unsolicited redesign work. Continue one explicitly requested photo-editor area at a time. Unselected layouts (Grouped shelf, Labeled chips, Action cluster, Labeled controls, Soft card, Pinned modes, Split controls, Value tabs, and Retouch Adjustment tabs) remain alternatives, not implementation tasks.
