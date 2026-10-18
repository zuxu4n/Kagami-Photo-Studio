#!/bin/sh
# Copies the converted Core ML models from the speed-test workspace into the app target.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/../speedtest/models"
mkdir -p "$here/PhotoStudio/Models"
cp -R "$src/realesr_general_x4v3_512.mlpackage" "$here/PhotoStudio/Models/RealESRGANGeneralX4.mlpackage"
cp -R "$src/lama_512.mlpackage" "$here/PhotoStudio/Models/LamaInpaint.mlpackage"
echo "models copied"
