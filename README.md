# Yumiro (prototype)

A free, open-source, on-device photo editor for iPhone. Everything runs on the phone: there is no network code at all.

Prototype v0.1. The home screen opens a photo (straight into a tool, if one is picked), the camera or a video. Needs iOS 18.

### Photo editor

Eight tools in three groups: fix and frame (Enhance, Adjust), beauty (Smooth, Retouch, Face, Warp), remove and replace (Heal, Background). Every change can be undone and redone, pinch and two-finger drag zoom and move the photo, hold the Compare button to see the original, and Save adds a full-size copy to Photos (add-only permission).

- **Enhance**: Real-ESRGAN general-x4v3 (Core ML, 512 px tiles, shared between a Neural Engine copy and a GPU copy). The result is never smaller than the photo and is enlarged up to 4× while it stays within 12.6 MP (4× for a typical selfie, 1× for a 12 MP photo); a photo that needs more than 20 tiles runs on a half-size copy. On faces only the model's small changes are kept (noise cleaning and fine sharpening), so it never redraws them. A Strength slider fades between the photo and the enhanced one, and Enhance can be turned off again (spots healed since are healed again on the photo as it was).
- **Adjust**: crop (Free or a fixed shape, with a frame to drag and resize), turn, flip both ways, straighten, brightness, contrast, saturation and warmth (Core Image).
- **Smooth**: edge-preserving skin smoothing (Metal), limited to a face-skin mask built from Apple Vision landmarks, so eyes, brows, lips and moles stay sharp.
- **Retouch**: whiten teeth, brighten eyes and even skin tone, per face (colour only; Metal).
- **Face**: over 30 sliders in eight areas (face, head, jaw, nose, eyes, lips, eyebrows, forehead), each face with its own values, plus Position, an oval dragged around the head to turn it. Jawline and eye size use Apple Vision's 76 landmarks; the rest use MediaPipe Face Mesh V2's 478 landmarks (Vision finds each face, then the mesh runs on an upright 256 px crop of it, twice, as MediaPipe's tracking does). All are local Metal warps.
- **Warp**: drag on a face to push it by hand, with a brush size and strength; the pushes stay under the Face sliders.
- **Heal**: Spot: tap a spot to remove it (LaMa big-lama at 512 px, CPU + GPU; the Neural Engine compile takes minutes for this model). People: tap a person to outline them (Apple's on-device person instance cutout, split between faces when Vision joins people who touch), tap again to remove. Brush and Erase paint the selection; Add shadow adds the dark area joined to its lower half. Removal works on a crop around each area with LaMa's 1024 function (about a third of full size for a standing person on a 12 MP photo, instead of a sixth), then the fill's finest detail is replaced by patches of the surrounding background's own grain (`ObjectRemoval.swift`).
- **Background**: blur what's behind the people like a lens (Metal, with the background filled in behind them so their colours don't glow), or remove it: see-through (saved as PNG), white or black. Brush and Erase fix the people's outline by hand.

### Camera and video

- **Camera**: films with Smooth, Retouch and the face shape drawn live on every frame (faces tracked from frame to frame, the same Metal kernels as the editor), front or back camera, with sound. Hold the picture to compare.
- **Video**: the same look on a video from Photos, plus Adjust (crop, turn, light and colour). Saves a new HEVC copy with its sound to Photos.

### Timings

Each tool's time and memory use is appended to `Documents/timings.json` in the app container, and the camera's frame rate to `Documents/camera_timings.json` (the last 5,000 entries of each), for collection over USB. Test builds launched with the argument `EnhanceBench` or `RemoveBench` time Enhance or removal on the phone (see `EnhanceBench.swift` and `EditorModel+Remove.swift`).

## Clean room

Everything here is written from scratch. No code, models, presets or assets come from Facetune, Remini, Photoroom, Meitu or BeautyPlus. A study of those apps only informed which features to build and the quality bar; none of it is in this repository.

## Models

| File | Source | Licence | Notes |
|---|---|---|---|
| `PhotoStudio/Models/RealESRGANGeneralX4.mlpackage` | xinntao/Real-ESRGAN `realesr-general-x4v3.pth` | BSD-3-Clause | Converted with coremltools 9, FP16 (`tools/models/esrgan.py`) |
| `PhotoStudio/Models/LamaInpaint.mlpackage` | advimman/lama `big-lama` | Apache-2.0 (check the weights' terms before shipping) | FP16, with BatchNorm folded to scale and shift (raw FP16 BatchNorm overflows). One multifunction package: `main` at 512 and `lama1024`, sharing one copy of the weights (`tools/models/lama.py`). Needs iOS 18. |
| `PhotoStudio/Models/FaceMesh.mlpackage` | Google MediaPipe `face_landmarker.task` (float16/1), its `face_landmarks_detector.tflite` (Face Mesh V2) | Apache-2.0 (model card: "Licensed under Apache License, Version 2.0") | Converted without TensorFlow by `tools/models/facemesh.py` (reads the TFLite file, runs its graph in PyTorch, coremltools 9, FP16); landmarks within 0.1 px of the original. The bundle's BlazeFace detector and blendshape model aren't used. |

The models are not committed to git (LaMa is about 100 MB). Make them on a Mac with Python 3.12:

```sh
python3 -m venv .venv && .venv/bin/pip install -r tools/models/requirements.txt
PYTHON=.venv/bin/python tools/make_models.sh path/to/any-photo.jpg
```

This downloads the original weights from their authors (about 370 MB, each checked against a SHA-256), converts them and writes the three packages to `PhotoStudio/Models`. The photo is optional: with it, each converted model is compared with the original PyTorch model on a crop of it and the PSNR is printed. LaMa takes the longest, several minutes.

## Build

Put your Apple team ID in `Local.xcconfig` (git ignores it; see `Signing.xcconfig`), then build. `DEVELOPER_DIR` picks Xcode without changing `xcode-select`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project PhotoStudio.xcodeproj -scheme PhotoStudio -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
```

The shared scheme runs Release with the debugger off: so it runs at full speed on the phone. Metal kernels are compiled on the device at first use (`ShaderSource.swift`), so Xcode's optional Metal Toolchain isn't needed.

See [TESTING.md](TESTING.md) for regression tests and device checks.

To try two designs side by side, `tools/install_variant.sh a` builds the branch `ui-a` and installs it as its own app, "Yumiro A" (and `b` makes "Yumiro B"), so the variants don't replace each other on the phone.
