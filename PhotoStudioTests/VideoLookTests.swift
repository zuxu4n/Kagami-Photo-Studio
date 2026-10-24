import XCTest
@testable import PhotoStudio

final class VideoLookTests: XCTestCase {
    func testExportSettingsAreIndependentOfPreviewAndComparison() {
        let preview = LookBox()
        preview.look.smooth = 0.65
        preview.look.shape.eyes = 0.25
        preview.adjust.crop = .square
        preview.adjust.turns = 1
        preview.comparing = true

        let export = LookBox(look: preview.look, adjust: preview.adjust)
        let expectedLook = preview.look
        let expectedAdjust = preview.adjust
        preview.look = LiveLook()
        preview.adjust = Adjustments()
        preview.comparing = false

        XCTAssertFalse(export.comparing, "Hold to compare must never remove effects from an export.")
        XCTAssertEqual(export.look, expectedLook)
        XCTAssertEqual(export.adjust, expectedAdjust)
    }
}
