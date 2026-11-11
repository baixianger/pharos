import XCTest
import SwiftUI
import PharosClientKit
@testable import Pharos

final class AvatarTests: XCTestCase {

    // MARK: - 1. Deterministic Seed Generation

    func testDeterministicSeedGeneration() {
        let seedA1 = AvatarParameters.computeSeed("codex_agent_session_1")
        let seedA2 = AvatarParameters.computeSeed("codex_agent_session_1")
        let seedB = AvatarParameters.computeSeed("agy_agent_session_2")

        // Invariant: Identical seed string produces identical 64-bit hash
        XCTAssertEqual(seedA1, seedA2)
        XCTAssertNotEqual(seedA1, seedB)

        // Invariant: Identical hash produces identical shape and color
        let shapeA1 = AvatarParameters.shape(for: seedA1)
        let shapeA2 = AvatarParameters.shape(for: seedA2)
        XCTAssertEqual(shapeA1, shapeA2)

        let colorA1 = AvatarParameters.color(for: seedA1)
        let colorA2 = AvatarParameters.color(for: seedA2)
        XCTAssertEqual(colorA1, colorA2)
    }

    // MARK: - 2. Canonical Shapes Coverage

    func testAllCanonicalShapesGenerateNonEmptyPaths() {
        let testRect = CGRect(x: 0, y: 0, width: 100, height: 100)

        XCTAssertEqual(AvatarShape.allCases.count, 13)

        for shape in AvatarShape.allCases {
            let path = PharosAvatarShape.path(for: shape, in: testRect)
            let bounds = path.boundingRect
            XCTAssertFalse(bounds.isEmpty, "Shape \(shape.rawValue) generated empty path")
            XCTAssertGreaterThan(bounds.width, 10, "Shape \(shape.rawValue) width too small")
            XCTAssertGreaterThan(bounds.height, 10, "Shape \(shape.rawValue) height too small")
            XCTAssertFalse(shape.displayName.isEmpty)
        }
    }

    // MARK: - 3. Color Palette Specifications

    func testPaletteColorsLightAndDarkHexValidity() {
        XCTAssertEqual(AvatarPaletteColor.allCases.count, 11)

        for color in AvatarPaletteColor.allCases {
            XCTAssertTrue(color.lightHex.hasPrefix("#") && color.lightHex.count == 7, "Invalid light hex for \(color.rawValue)")
            XCTAssertTrue(color.darkHex.hasPrefix("#") && color.darkHex.count == 7, "Invalid dark hex for \(color.rawValue)")

            let lightColor = color.color(isDark: false)
            let darkColor = color.color(isDark: true)
            XCTAssertNotNil(lightColor)
            XCTAssertNotNil(darkColor)
        }
    }

    // MARK: - 4. Eye Expressions and Blink Deformation

    func testAllEyeExpressionsGenerateValidPaths() {
        let testRect = CGRect(x: 0, y: 0, width: 100, height: 100)

        XCTAssertEqual(AvatarExpression.allCases.count, 9)

        for exp in AvatarExpression.allCases {
            let openPath = PharosAvatarShape.eyePaths(for: exp, in: testRect, blinkProgress: 0.0)
            let openBounds = openPath.boundingRect
            XCTAssertFalse(openBounds.isEmpty, "Expression \(exp.rawValue) generated empty open path")

            let blinkedPath = PharosAvatarShape.eyePaths(for: exp, in: testRect, blinkProgress: 1.0)
            let blinkedBounds = blinkedPath.boundingRect
            XCTAssertFalse(blinkedBounds.isEmpty, "Expression \(exp.rawValue) generated empty blinked path")

            // Invariant: Full blink flattens the eye height
            XCTAssertLessThanOrEqual(blinkedBounds.height, openBounds.height)
        }
    }

    // MARK: - 5. Activity Status Mapping

    func testAvatarActivityStatusMapping() {
        XCTAssertEqual(AvatarActivityStatus.idle.defaultExpression, .calm)
        XCTAssertEqual(AvatarActivityStatus.working.defaultExpression, .neutral)
        XCTAssertEqual(AvatarActivityStatus.needsHuman.defaultExpression, .surprised)
        XCTAssertEqual(AvatarActivityStatus.stopped.defaultExpression, .sleepy)
    }

    // MARK: - 6. Customization Overrides

    @MainActor
    func testAvatarCustomizationOverrides() {
        let avatarView = PharosAvatarView(
            seed: "agent_42",
            customShape: .heart,
            customColor: .magenta,
            status: .working,
            size: 48
        )

        XCTAssertEqual(avatarView.effectiveShape, .heart)
        XCTAssertEqual(avatarView.effectiveColor, .magenta)
        XCTAssertEqual(avatarView.effectiveExpression, .neutral)
    }
}
