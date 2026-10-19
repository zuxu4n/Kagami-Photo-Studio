# PhotoStudio (prototype)

A free, open-source, on-device photo editor for iPhone. Everything runs on the phone: there is no network code at all.

Prototype v0.1 (one screen):
- **Enhance ×4**: Real-ESRGAN general-x4v3 (Core ML, 512 px tiles, Neural Engine + GPU). The input long side is capped at 1024 px, so output is up to 4096 px.
- **Smooth**: edge-preserving skin smoothing (Metal), limited to a face-skin mask built from Apple Vision landmarks, so eyes, brows, lips and moles stay sharp.
- **Heal**: tap a spot to remove it. LaMa big-lama (Core ML, 512 px working size) runs on CPU + GPU (the Neural Engine compile takes minutes for this model).
- **Face**: slim face, bigger eyes and slim nose from Apple Vision's 76 landmarks; jaw, chin, lips, smile and forehead from MediaPipe Face Mesh V2's 478 landmarks (Vision finds each face, then the mesh runs on an upright 256 px crop of it, twice, as MediaPipe's tracking does). All are local Metal warps.
- Hold to compare; save to Photos (add-only permission).
- Each tool's time is shown on screen and appended to `Documents/timings.json` in the app container.

## Clean room

Everything here is written from scratch. No code, models, presets or assets come from Facetune, Remini, Photoroom, Meitu or BeautyPlus. The competitor study in `../study` only informed which features to build and the quality bar.

## Models

| File | Source | Licence | Notes |
|---|---|---|---|
| `PhotoStudio/Models/RealESRGANGeneralX4.mlpackage` | xinntao/Real-ESRGAN `realesr-general-x4v3.pth` | BSD-3-Clause | Converted with coremltools 9, FP16 |
| `PhotoStudio/Models/LamaInpaint.mlpackage` | advimman/lama `big-lama` | Apache-2.0 (check the weights' terms before shipping) | FP16, with BatchNorm folded to scale and shift (raw FP16 BatchNorm overflows) |
| `PhotoStudio/Models/FaceMesh.mlpackage` | Google MediaPipe `face_landmarker.task` (float16/1), its `face_landmarks_detector.tflite` (Face Mesh V2) | Apache-2.0 (model card: "Licensed under Apache License, Version 2.0") | Converted without TensorFlow by `../speedtest/scripts/convert_facemesh.py` (reads the TFLite file, runs its graph in PyTorch, coremltools 9, FP16); landmarks within 0.1 px of the original. The bundle's BlazeFace detector and blendshape model aren't used. |

The models are not committed to git (LaMa is about 100 MB). They come from the conversion scripts in `../speedtest/scripts`; copy them in with `tools/copy_models.sh`.

## Build

This Mac account isn't an administrator, so the Xcode tools are selected per command instead of with `xcode-select`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project PhotoStudio.xcodeproj -scheme PhotoStudio -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
```

The shared scheme runs Release with the debugger off: attaching a debugger needs an admin password on this Mac. Metal kernels are compiled on the device at first use (`ShaderSource.swift`), so Xcode's optional Metal Toolchain isn't needed.
