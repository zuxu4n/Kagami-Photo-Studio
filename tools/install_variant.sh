#!/bin/sh
# Builds one UI variant and installs it on the iPhone as its own app, next to the others.
#   tools/install_variant.sh a      # branch ui-a in ../yumiro-ui-a, installed as "Yumiro A"
#   tools/install_variant.sh b      # branch ui-b in ../yumiro-ui-b, installed as "Yumiro B"
# Run it from this checkout (the one with the models and Local.xcconfig). The first time it makes the variant's
# worktree from the branch on GitHub; after that it pulls the branch's newest commits. Models and Local.xcconfig,
# which git doesn't carry, are copied in when missing. The bundle ID (com.zuxu4n.photostudio.<letter>) and the home
# screen name are set on the command line, so nothing in the project changes. With several phones connected, pick
# one with DEVICE=<identifier from `xcrun devicectl list devices`>.
set -e
letter="$1"
[ -n "$letter" ] || { echo "usage: $0 <letter>   (for example: $0 a)"; exit 1; }
here="$(cd "$(dirname "$0")/.." && pwd)"
branch="ui-$letter"
dir="$(dirname "$here")/yumiro-ui-$letter"
name="Yumiro $(echo "$letter" | tr '[:lower:]' '[:upper:]')"

git -C "$here" fetch origin "$branch"
if [ -d "$dir" ]; then
    git -C "$dir" pull --ff-only origin "$branch"
else
    git -C "$here" worktree add "$dir" "$branch"
fi
[ -f "$dir/Local.xcconfig" ] || cp "$here/Local.xcconfig" "$dir/"
mkdir -p "$dir/PhotoStudio/Models"
for m in "$here"/PhotoStudio/Models/*.mlpackage; do
    [ -e "$dir/PhotoStudio/Models/$(basename "$m")" ] || cp -R "$m" "$dir/PhotoStudio/Models/"
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$dir"
xcodebuild -project PhotoStudio.xcodeproj -scheme PhotoStudio -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates \
    PRODUCT_BUNDLE_IDENTIFIER="com.zuxu4n.photostudio.$letter" INFOPLIST_KEY_CFBundleDisplayName="$name" build

if [ -z "$DEVICE" ]; then
    list="$(mktemp)"
    xcrun devicectl list devices --json-output "$list" >/dev/null
    DEVICE="$(plutil -extract result.devices.0.identifier raw "$list")"
    rm -f "$list"
fi
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Release-iphoneos/PhotoStudio.app
echo "Installed $name ($branch at $(git rev-parse --short HEAD))"
