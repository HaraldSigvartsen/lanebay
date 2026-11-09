import AppKit
import SwiftUI
import XCTest
import LanebayDesign

final class DesignTokenTests: XCTestCase {
    func testSpacingSitsOnTheFourPointGrid() {
        let scale = [DS.Space.xxs, DS.Space.xs, DS.Space.sm, DS.Space.md, DS.Space.lg, DS.Space.xl]
        XCTAssertEqual(scale, [4, 8, 12, 16, 24, 32])
        for value in scale {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0, "\(value) is off the 4 pt grid")
        }
    }

    func testRadiusScaleMatchesRedesign() {
        XCTAssertEqual(DS.Radius.chip, 8)
        XCTAssertEqual(DS.Radius.control, 10)
        XCTAssertEqual(DS.Radius.card, 18)
        XCTAssertEqual(DS.Radius.sheet, 22)
    }

    func testEveryStatusKindHasAColor() {
        XCTAssertEqual(Set(DS.Color.statusColors.keys), Set(StatusKind.allCases))
        for kind in StatusKind.allCases {
            _ = DS.Color.status(kind)
        }
    }

    func testAccentInkOnAccentSoftMeetsWCAGAAInLightAndDarkMode() {
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let nsAppearance = NSAppearance(named: appearance)!
            let fg = resolvedSRGB(DS.Color.accentInk, appearance: nsAppearance)
            let bg = resolvedSRGB(DS.Color.accentSoft, appearance: nsAppearance)
            let ratio = contrastRatio(fg, bg)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) accent ink on accent soft: \(ratio):1")
        }
    }

    func testLightModeTextAndBordersStayReadable() {
        let light = NSAppearance(named: .aqua)!
        let raised = resolvedSRGB(DS.Color.raisedSurface, appearance: light)
        let surface = resolvedSRGB(DS.Color.surface, appearance: light)
        for (name, color) in [("ink", DS.Color.ink), ("secondaryInk", DS.Color.secondaryInk), ("mutedInk", DS.Color.mutedInk)] {
            let ratio = contrastRatio(resolvedSRGB(color, appearance: light), raised)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "light \(name) on raisedSurface: \(ratio):1")
        }
        let hairline = contrastRatio(resolvedSRGB(DS.Color.hairline, appearance: light), surface)
        XCTAssertGreaterThanOrEqual(hairline, 1.5, "light hairline on surface: \(hairline):1")
        let canvas = contrastRatio(surface, resolvedSRGB(DS.Color.canvas, appearance: light))
        XCTAssertGreaterThanOrEqual(canvas, 1.15, "white cards must separate from the light canvas: \(canvas):1")
    }

        func testMotionHonoursReduceMotion() {
        XCTAssertNil(DS.Motion.animation(DS.Motion.snappy, reduceMotion: true))
        XCTAssertNil(DS.Motion.animation(DS.Motion.pulse, reduceMotion: true))
        XCTAssertNotNil(DS.Motion.animation(DS.Motion.snappy, reduceMotion: false))
    }

    // MARK: - Helpers

    private func resolvedSRGB(_ color: Color, appearance: NSAppearance) -> (CGFloat, CGFloat, CGFloat) {
        var components: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
                XCTFail("Unable to resolve color as sRGB")
                return
            }
            components = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }
        return components
    }

    private func contrastRatio(_ foreground: (CGFloat, CGFloat, CGFloat), _ background: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        let foregroundLuminance = luminance(foreground)
        let backgroundLuminance = luminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func linearize(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgb.0) + 0.7152 * linearize(rgb.1) + 0.0722 * linearize(rgb.2)
    }
}
