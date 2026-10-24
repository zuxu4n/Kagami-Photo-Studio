import XCTest
import UIKit
@testable import PhotoStudio

@MainActor
final class EditorRegressionTests: XCTestCase {
    private func photoData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return try XCTUnwrap(image.pngData())
    }

    func testOpeningInSmoothTracksTheAutomaticEditAndSupportsUndoRedo() async throws {
        let model = EditorModel()
        model.tool = .smooth
        await model.load(data: try photoData())

        XCTAssertNil(model.error)
        XCTAssertEqual(model.smooth, model.smoothStart)
        XCTAssertTrue(model.edited, "Closing must warn about the smoothing that will be saved.")
        XCTAssertTrue(model.canUndo)

        await model.undo()
        XCTAssertEqual(model.smooth, 0)
        XCTAssertTrue(model.canRedo)
        await model.redo()
        XCTAssertEqual(model.smooth, model.smoothStart)
        model.close()
    }

    func testEnteringSmoothAppliesTheDefaultOnlyOncePerPhoto() async throws {
        let model = EditorModel()
        await model.load(data: try photoData())
        XCTAssertFalse(model.edited)

        model.toolShown(.smooth)
        XCTAssertTrue(model.canUndo)
        await model.undo()
        model.toolShown(.smooth)

        XCTAssertEqual(model.smooth, 0, "Returning to Smooth must preserve an undone default.")
        XCTAssertFalse(model.canUndo)
        model.close()
    }

    func testCloseInvalidatesBackgroundWorkAndReleasesPhotoState() async throws {
        let model = EditorModel()
        await model.load(data: try photoData())
        let version = model.workingVersion
        model.pushUndo(model.undoStep(.whole(try XCTUnwrap(model.working))))
        model.people = (model.sourceVersion, [[255]])
        model.blurEdits = MatteEdits(width: 1, height: 1, values: [255])
        model.blurStroke = (model.undoStep(.unchanged), .zero)
        model.personMatte = PersonMatte(width: 1, height: 1, base: [255], alpha: [255],
                                      holeWidth: 1, holeHeight: 1, hole: [255], fill: [0, 0, 0, 255],
                                      fgWidth: 1, fgHeight: 1, fg: [0, 0, 0, 255], hasPerson: true)

        model.close()

        XCTAssertNotEqual(model.workingVersion, version, "Pending cutout tasks must reject their old version.")
        XCTAssertFalse(model.hasImage)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.display)
        XCTAssertNil(model.original)
        XCTAssertNil(model.personMatte)
        XCTAssertNil(model.people)
        XCTAssertNil(model.blurStroke)
        XCTAssertTrue(model.blurEdits.isEmpty)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertFalse(model.edited)
    }

    func testBusyPhotoRejectsOverlappingDestructiveOperations() async throws {
        let model = EditorModel()
        await model.load(data: try photoData())
        let before = try XCTUnwrap(model.working).pixels
        model.busy = "Another operation"

        await model.runEnhance()
        await model.heal(at: .zero)
        await model.save()
        await model.peopleTap(at: .zero)

        XCTAssertEqual(model.busy, "Another operation")
        XCTAssertEqual(model.working?.pixels, before)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.canUndo)
        model.busy = nil
        model.close()
    }
}
