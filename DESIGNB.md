# Yumiro B: design handoff

This is the design record for **Yumiro B**, the `ui-b` branch. It lists what the user approved, what's built, what was only proposed, and what's left. Last updated 2026-10-24; the code it describes is `ui-b` at `27ca408`.

The code is the source of truth for exact values. This file says why each value is what it is, and where it lives.

## At a glance

- **Built in ui-b and pushed:**
  - the Balanced top bar;
  - the labelled-strip tool bar;
  - fill-field slider rows;
  - Track mode tabs and chips, in every use, including the camera and the video editor;
  - the Tool cards home screen;
  - the Docked panel camera, with the fill field in the camera's and the video editor's look controls, and a looks tile that hides the camera's sliders.

  None of it has been compiled or tried on the phone yet. See [Approved decisions](#approved-decisions) and [Components](#components).
- **Only proposed:** the options the user didn't pick for each part, under [Proposed but not picked](#proposed-but-not-picked). Don't build them unless the user picks one.
- **Not started:** the video editor screen.
- **Old-style leftovers:** the Adjust panel, the panel buttons, and the three sizes of changed dot. See [Not built yet](#not-built-yet).
- **Validation so far:** reading each diff, contrast worked out from the colour values, and layout arithmetic. There are no builds, test runs or device screenshots. What to check on the phone is under [Validation](#validation).
- **Open question:** the camera's looks tile icon may fall below the 3:1 a graphic needs over some pictures: in light mode over dark ones, in dark mode over bright ones, and over mid-tone ones too while it's tinted (estimated, see [Validation](#validation)). Nothing has been changed for it yet.

## How to work on ui-b

These rules come from the user. A fresh session doesn't get the previous session's memory, so they're written out here.

- **Work only in this folder** (`C:\Users\Jason\OneDrive\Desktop\Code\js\yumiro-ui-b`, branch `ui-b`). Don't read, diff, log or check out `main`, `ui-a` or any other branch. If something seems to need another branch, ask first.
- **Push with `git push origin ui-b`.** Never force-push: the install script on the Mac uses `git pull --ff-only`. Never merge into, edit or push `main` or `ui-a`.
- **Nothing builds on this PC.** It has no Xcode, models or `Local.xcconfig`. The user builds on their Mac with `tools/install_variant.sh b`, which installs the branch as its own app, "Yumiro B", and prints `ui-b at <sha>`. After each push, tell the user the commit is ready to install.
- **One part at a time.** Each round redesigns one part of the UI and leaves the rest alone:
  1. Research the part on Mobbin. Use the Mobbin connector's `search_screens` with platform `ios`, and cite each result by its `mobbin_url`.
  2. Propose **3 options** as mockups on a Design canvas Artifact. Each option sits in its own screen (the editor, for editor parts), matches what's already in ui-b, and comes in light and dark.
  3. The user picks **one** option. Never offer to build two, and never create a new branch or worktree.
  4. Build the pick in ui-b. Keep everything the code does now: haptics, undo steps, accessibility labels and traits, disabled states, scrolling to the picked item.
  5. Commit with a subject line, a blank line, then the body. Push, then tell the user it's ready for `tools/install_variant.sh b`.
- **Clean room** (README, "Clean room"). Nothing comes from Facetune, Remini, Photoroom, Meitu or BeautyPlus. Learn patterns on Mobbin, but design Yumiro's own version: never copy layouts, icons or assets. Mobbin doesn't seem to have dedicated beauty editors (a Facetune search returned unrelated apps), so the beauty patterns come from beauty cameras such as Shopee and Azar.

## Approved decisions

| Part | Approved option | In ui-b | Mockup canvas |
|---|---|---|---|
| Top bar | Design A, "Balanced" (won the A/B test) | `93155a5`, merged in at `e025bfb` | made in the design A session; no canvas in this record |
| Bottom tool bar | Option 1, "Labelled strip" | `575d86a` (first built as `62567b2`) | [Yumiro Editor Toolbar](https://claude.ai/artifact/WNMhe9Lez6KHvwpZ5nRroz) |
| Slider row | Option 3, "Fill field" | `b3f53c5` | [Yumiro Slider Row](https://claude.ai/artifact/HhNV7Z7EAWJt8dTne6YnuR) |
| Mode tabs and chips | Option 1, "Track", in every use | `6da010a` and `33ded13` | [Yumiro Tabs and Chips](https://claude.ai/artifact/R5cCo1VDvFfZjpcSPMzX3U) |
| Home screen | Option 1, "Tool cards" | `0c2c9bc` and `f52f7c1` | [Yumiro Home Screen](https://claude.ai/artifact/FBTjR8Swy3BWNDJ6ytUXqF) |
| Camera | Option 2, "Docked panel" | `20d73b0` | [Yumiro Camera](https://claude.ai/artifact/4wwPUhSG5hjzkGrtHSwNSi) |
| Camera: hiding the looks | Option 2, "Looks tile" | `27ca408` | [Yumiro Camera](https://claude.ai/artifact/4wwPUhSG5hjzkGrtHSwNSi), "Hide the looks" page |

ui-b's tool bar is **not** design A's "Focus rail" from main. The user asked for the labelled strip in ui-b on purpose.

### Approved mockups

The canvases are private claude.ai Artifacts owned by the user. Open them with the Artifact tool's `read` action, not a web fetch. The approved boards in each are:

- **Tool bar:** `DirectionA.dc.html` and `DirectionADark.dc.html` on the Options page. The canvas calls them "Direction A"; they became Option 1. That canvas predates design A, so only its tool bar is approved, not its top bar or panels.
- **Slider row:** `Option3.dc.html` and `Option3Dark.dc.html` on the Options page, and `Panels3.dc.html` on the Panels page. That canvas draws design A's Focus rail tool bar. ui-b has the labelled strip instead.
- **Tabs and chips:** `Editor1.dc.html` on the "Face in the editor" page, and `Uses1.dc.html` on the "Every use" page (Heal, both Background modes, the disabled Refine switch, the camera, the video editor). This canvas already shows ui-b's top bar, tool bar and slider fields.
- **Home screen:** `Home1.dc.html` on the "Home screen" page, and the first phone of `Busy.dc.html` on the "While a photo opens" page. Both draw the shared `Main.dc.html` with `look="cards"`.
- **Camera:** `Option2.dc.html` on the "Camera screen" page: live, recording, and camera access off, each in light and dark. All draw the shared `Main.dc.html` with `look="docked"`. The first version of the camera-off screen was black in light mode too; the user caught it, and the approved version has a grey area that follows light and dark.
- **Camera, hiding the looks:** `Hide2.dc.html` on the "Hide the looks" page: live with the looks showing, and recording with them hidden by the tile, in light and dark. It draws `Main.dc.html` with `look="docked"` and `hide="tile"`. `HideNow.dc.html` on the same page is the camera as it was before.

The camera canvas has three pages. It opens on "Hide the looks" (`HideNow`, `Hide1`, `Hide2`, `Hide3`); "Camera screen" has `Current`, `Option1`, `Option2` and `Option3`; "Parts" has the shared `Main`, `Look` and `Icon`. Every phone on it can be tried: hold the picture, tap Record, and tap the looks tile or handle.

Local copies of the canvas sources are in earlier sessions' scratchpads. They are temporary and may be deleted:

- `C:\Users\Jason\AppData\Local\Temp\claude\C--Users-Jason-OneDrive-Desktop-Code-js-photoStudioClaude\d9da43b8-b25d-4a98-a1fd-c3e284618932\scratchpad\toolbar\project\`
- `C:\Users\Jason\AppData\Local\Temp\claude\C--Users-Jason-OneDrive-Desktop-Code-js-photoStudioClaude\d9da43b8-b25d-4a98-a1fd-c3e284618932\scratchpad\slider\project\`
- `C:\Users\Jason\AppData\Local\Temp\claude\C--Users-Jason-OneDrive-Desktop-Code-js-photoStudioClaude\d9da43b8-b25d-4a98-a1fd-c3e284618932\scratchpad\tabs\project\`
- `C:\Users\Jason\AppData\Local\Temp\claude\C--Users-Jason-OneDrive-Desktop-Code-js-photoStudioClaude\ef35a15a-37f1-436c-8e6f-1376f317c51e\scratchpad\home\project\`
- `C:\Users\Jason\AppData\Local\Temp\claude\C--Users-Jason-OneDrive-Desktop-Code-js-photoStudioClaude\19a8e3b9-4843-4688-b1e8-6853d77fbb72\scratchpad\camera\project\`

Reusable mockup parts for the next canvas:

- **The `tabs` folder:**
  - `Main.dc.html`: the editor with ui-b's bars;
  - `Panel.dc.html`, `Tabs.dc.html`, `Chips.dc.html`, `Camera.dc.html` and `Video.dc.html`;
  - `Icon.dc.html`: the tool, top bar and mode glyphs.
- **The `home` folder:**
  - `Main.dc.html`: the home screen, with a `look` prop (`current`, `cards`, `tiles`, `canvas`) and a `busy` prop;
  - `Icon.dc.html`: the tool glyphs plus photo, camera, video, info, lock, chevron and a photo stack.
- **The `camera` folder:**
  - `Main.dc.html`: the camera screen, with a `look` prop (`current`, `glass`, `docked`, `strip`), a `state` prop (`live`, `recording`, `denied`), and, for `docked` only, a `hide` prop (`none`, `auto`, `tile`, `handle`) with `folded` to start the looks hidden. Holding the picture or the Compare tile compares, Record starts a pretend timer, and the looks tile or handle folds the looks;
  - `Look.dc.html`: `LookControls`, with a `layout` prop (`system`, `fill`, `strip`) and a `surface` prop (`plain`, `material`);
  - `Icon.dc.html`: close, switch camera, compare, reset, camera, looks (`slider.horizontal.3`), and a line glyph for each of the 13 looks.

**There are no device screenshots.** Nothing has been captured from a phone or simulator.

## Colours

The app uses system colours, so light mode, dark mode and Increase Contrast come for free. The `AccentColor` asset has no value set, so the accent is system blue: #007AFF in light mode and #0A84FF in dark mode.

| Role | Value | Used by |
|---|---|---|
| Accent | `Color.accentColor` | Save fill, Undo/Redo icons, picked tool icon, reset arrow, slider fill and handle, changed dots; on the home screen, the "Edit a photo" fill and the Camera, Video and tool icons; on the camera, the Compare, Switch and looks icons and the Open Settings fill |
| Control grey | `Color(.secondarySystemBackground)`: #F2F2F7 light, #1C1C1E dark | top bar buttons, slider fields, reset tiles, mode tracks, chips, Face area track; the home screen's About, Camera and Video tiles and tool cards; the camera's Compare and Switch tiles, and the area behind the camera-off message |
| Grey on a material | `Color(.secondarySystemFill)`, via `Color.trackFill(material)` | chips and tracks on a material. Nothing uses it now that the camera's panel is solid; the code path stays in `trackFill` |
| Picked tint | `Color.toolTile(scheme)`: accent at 0.14 light, 0.24 dark | picked tool tile, picked mode tile, picked chip, picked Face area; the camera's Compare tile while it's held, and its looks tile while the looks show (on top of `.regularMaterial`, as it sits over the picture) |
| Recording time | #D70015 (`Color.recordingTime`, private to `CameraView.swift`) | the camera's status pill while recording, with the time in white. System red (#FF3B30) gives white text only 3.6:1 |
| Record ring | white in dark mode, `Color(.systemGray3)` (#C7C7CC) in light (`Color.recordRing`) | the 4 pt ring around the record button, which sits on the panel; a white ring would vanish on the light panel |
| Slider fill | accent at 0.14 light, 0.28 dark | slider field fill (`SliderField.marks`) |
| Muted text | `Color.toolMuted`: rgb(0.42, 0.42, 0.44) light, (0.60, 0.60, 0.62) dark; Increase Contrast (0.33, 0.33, 0.35) and (0.72, 0.72, 0.75) | unpicked tool names, icons and group titles; unpicked mode names on a track; the home screen's group titles, tool card lines and privacy line; the camera-off screen's icon and line |
| Muted value | `Color.sliderMuted`: white 0.42 light, 0.60 dark; Increase Contrast 0.30 and 0.75 | a slider's value while it's at its default |
| Slider marks | `Color(.systemGray2)` | a two-way slider's middle line; the default mark |
| Disabled | text `Color(.tertiaryLabel)`; picked tile `Color(.systemGray5)`; slider tint `Color(.systemGray3)`; Save fill at 0.35 opacity | every control with `.disabled`; the whole home screen while a photo opens ("Edit a photo" fill at 0.35, like Save) |
| Close icon | `.secondary` | the top bar's neutral button; the home screen's About; the camera's Close (on a material over the picture, and on the background colour when the camera is off) |

`toolMuted` and `sliderMuted` exist because `.secondary` (#8A8A8E) is only about 3.4:1 on white, below the 4.5:1 needed for small text. The contrast results are under [Validation](#validation).

Hex values used in the mockups:

- **Light:** background #FFFFFF, grey #F2F2F7, secondary #8A8A8E, muted #6C6C70, accent #007AFF, track #E5E5EA, tick #AEAEB2, tint #D9EBFF (#DBEBFF in some of the tabs canvas's parts; the home canvas has no picked tint), disabled #C4C4C6, separator #C6C6C8.
- **Dark:** background #000000, grey #1C1C1E, secondary #8D8D93, muted #98989F, accent #0A84FF, track #39393D, tick #636366, tint #02203D, disabled #4F4F54, separator #38383A.
- **Camera canvas** (`CM_LIGHT` and `CM_DARK` in its `Main.dc.html`):
  - material rgba(246,246,248,0.84) light, rgba(30,30,32,0.80) dark, for `.regularMaterial` over the picture;
  - recording pill #D70015 with white text; record dot #FF3B30; record ring #C7C7CC light, #FFFFFF dark;
  - Compare tile while held: rgba(0,122,255,0.14) light, rgba(10,132,255,0.24) dark, on the panel;
  - looks tile while the looks show: rgba(210,228,250,0.92) light, rgba(10,132,255,0.40) dark, over the picture. The code uses `.regularMaterial` with `toolTile` on top instead;
  - disabled icons #C4C4C6 light, #4F4F54 dark on the panel; rgba(60,60,67,0.3) light, rgba(235,235,245,0.3) dark on a material.

## Typography

The font is the system font (SF Pro), always set with Dynamic Type text styles. The editor caps Dynamic Type at `.xLarge` because the tool panel is dense.

| Element | Style |
|---|---|
| Top bar: Save | `.body.weight(.semibold)`, white |
| Top bar: icons | `.system(size: 20)` |
| Tool bar: group titles | `.caption2.weight(.semibold)`, `toolMuted`, read as headers by VoiceOver |
| Tool bar: icons | `.title3`, in a 24 pt tall frame |
| Tool bar: names | `.caption2`; semibold and `.primary` when picked, otherwise `toolMuted` |
| Slider field: name and value | `.subheadline`; the value uses `.monospacedDigit()` and turns semibold and `.primary` once moved |
| Mode tabs, Face areas, chips | `.subheadline`; semibold when picked |
| Reset tile arrow | `.system(size: 18)` |
| Hints under a panel | `.footnote`, `.secondary`, at most 2 lines |
| Panel headings ("Enhanced") | `.headline` |
| Home: "Yumiro" | `.largeTitle.bold()`, a header for VoiceOver |
| Home: "Edit a photo" | `.body.weight(.semibold)`, white |
| Home: Camera and Video | `.subheadline.weight(.semibold)`, `.primary`; icons `.title3`, accent |
| Home: "Start with a tool" | `.title3.weight(.semibold)`, a header |
| Home: group titles | as the tool bar's: `.caption2.weight(.semibold)`, `toolMuted`, headers |
| Home: tool cards | name `.subheadline.weight(.semibold)`, `.primary`; line `.footnote`, `toolMuted`; icon `.title3`, accent, in a 28 pt wide frame |
| Home: privacy line | `.footnote`, `toolMuted`, after a `lock` |
| Camera: status pill | `.footnote`, `.primary` on `.regularMaterial`; while recording the time is `.monospacedDigit()`, semibold and white on `recordingTime` |
| Camera: tile icons (Close, looks, Compare, Switch) | `.system(size: 20)`, as the editor's top bar |
| Camera off: icon, title, line | `camera` at `.system(size: 40)` in `toolMuted`; "Allow the camera" `.title3.weight(.semibold)`, a header; the line `.subheadline`, `toolMuted`, centred |
| Camera off: Open Settings | `.body.weight(.semibold)`, white on the accent, like Save |

The home screen isn't capped: it scrolls, so it follows Dynamic Type all the way. The camera stays capped at `.xLarge`, as before.

Slider values show two-way ranges as −100 to +100 with a sign, using a real minus sign (−). One-way ranges show 0 to 100.

## Spacing, sizes and shape

- **Spacing scale** (`Space` in `Theme.swift`): xs 4, s 8, m 12, l 16, xl 24, xxl 32.
- **Touch targets:** every control is at least 44 pt. Rows of controls are 44 pt tall. Chips are 36 pt, and a tile inside a track is 36 pt (44 minus 4 pt of padding on each side).
- **Corner radii** (`style: .continuous` on every redesigned control; the toast and the busy badge use plain corners):

  | Radius | Used for |
  |---|---|
  | 14 | 44 pt controls: top bar buttons, slider fields, reset tiles, mode tracks, the Face area track; every home screen tile and card; the camera's Close, looks, Compare and Switch tiles and Open Settings |
  | 12 | tool bar tiles, chips |
  | 10 | the tile inside a track; toasts |

- **Editor layout, top to bottom:**
  - top bar: 52 pt tall, 12 pt side padding;
  - photo canvas: fills the rest;
  - tool panel: 16 pt sides, 12 pt top and bottom, at least 184 pt tall, rows 8 pt apart;
  - a divider;
  - tool bar: 84 pt tall.
- **Home layout, top to bottom:**
  - header: at least 52 pt tall, 16 pt side padding;
  - then a scroll view with 16 pt sides, 8 pt on top, 16 pt below, and 8 pt between its parts;
  - "Edit a photo": 52 pt;
  - Camera and Video: 52 pt, side by side;
  - "Start with a tool", 20 pt further down;
  - each group 4 pt further down: its title, 4 pt, then cards two to a row, 8 pt apart both ways, at least 60 pt tall;
  - the privacy line, 12 pt further down.
- **Camera layout, top to bottom:**
  - the picture: from the top of the screen (under the status bar's area) down to the panel;
  - over it, the top bar: 52 pt tall, 12 pt side padding, inside the safe area. One row: Close, the status, the looks tile, with at least 8 pt either side of the status;
  - the panel, on `systemBackground` down through the home indicator: 12 pt on top, the chips (36 pt), 10 pt, the slider row (44 pt), 12 pt, the record row (76 pt), 8 pt below. That's 198 pt plus the home indicator. With the looks hidden it's 12 pt, the record row and 8 pt: 96 pt plus the home indicator;
  - the record row has 16 pt side padding: Compare on the left, Record in the middle, Switch camera on the right.
- **Camera-off layout:** a `secondarySystemBackground` area from the top of the screen down to the button, with Close at the top left (12 pt in, centred in 52 pt) and the message centred with 40 pt side padding; then Open Settings, 52 pt tall, full width with 16 pt all round.
- **Press and motion:**
  - every custom button fades to 0.7 opacity while pressed;
  - a track's tile slides with `.snappy(duration: 0.25)`;
  - picked-state changes use `.easeOut(duration: 0.2)`;
  - scroll edge fades use `.easeInOut(duration: 0.2)`;
  - the camera's looks tile uses the default animation: the look controls fade, and the panel shrinks or grows.

## Components

### Top bar: "Balanced" (`ContentView.topBar`, `PhotoEditorTopBarButtonStyle`)

- **Close:** an `xmark` on the left, in a grey 44 pt tile with a `.secondary` icon. It asks before discarding edits.
- **Undo and Redo:** centred, 4 pt apart, accent icons on grey tiles.
- **Save:** on the right. White semibold text on an accent fill, at least 76 pt wide, with 17 pt side padding.
- **Disabled:** icons turn `tertiaryLabel` and Save's fill drops to 0.35. Everything is disabled while the app is busy.
- **VoiceOver order:** Close, Undo, Redo, then Save.

### Bottom tool bar: "Labelled strip" (`ContentView.toolBar`, `toolButton`; the "Tool bar" section of `Theme.swift`)

- **Layout:** one row that scrolls sideways, with three named groups:
  - **Fix:** Enhance, Adjust;
  - **Beauty:** Smooth, Retouch, Face, Warp;
  - **Remove:** Heal, Background.

  The names are `Tool.groupTitles`, shown above each group (8 pt leading inset) instead of divider lines. Groups are 12 pt apart and tools 4 pt apart. The row has 12 pt side padding, 8 pt on top and 4 pt below.
- **Tool button:** the icon over its name, 3 pt apart. At least 64 × 56 pt, with 6 pt side padding.
- **Picked tool:** sits on a `ToolTile` (radius 12, `toolTile`). Its icon is accent, and its name is semibold and `.primary`.
- **Changed dot (`ChangedDot`):** 8 pt in the accent colour, with a 2 pt ring in the colour behind it (the bar, or the tile). It sits at offset (7, −5) from the icon's top-right corner, and it also shows on the picked tool.
- **Scroll edges:** `scrollEdgeFades()` fades each end over 24 pt while there's more to scroll that way.
- **Behaviour:** picking a tool scrolls it to the centre (also on appear) and plays the selection haptic.
- **VoiceOver:** each tool reads its name plus ", changed" if it has changed the photo, and has the selected trait when picked. Group titles are headers.
- **Cost:** 84 pt tall instead of the old 66, so the photo is 18 pt shorter.

### Slider row: "Fill field" (`ContentView.sliderRow`; `ValueSlider` and the private `SliderField` in `Adjustments.swift`; `ResetButton(tile: true)` in `Theme.swift`)

- **Row:** a field and a 44 × 44 reset tile, 8 pt apart, 44 pt tall.
- **Field:** a 44 pt grey tile (radius 14) with the name on the left and the value on the right, 14 pt in from the sides. Long names shrink to 80%.
- **Fill:** a faint accent fill runs from the start of the range up to a 3 × 24 pt accent handle. On a two-way slider it runs out from the middle instead, and a 1 × 20 pt `systemGray2` line marks the middle. The handle travels between 6 pt from each end.
- **Default mark:** when the default isn't at either end (Enhance's Strength, the brush sizes), a 2 pt `systemGray2` mark on the bottom edge shows where it is.
- **Value:** shown in `sliderMuted` at the default; semibold and `.primary` once moved.
- **Drag:** a drag anywhere moves the value from where it is (`DragGesture(minimumDistance: 4)`, relative), so a touch never makes it jump, and a plain tap does nothing. A drag the system cancels still ends cleanly.
- **Catch at zero:** two-way sliders snap to 0 within 3% of half the range, with a light impact haptic.
- **Undo, ring and Strength:** one undo step per drag and per reset. Non-undoable brush sliders show the brush ring on the photo while dragging. Enhance's Strength uses its own `onEditing` and `onReset` steps.
- **VoiceOver:** reads and adjusts the field as the system `Slider`, through `accessibilityRepresentation`. The reset tile reads "Reset <name>".
- **Reset tile:** an accent arrow on a grey 44 pt tile (radius 14). It turns `tertiaryLabel` when the slider is at its default or the app is busy.
- **Scope:** `sliderRow`, which covers the photo editor's tool panels, and `LookControls`, which covers the camera and the video editor's Face panel (`20d73b0`). With no `title`, `ValueSlider` still draws the system slider, which only the Adjust panel (photo and video editors) uses now.

### Mode tabs: "Track" (`ModeTabs`, `TrackItemStyle` with `.none` backing, in `Theme.swift`)

- **Shape:** one 44 pt grey track (radius 14, `trackFill`) with 4 pt of padding inside.
- **Modes:** share the width equally. Names shrink to 75% if needed.
- **Picked mode:** a radius 10 `toolTile` tile slides under it (`systemGray5` when disabled). Its name is semibold and `.primary`; the others are `toolMuted`.
- **Used by:**
  - Heal: Spot, People, Brush, Erase;
  - Background: Blur, Remove;
  - Background's Refine row: Auto, Brush, Erase;
  - the video editor: Face, Adjust.
- **Refine's disabled state:** Refine is off until people are found (`.disabled(model.personMatte == nil)`). The text then turns `tertiaryLabel`.
- **Behaviour:** selection haptic on every change.
- **VoiceOver:** gets the original segmented `Picker` through `accessibilityRepresentation`, so it still reads "Spot, 1 of 4".

### Chips (`Chip`, `TrackItemStyle` with `.chip` backing)

- **Shape:** a 36 pt grey tile (radius 12, `trackFill`) with 14 pt side padding. The name never truncates.
- **Picked chip:** gets the `toolTile` tint on top of the grey, and its name turns semibold. Names are `.primary` on a chip's own grey.
- **Changed dot:** 6 pt in the accent colour, at the top-right corner of the name (offset 9, −1); `tertiaryLabel` when disabled. It replaced the old "•" after the name. VoiceOver reads it as the value "changed".
- **VoiceOver:** the selected trait when picked.
- **Rows:**
  - **Face subtabs:** a scrolling row, 6 pt apart.
  - **Background fills (Off, Clear, White, Black):** 8 pt apart in a 44 pt row, disabled while the app is busy.
  - **Camera looks (`LookControls`, also in the video editor's Face panel):** a scrolling row, 6 pt apart, with 16 pt side padding. Since `20d73b0` the camera's panel is solid, so the chips use the plain grey there too.
- **Behaviour:** every row plays the selection haptic.

### Face areas (`ContentView.areaTabs`, `TrackItemStyle` with `.tile` backing)

- **Shape:** the eight areas (Face, Head, Jaw, Nose, Eyes, Lips, Eyebrows, Forehead) in a 44 pt grey track that scrolls sideways. The names scroll under its rounded corners.
- **Items:** 2 pt apart. The picked area gets its own radius 10 `toolTile` tile.
- **Behaviour:** picking an area scrolls it to the centre and plays the selection haptic.
- **Changed dot:** marks an area with a slider moved on the selected face, read as "changed".
- **VoiceOver:** the selected trait when picked.
- **Panel order:** areas, then subtab chips, then the slider field. That's the tabs → chips → slider order the Mobbin references use.

### Home screen: "Tool cards" (`HomeView` and the private `HomeTileStyle` in `HomeView.swift`)

- **Header:** "Yumiro" on the left. About is on the right, an `info.circle` in a grey 44 pt tile with a `.secondary` icon, like the editor's Close. It opens the About sheet, which still offers "Show the welcome again".
- **Edit a photo:** a full-width 52 pt button, white semibold on an accent fill, like Save. It opens the photo picker with no tool picked.
- **Camera and Video:** two equal 52 pt grey tiles side by side, each an accent icon beside its name. Video's visible name is "Video", but VoiceOver reads "Edit a video" as before, and Voice Control answers to both.
- **Start with a tool:** the eight tools under the tool bar's own groups (`Tool.groups`, `Tool.groupTitles`: Fix, Beauty, Remove). Each tool is a grey card (radius 14) with its accent icon, its name and its one line (`Tool.blurb`). Both cards in a row are as tall as the taller one, so a line that wraps doesn't leave them uneven.
- **Picking a tool:** opens the photo picker, and the photo opens in that tool. Each card keeps the hint "Choose a photo to open in <tool>".
- **Privacy:** "Everything happens on this iPhone. Your photos are never uploaded." under the tools, after a lock. The text is unchanged.
- **While a photo opens:** everything is disabled, as before. Text and icons turn `tertiaryLabel`, the "Edit a photo" fill drops to 0.35 and the busy badge shows on top.
- **Press:** every tile fades to 0.7 while pressed.
- **VoiceOver order:** Yumiro (a header), About, Edit a photo, Camera, Edit a video, Start with a tool (a header), then each group title (a header) and its tools, then the privacy line. Icons inside the cards are hidden, so a card reads as its name and line.
- **Not a `NavigationStack` any more:** the header is drawn by the view, so the title doesn't shrink as the page scrolls. The Welcome and About sheets keep their own navigation bars.

### Camera: "Docked panel" (`CameraView`, `LookControls`, `CameraAccessView` and the private `CameraButtonStyle` in `CameraView.swift`)

- **Picture:** the live camera fills the screen from the top down to the panel, under the status bar's area (`ignoresSafeArea(edges: .top)`). It still fills its frame (`resizeAspectFill`), so the panel crops the picture rather than shrinking it. Recording is unaffected.
- **Hold to compare:** holding anywhere on the picture shows it without the look, as before.
- **Top bar, over the picture:**
  - **Close** on the left: a 44 pt tile (radius 14) on `.regularMaterial` with a `.secondary` `xmark`. It's disabled while recording, and the icon then turns `tertiaryLabel`.
  - **Status pill** in the middle: 32 pt tall, a capsule on `.regularMaterial`, reading "Looking for a face" or "Hold the picture to compare". While recording it turns `recordingTime` red with a white dot and the time in white semibold.
  - **Looks tile** on the right (`27ca408`): an accent `slider.horizontal.3` on a 44 pt tile. It shows and hides the look controls at any time, including while recording. It has the picked tint over `.regularMaterial` while the looks show, and plain `.regularMaterial` while they're hidden. It reads "Hide looks" or "Show looks". The choice is kept in `UserDefaults` (`@AppStorage("cameraLooksHidden")`), so the camera opens the way it was left. The change uses the default animation: the looks fade, and the picture grows into the space. It's in the top bar because that corner was empty once Switch camera moved to the record row, and a tile there mirrors Close. Unlike the options not picked, the camera never hides or shows the looks on its own.
- **Panel:** solid `systemBackground`, so it's white in light mode and black in dark, like the photo editor's tool panel. It holds `LookControls` (the chips, then the slider field and reset tile), then the record row. With the looks hidden, only the record row is left.
- **Record row:**
  - **Compare** on the left: the photo editor's compare glyph (`square.split.2x1`), accent, on a grey 44 pt tile. Holding it does the same as holding the picture, and the tile takes the picked tint while either is held. It reads "Hold to compare with the original", as in the editor, with the button trait.
  - **Record** in the middle: 76 pt, a red dot in a 4 pt `recordRing` that becomes a 30 pt square while recording. Medium impact haptic on start and stop, as before.
  - **Switch camera** on the right: an accent `arrow.triangle.2.circlepath` on a grey 44 pt tile, disabled while recording.
- **Toast:** "Saved to Photos" and other messages still show 64 pt below the top of the safe area, over the picture.
- **Camera off (`CameraAccessView`):** the same shape as the live screen. A `secondarySystemBackground` area where the picture would be holds the message (camera icon, "Allow the camera", the line), with Close on a `systemBackground` tile at the top left. Below it, where the panel would be, is a full-width 52 pt "Open Settings" in white on the accent. It follows light and dark mode; the first mockup had it black in light mode, which the user caught. The copy is unchanged.
- **VoiceOver order:** Close, the status, the looks tile, the chips, the slider field, its reset, Compare, Record, Switch camera. With the looks hidden, the chips, field and reset are gone. The labels are unchanged: "Close camera", "Switch camera", "Record" and "Stop recording", "Reset <look>". The looks tile is new: "Hide looks" or "Show looks".
- **Unchanged:** the look itself, the camera controller, the 13 looks, the record haptic, the timer, `.statusBarHidden()`, and the `.xLarge` Dynamic Type cap.
- **Shared with the video editor:** `LookControls` changed from the system slider and plain reset arrow to the fill field and reset tile, so the video editor's Face panel shows them too. Its chips and layout are otherwise the same. Hiding the looks lives in `CameraView` only, so it doesn't reach the video editor.

### Unchanged parts (not redesigned yet)

These still have their original look:

- `PanelTextButton` (system bordered, small);
- `StudioIconButton`, `HintText`, `Toast`, `BusyBadge`;
- the Face Position row's plain `ResetButton`;
- the Welcome and About sheets (system lists; the user asked to leave them as they are);
- everything under "Not built yet" below.

## Mobbin references

All references are iOS screens and patterns only.

**Bottom tool bar**

- [Apple Photos](https://mobbin.com/screens/cfdedea1-b462-42ae-b794-606e9f4ef2c0): the picked tool shown with weight, not colour alone.
- [VSCO](https://mobbin.com/screens/78fc1651-3c0b-42c5-93cf-bcd084ec7048) and [Halide](https://mobbin.com/screens/d6030ecf-e191-489a-903b-8ab937087023): short group names above the tools.
- [Google Photos](https://mobbin.com/screens/a0afe998-b52c-4db2-91a2-10ece845da10): groups as tabs on the bottom row. This informed Option 2, which wasn't picked.
- [Azar](https://mobbin.com/screens/47ec2e21-dd91-4046-b091-dd9a99baf491): a bright dot on tools that have been used.
- [Shopee](https://mobbin.com/screens/fbda85d0-d09e-4a6c-af5d-61a00f498c00) and [CapCut](https://mobbin.com/screens/3ffa0696-70f6-46d3-9303-9f6552e28768): a tile behind the picked tool, and a row cut off at the edge so it reads as scrolling.
- [Depop](https://mobbin.com/screens/2a3e86d3-c7a1-481b-adb5-7db4492358a4): a few modes shown together with no scrolling.

**Slider row**

- [VSCO](https://mobbin.com/screens/62d0dba7-72e7-4dfb-a691-a986a789b5df), [Shopee](https://mobbin.com/screens/e0a34c4b-29b8-4bdf-aced-9fb455d9aa09) and [Azar](https://mobbin.com/screens/47ec2e21-dd91-4046-b091-dd9a99baf491): no label on the slider when a tile or chip already names it.
- [Telegram](https://mobbin.com/screens/dc3a6820-6750-4363-9f63-be2ad3b6e17b) and [VSCO HSL](https://mobbin.com/screens/9b5f4b29-caa9-4443-a8dd-2900a717dd19): the label above the track in stacks of sliders; the value at the end of the row.
- [CapCut](https://mobbin.com/screens/0fce915d-55c0-45d7-b1d1-d9ce6565240e): a label on the left, which is rare.
- [Apple Photos](https://mobbin.com/screens/1eb1d98a-3c9e-4145-80e8-abb2a8ced824): the value in a ring around the tool button.
- [Meta's avatar editor](https://mobbin.com/screens/267cb0c8-2255-4ab8-aac1-658606ec4b53) and [Halide](https://mobbin.com/screens/a0c1c665-0576-435e-af2b-20bf9ac03972): two-way sliders that fill out from a centre mark.
- [Shopee](https://mobbin.com/screens/fbda85d0-d09e-4a6c-af5d-61a00f498c00): a dot marking a default that isn't at the start.
- [Depop](https://mobbin.com/screens/6ddbe876-edc9-4d7b-ba12-90646da8aa7f): tabs, then chips, then the slider.

**Mode tabs and chips**

- [Depop](https://mobbin.com/screens/6ddbe876-edc9-4d7b-ba12-90646da8aa7f): a segmented control for 2 or 3 short modes.
- [CapCut](https://mobbin.com/screens/0fce915d-55c0-45d7-b1d1-d9ce6565240e) and [Unfold](https://mobbin.com/screens/e32f526c-2d35-40d4-b0b1-a70bd5e1183c): text tabs with an underline; CapCut also has Brush/Erase tiles.
- [Shopee's beauty camera](https://mobbin.com/screens/328ab298-7eb2-4525-b60e-27fb311d3a30): icon-and-label tiles with the picked one highlighted.
- [Google Photos](https://mobbin.com/screens/7b06c8c8-7a19-4e32-9c34-89092bdb72d7): two opposite modes (Add, Subtract) as a pair of pills.
- [Instagram's avatar editor](https://mobbin.com/screens/adbe0d6b-fdf6-4e81-8acd-a2148454d069): tabs on top and chips below, both running off the edge.
- [Lovi](https://mobbin.com/screens/e6316517-0b99-428f-a07c-93cf5e8be244): the picked chip gets a fill and heavier text.
- [CapCut](https://mobbin.com/screens/b7019626-a811-45c9-8a49-9024827b99c3): swatches on visual choices, with ⊘ for "none".
- [Azar](https://mobbin.com/screens/8f295b8c-0d6e-4715-879d-af53d7f8352d): a small coloured dot at the top-right of changed features.

**Home screen** (Photoroom's screens came up too, but it's on the clean-room list, so they were left out)

- [CapCut](https://mobbin.com/screens/58984ebf-3e01-469c-ae98-a8e1caec2fdd): a grid of grey tool tiles and one wide "New project" card; a gear for settings at the top right.
- [Riveo](https://mobbin.com/screens/30efe1fe-9e74-4d1e-a28c-746a1c6e8d2b): Camera in the tool grid beside New Project, as an equal.
- [VSCO's Studio](https://mobbin.com/screens/231f539d-9f24-4171-89ba-7312b1ddf76a): photo, video and camera as three icons at the top. This informed Option 2, which wasn't picked.
- [ElevenLabs](https://mobbin.com/screens/d4c0f005-93d8-47de-9950-5e01a459547e): a large title, then one full-width "Create new" button, then media types as chips.
- [GoPro Quik](https://mobbin.com/screens/a7b97370-8ff9-49c3-8a5f-dad957779bfa) and [Unfold](https://mobbin.com/screens/39d92183-a69b-4051-957f-bf50871e95f3): an empty screen with one call to action, and an empty canvas to add media to. These informed Option 3, which wasn't picked.
- [Halide](https://mobbin.com/screens/5ea10830-e17f-4a58-aa6e-2b57c9d2ed2d): rows with an icon, a name and one line under it; About in an Info group.
- [Kino](https://mobbin.com/screens/833b6ee7-ed75-41ce-8c0b-864f74d35170): About as its own page with the version and credits, like Yumiro's About sheet.
- [Tinder](https://mobbin.com/screens/becb7eec-eeb1-4c0f-b919-693966caadfc) and [Any Distance](https://mobbin.com/screens/889d3bc2-59f3-46c0-b955-9737cbadb2b7): "everything stays on your device" said where photos are picked, or a privacy promise in settings. No home screen found leads with privacy.
- [Mammoth](https://mobbin.com/screens/67aadc4a-6db0-4eae-8d11-4e288bb46069): the system photo picker's own "Private Access to Photos" card, which Yumiro's picker shows too.

**Camera**

- [Azar](https://mobbin.com/screens/8f295b8c-0d6e-4715-879d-af53d7f8352d) and [Shopee](https://mobbin.com/screens/328ab298-7eb2-4525-b60e-27fb311d3a30): a solid panel docked under the picture, holding icon-over-name tiles with dots on the changed ones; the slider sits just above the panel. This informed Option 2, which was picked, and Option 3.
- [Azar](https://mobbin.com/screens/8f295b8c-0d6e-4715-879d-af53d7f8352d) and [Snapchat](https://mobbin.com/screens/e3488f3d-632c-46cc-b84f-867d3a9de1e8): a compare button you can see, at the end of the slider row. [Ulta](https://mobbin.com/screens/9c30ff40-ccc1-4834-a6cc-85c50df0c19d) puts "Before & After" in a menu.
- [WhatsApp](https://mobbin.com/screens/9072cfbe-c1b2-4915-9d90-9a2badd12f72), [Messages](https://mobbin.com/screens/870439ce-b80c-4e24-80a0-9f34a588e51e) and [Edits](https://mobbin.com/screens/0158dcd6-1cdc-4261-8d30-d6e136f3076a): the recording time as a red pill at the top centre; WhatsApp and Edits put Switch camera beside the record button.
- [CapCut](https://mobbin.com/screens/6bfe7a64-4cfc-4654-ba90-01141600ee7c): the time just above the record button. [Snapchat](https://mobbin.com/screens/ca8f9728-a151-41d6-8b67-70fc8bbc46d1): a progress ring around it.
- [WhatsApp](https://mobbin.com/screens/7a8660b8-5db6-4c68-ad9f-8c325f86b177) and [Instagram](https://mobbin.com/screens/0c243e80-dd7c-4dc7-91fa-922dfe9b9d1c): "Find a face" as a small pill under the top bar, or as text in the middle.
- [Klarna](https://mobbin.com/screens/e79dc9e0-830c-460d-bd79-1e1fc419ab4c), [PlayStation](https://mobbin.com/screens/b27fac9f-381a-46f3-b761-47922ba43290) and [Meetup](https://mobbin.com/screens/a98bbd1f-2f2e-4d74-a207-77c78a8caaf7): camera access off as an icon, one line on why, and one filled button; Klarna pins it full width at the bottom, and Meetup keeps the message where the camera would be.

**Camera: hiding the looks**

- [YouTube](https://mobbin.com/screens/7a1782bb-1c65-4189-9bb0-93659f06dcff) and [CapCut](https://mobbin.com/screens/e153aa06-2595-4a2a-8138-1381dd3e02c1): the camera's tool list folds away with a chevron at its end.
- [Apple Notes](https://mobbin.com/screens/5e6cda9b-51d4-4347-ab57-13915ab5b49c) and [Freeform](https://mobbin.com/screens/37982b5b-a2f8-4595-b35b-7ecc72046b24): Flash, Filters and Shutter above the shutter, with a choice's options opening only when asked for.
- [WhatsApp](https://mobbin.com/screens/1799c88c-0d6b-4086-a3e1-37d531eb0a63), [Ulta](https://mobbin.com/screens/134b3b54-9842-43b1-b16f-a5e683b08e9b) and [Oura](https://mobbin.com/screens/15ea5364-e8dd-4c98-8144-d52f9975c671): a grab handle on the panel under the camera. This informed Option 3, which wasn't picked.
- [Edits](https://mobbin.com/screens/317f2d7c-955e-431d-8ca7-25fe302a2558): the camera's tools as a short column at the side, out of the way of the picture.

## Proposed but not picked

These are on the canvases, but they're not approved. Don't build them unless the user picks one.

- **Tool bar, Option 2 "Group tabs":** Fix, Beauty and Remove as bottom tabs, with the group's tools spread above them. 100 pt tall.
- **Slider row, Option 1 "Tuned inline":** today's layout with the new track, value and reset.
- **Slider row, Option 2 "Label on top":** the name and value on a line above a full-width track. About 14 pt taller per slider.
- **Tabs, Option 2 "Tabs and pills":** text tabs with an accent underline; outlined pills.
- **Tabs, Option 3 "Tool tiles":** icon-over-name mode tiles like the tool bar; swatches on the Background fills.
- **Home, Option 2 "Tiles and rows":** Photo (accent fill), Camera and Video as three equal 92 pt tiles; the tools as grouped 48 pt rows with the line on the right and a chevron.
- **Home, Option 3 "Editor start":** the editor with no photo yet. A grey area holds "Edit a photo", Camera, Video and the privacy line, and the labelled-strip tool bar sits along the bottom. The tools' lines aren't shown.
- **Camera, Option 1 "Glass card"** (`Option1.dc.html`): the old layout over a full-screen picture, with Close and Switch as 44 pt material tiles, the look card at radius 14 with the fill field, and a centred camera-off screen with a 52 pt Open Settings.
- **Camera, Option 3 "Look strip"** (`Option3.dc.html`): the 13 looks as a labelled strip like the tool bar (Skin, Head, Features, Retouch) under the fill field on a solid panel, with the record button and a Compare tile over the picture, and Open Settings pinned to the bottom of a plain camera-off screen.
- **Hiding the looks, Option 1 "Fold while recording"** (`Hide1.dc.html`): no new control; the looks fold away when recording starts and come back when it stops.
- **Hiding the looks, Option 3 "Handle"** (`Hide3.dc.html`): a grab handle at the top of the panel folds the looks (tap or swipe down), and they also fold by themselves while recording unless they were already folded. The handle takes about 14 pt from the picture.

## Not built yet

**Remaining part:** the video editor. It hasn't been researched or mocked up. Its Face panel already has the new look controls through `LookControls`.

**Leftovers in the old style, to settle when their part comes up:**

- **Adjust panel** (`AdjustPanel` in `Adjustments.swift`, used by the photo editor's Adjust tool and the video editor). It keeps:
  - the system slider;
  - a plain `ResetButton` in its header;
  - its own tool row: accent icon over a `.caption2` name, a 6 pt `.secondary` changed dot, and no tile.

  It doesn't match the labelled strip, the fill field or the chips.
- **Panel buttons:** `PanelTextButton` (Reset all, Clear, Add shadow, Remove, Turn off) is still the system bordered style, which no new part uses.
- **Changed dots:** there are three sizes. The tool bar uses 8 pt with a ring, chips and tracks use 6 pt accent, and the Adjust row uses a 6 pt grey dot.

**No photo button on the camera.** It only records video. The user asked to hide the settings "when recording/taking picture"; the looks tile covers recording. Taking photos from the camera would be a part of its own, and nothing has been designed for it.

**Known flaw:** commit `62567b2`'s message has no blank line after its subject, so `git log --oneline` shows it as one long line. Fixing it needs a force-push, so leave it.

## Validation

**Builds and tests:**

- **Nothing in ui-b has been compiled.** This PC can't build, and the user hasn't reported a build result for `62567b2`, `b3f53c5`, `575d86a`, `6da010a`, `33ded13`, `0c2c9bc`, `f52f7c1`, `20d73b0` or `27ca408` yet.
- **Each change was reviewed by reading the diff** for Swift and SwiftUI correctness. Every API used is available on iOS 18, the deployment target.
- **The tests in `PhotoStudioTests`** (`EditorRegressionTests`, `VideoLookTests`) cover editing, undo and video looks, not these views. `TESTING.md` explains how to run them on a Mac.
- **Mockups:** the home canvas was published without a render check by the session that made it. The user has looked at it and picked from it. The home screen in ui-b follows `Home1.dc.html` value for value, apart from one fix: the card rows were 4 pt apart in the first build and are 8 pt now (`f52f7c1`).
- **Camera mockups:** published without a render check (the canvas needs a claude.ai sign-in the session's browser didn't have). The user looked at it, picked Option 2, and caught that its camera-off screen was black in light mode; that was fixed on the canvas before the build. The camera in ui-b follows `Option2.dc.html`. The one difference: the Compare tile reads "Hold to compare with the original", the photo editor's label, rather than the mockup's "Compare with the original".
- **Hiding the looks:** the "Hide the looks" page was also published without a render check. The user picked Option 2. ui-b follows `Hide2.dc.html`, apart from the panel's heights: the mockup's panel is 230 pt with the looks and 130 pt without, and the code's is 198 and 96 pt plus the home indicator, as before. The tile's tint is also drawn differently (see the camera canvas's hex values above).

**Contrast**, calculated with the WCAG formula from the colour values above. The `toolMuted` and `sliderMuted` rows are text and need 4.5:1. The picked tool's accent icon is a graphic and needs 3:1.

| Foreground on background | Ratio |
|---|---|
| `toolMuted` on white (tool bar, light) | 5.29 |
| `toolMuted` on black (tool bar, dark) | 7.41 |
| `toolMuted` on #F2F2F7 (a track, light) | 4.74 |
| `toolMuted` on #1C1C1E (a track, dark) | 6.00 |
| `sliderMuted` on #F2F2F7 (slider field, light) | 4.77 |
| `sliderMuted` on #1C1C1E (slider field, dark) | 5.97 |
| `.secondary` #8A8A8E on white (the old labels) | 3.44 |
| Accent icon on the picked tile, light | 3.35 |
| Accent icon on the picked tile, dark | 4.52 |
| `.primary` text on the picked tile | 12.5 or more |
| Accent icon on #F2F2F7 (home tiles and cards, light) | 3.60 |
| Accent icon on #1C1C1E (home tiles and cards, dark) | 4.67 |
| White text on the accent (Save, "Edit a photo"), light | 4.02 |
| White text on the accent (Save, "Edit a photo"), dark | 3.65 |
| White text on `recordingTime` #D70015 (the camera's recording time) | 5.38 |
| White text on system red #FF3B30 (not used: why the time has its own red) | 3.55 |
| Red record dot #FF3B30 on the white panel | 3.55 |
| `recordRing` #C7C7CC on the white panel | 1.68 |
| Accent icon on the held Compare tile | the picked tile's 3.35 light, 4.52 dark |
| Accent looks icon on the tinted material, light: over white, a mid-tone picture, black | about 3.2, 2.8, 2.2 |
| Accent looks icon on the tinted material, dark: over white, a mid-tone picture, black | about 2.0, 2.6, 3.6 |
| Accent looks icon on the plain material (looks hidden), light: over white, a mid-tone picture, black | about 3.8, 3.2, 2.6 |
| Accent looks icon on the plain material (looks hidden), dark: over white, a mid-tone picture, black | about 2.4, 3.3, 4.9 |
| `.secondary` Close icon on the material, light: over white, a mid-tone picture, black | about 3.4, 3.2, 2.9 |
| `.secondary` Close icon on the material, dark: over white, a mid-tone picture, black | about 3.8, 4.8, 6.1 |

The tool cards' lines use `toolMuted` on the grey, so they get the track rows' 4.74 and 6.00, and so does the camera-off line. The record ring is faint on the light panel, but the red dot inside it clears the 3:1 a graphic needs, so the button still reads. White on the accent is below 4.5:1 for 17 pt text. Save already had that, and it's how the system's own filled buttons look, so it's recorded here rather than changed.

The camera's material rows are estimates. They treat `.regularMaterial` as the canvas's flat colour (light rgba(246,246,248,0.84), dark rgba(30,30,32,0.80)) over plain white, the canvas's mid-tone picture (#8E9A8B) or black. The real material blurs and adds vibrancy, so the phone will differ. They suggest the looks tile's accent icon can fall below 3:1: in light mode over dark pictures, in dark mode over bright ones, and over mid-tone ones too while it's tinted. Close's `.secondary` icon dips just under 3:1 only in light mode over a dark picture. That is to check on the phone before deciding anything. If it's hard to see, ways to fix it: a `.primary` icon while the tile is tinted, or `.thickMaterial`. Nothing has been changed for it.

**Layout arithmetic** (from the code, not measured on a device):

- **Video editor controls:** they need about 227 of their 236 pt with the 44 pt mode track and the Adjust panel. Very large text could make that tight.
- **Taller panels:** the Face panel grows about 20 pt (areas 44 pt instead of 32, chips 36 instead of 28). Heal and Background grow about 12 pt for each mode track.
- **Background fills:** the four fills fit across a 375 pt phone (343 pt inside the panel).
- **Home screen:** the header and content are about 630 pt tall at the default text size. That fits a 390 × 844 phone with room to spare. On a 375 × 667 phone it's about the height of the screen, so it may scroll a little, and larger text scrolls.
- **Tool card text:** on a 390 pt phone the name and line get about 113 pt across, and about 105 pt on a 375 pt phone. So "Reshape features" and "Teeth, eyes, tone" may wrap to two lines on the smaller phone or with larger text.
- **Camera panel:** 198 pt plus the home indicator. On a 390 × 844 phone the picture shows about 612 pt of height above it; on a 375 × 667 phone, about 469 pt. With the looks hidden the panel is 96 pt, so the picture shows about 714 pt and 571 pt. The panel only grows with Dynamic Type up to the `.xLarge` cap.
- **Camera top bar:** the status gets about 262 pt between the tiles on a 390 pt phone and 247 pt on a 375 pt phone. "Hold the picture to compare" needs about 200 pt at the default size, so it fits; at the `.xLarge` cap it may come close on the smaller phone.
- **Video editor Face panel:** the look controls are 90 pt tall (36 pt chips, 10 pt, 44 pt field), as the system slider row was, so the Face panel needs about 166 of its 236 pt.

**Still to check on the phone:**

- **Tool bar:** where the dot sits on each icon; the edge fades as you scroll; the tile in dark mode.
- **Slider fields:** how a drag feels (it's a custom control); the click at zero on Face's two-way sliders; Enhance's Strength applying when you lift your finger.
- **Tracks:** the tile slide; the Face area track scrolling under its corners; the Refine track while disabled.
- **Camera:**
  - how much of the picture shows above the panel, and that the face still sits well in it;
  - holding the picture and holding the Compare tile, and the tile's tint while either is held;
  - the record ring in light mode, and the red time pill while recording;
  - Close and Switch greyed out while recording;
  - the "Saved to Photos" toast clearing the top bar;
  - the camera-off screen in light and dark mode (turn off camera access in Settings to see it);
  - the looks tile: the looks fading in and out, the picture growing without a jump (the camera layer resizes on its own), the tint over the picture, hiding while recording, and the camera opening hidden after it was closed hidden;
  - the status pill between Close and the looks tile at the largest text size;
  - the looks tile's icon and Close's icon against a bright background and a dark one, in light and dark mode.
- **Video editor:** the Adjust panel's fit; the fill field and reset tile in the Face panel.
- **Home screen:**
  - both cards in a row staying the same height when a line wraps;
  - the greyed-out look while a photo opens;
  - VoiceOver reading each card as its name and line, then the hint;
  - the About sheet and "Show the welcome again".

## Where things live

| Thing | File and symbol |
|---|---|
| Colours, spacing, buttons, mode tabs, chips, tool bar parts | `PhotoStudio/Theme.swift`: `Space`, `Color.sliderMuted`, `Color.trackFill`, `ModeTabs`, `Chip`, `TrackItemStyle`, `ResetButton`, `Color.toolMuted`, `Color.toolTile`, `ToolTile`, `ChangedDot`, `scrollEdgeFades` |
| Editor layout, top bar, tool bar, panels, slider row, Face areas | `PhotoStudio/ContentView.swift`: `editor`, `topBar`, `PhotoEditorTopBarButtonStyle`, `toolBar`, `toolButton`, `toolPanel`, `areaTabs`, `subtabChips`, `sliderRow`, `Tool.groups`, `Tool.groupTitles` |
| Slider field, Adjust panel | `PhotoStudio/Adjustments.swift`: `ValueSlider`, `SliderField`, `AdjustPanel` |
| Camera screen, camera-off screen, look controls (shared with video) | `PhotoStudio/CameraView.swift`: `CameraView`, `CameraAccessView`, `LookControls`, `CameraButtonStyle`, `Color.recordingTime`, `Color.recordRing`; the looks tile's `cameraLooksHidden` setting |
| Video editor controls | `PhotoStudio/VideoEditView.swift`: `controls` |
| Home screen (the Welcome and About sheets are in the same file, unchanged) | `PhotoStudio/HomeView.swift`: `HomeView`, `HomeTileStyle` |
| Install a branch on the phone | `tools/install_variant.sh b` (run on the Mac) |
