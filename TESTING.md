# Regression checks

On a Mac with Xcode, open `PhotoStudio.xcodeproj`, select an iPhone simulator with iOS 18 or later, and run Product > Test. The shared PhotoStudio scheme includes PhotoStudioTests. These tests use a small generated photo and do not require downloaded model weights.

For the command line, choose an available simulator ID from `xcrun simctl list devices available`, then run:

```sh
xcodebuild -project PhotoStudio.xcodeproj -scheme PhotoStudio -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" test
```

The automated cases cover automatic smoothing and undo/redo, photo closure invalidating background work and releasing state, overlapping edit operations, and independent export settings.

Check these device flows with the converted models installed:

- Open a photo directly in Smooth. Close must ask about unsaved edits; Undo restores Strength to zero, and Redo restores the default.
- Start finding people in Background, close the photo before it finishes, then open another photo. The old cutout must never appear on the new photo. Repeat after painting a background correction.
- While saving or enhancing a photo, attempt to move sliders and paint. The operation must finish with the settings selected before it began.
- On a fresh camera permission prompt, dismiss the camera before responding. Granting permission afterward must not start capture. Open it again and confirm it still works.
- Change a video's crop and quarter turn rapidly while paused, then save immediately. Preview and export must use the final crop and orientation. Hold to compare, then tap Save with another finger; the exported video must retain its effects.
- Deny Photos access and try saving a video. The app should report the permission issue without exporting a temporary movie. Retry after granting access in Settings.

Swift syntax and Xcode project structure can be inspected on Windows. Building, running XCTest, and checking camera, Metal and Photos behavior require Xcode and an Apple device or simulator.
