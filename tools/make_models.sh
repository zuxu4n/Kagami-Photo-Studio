#!/bin/sh
# Downloads the three open models, converts them to Core ML and puts them in PhotoStudio/Models.
#   python3 -m venv .venv && .venv/bin/pip install -r tools/models/requirements.txt
#   PYTHON=.venv/bin/python tools/make_models.sh [sample.jpg]
# Every download is checked against a SHA-256. With a sample photo, each converted model is compared with the
# original PyTorch model on a crop of it. Downloads and intermediate files stay in tools/models/cache (git ignores it).
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
py="${PYTHON:-python3}"
cache="$here/tools/models/cache"
out="$here/PhotoStudio/Models"
sample="$1"
mkdir -p "$cache" "$out"

fetch() {  # url file sha256
    if [ ! -f "$cache/$2" ] || ! echo "$3  $cache/$2" | shasum -a 256 -c -s; then
        curl -fL --retry 3 -o "$cache/$2" "$1"
    fi
    echo "$3  $cache/$2" | shasum -a 256 -c
}

# Real-ESRGAN realesr-general-x4v3 (BSD-3-Clause)
fetch https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth \
    realesr-general-x4v3.pth 8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292
# MediaPipe Face Landmarker float16/1 (Apache-2.0); only its Face Mesh V2 landmark model is used
fetch https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task \
    face_landmarker.task 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff
# LaMa big-lama (Apache-2.0): weights, plus LaMa's network code at a pinned commit
fetch https://huggingface.co/smartywu/big-lama/resolve/main/big-lama.zip \
    big-lama.zip f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6
lama=https://raw.githubusercontent.com/advimman/lama/786f5936b27fb3dacd2b1ad799e4de968ea697e7
mkdir -p "$cache/lama_src"
for f in ffc base squeeze_excitation; do
    curl -fsL --retry 3 -o "$cache/lama_src/$f.py" "$lama/saicinpainting/training/modules/$f.py"
done
curl -fsL --retry 3 -o "$cache/lama_src/LICENSE" "$lama/LICENSE"

rm -rf "$cache/facemesh" "$cache/big-lama"
unzip -oq "$cache/face_landmarker.task" face_landmarks_detector.tflite -d "$cache/facemesh"
unzip -oq "$cache/big-lama.zip" -d "$cache"

rm -rf "$out/RealESRGANGeneralX4.mlpackage" "$out/FaceMesh.mlpackage" "$out/LamaInpaint.mlpackage" "$cache/lama_parts"
"$py" "$here/tools/models/esrgan.py" "$cache/realesr-general-x4v3.pth" "$out/RealESRGANGeneralX4.mlpackage" $sample
"$py" "$here/tools/models/facemesh.py" "$cache/facemesh/face_landmarks_detector.tflite" "$out/FaceMesh.mlpackage"
"$py" "$here/tools/models/lama.py" "$cache/big-lama/models/best.ckpt" "$cache/lama_src" "$cache/lama_parts" \
    "$out/LamaInpaint.mlpackage" $sample
echo "models are in $out"
