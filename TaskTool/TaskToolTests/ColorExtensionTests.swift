//
//  ColorExtensionTests.swift
//  TaskToolTests
//
//  Created by Mikkel Lund Lindemark on 23/01/2026.
//

import XCTest
import SwiftUI
@testable import TaskTool

final class ColorExtensionTests: XCTestCase {
    
    func testColorFromStringBlue() {
        let color = Color.from(string: "blue")
        XCTAssertEqual(color, .blue)
    }
    
    func testColorFromStringGreen() {
        let color = Color.from(string: "green")
        XCTAssertEqual(color, .green)
    }
    
    func testColorFromStringRed() {
        let color = Color.from(string: "red")
        XCTAssertEqual(color, .red)
    }
    
    func testColorFromStringOrange() {
        let color = Color.from(string: "orange")
        XCTAssertEqual(color, .orange)
    }
    
    func testColorFromStringPurple() {
        let color = Color.from(string: "purple")
        XCTAssertEqual(color, .purple)
    }
    
    func testColorFromStringYellow() {
        let color = Color.from(string: "yellow")
        XCTAssertEqual(color, .yellow)
    }
    
    func testColorFromStringGray() {
        let color = Color.from(string: "gray")
        XCTAssertEqual(color, .gray)
    }
    
    func testColorFromStringCaseInsensitive() {
        let colorUpper = Color.from(string: "BLUE")
        let colorLower = Color.from(string: "blue")
        let colorMixed = Color.from(string: "BlUe")
        
        XCTAssertEqual(colorUpper, .blue)
        XCTAssertEqual(colorLower, .blue)
        XCTAssertEqual(colorMixed, .blue)
    }
    
    func testColorFromStringInvalid() {
        let color = Color.from(string: "invalid")
        XCTAssertEqual(color, .blue) // Should default to blue
    }
    
    func testColorFromStringEmpty() {
        let color = Color.from(string: "")
        XCTAssertEqual(color, .blue) // Should default to blue
    }

    // MARK: - Readability

    func testSemanticTextColorsMeetContrastOnTintedBackgrounds() {
        let tints: [(Color, NSColor)] = [
            (.taskToolDanger, .systemRed),
            (.taskToolSuccess, .systemGreen),
            (.taskToolWarning, .systemYellow),
            (.taskToolInfo, .systemBlue),
            (.taskToolBlocked, .systemPurple),
            (.taskToolSecondaryText, .clear)
        ]
        let appearances: [(NSAppearance.Name, NSColor)] = [
            (.aqua, .white),
            (.darkAqua, NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1))
        ]
        for (appearanceName, base) in appearances {
            let appearance = NSAppearance(named: appearanceName)!
            for (text, tint) in tints {
                var ratio = 0.0
                appearance.performAsCurrentDrawingAppearance {
                    let tinted = tint.withAlphaComponent(0.18)
                    let bg = Self.composite(tinted, over: Self.resolve(base))
                    ratio = Self.contrastRatio(Self.composite(Self.resolve(NSColor(text)), over: bg), bg)
                }
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text) in \(appearanceName.rawValue)")
            }
        }
    }

    private static func resolve(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func composite(_ fg: NSColor, over bg: NSColor) -> NSColor {
        let f = resolve(fg), b = resolve(bg), a = f.alphaComponent
        return NSColor(
            srgbRed: f.redComponent * a + b.redComponent * (1 - a),
            green: f.greenComponent * a + b.greenComponent * (1 - a),
            blue: f.blueComponent * a + b.blueComponent * (1 - a),
            alpha: 1
        )
    }

    private static func luminance(_ color: NSColor) -> Double {
        func lin(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(color.redComponent) + 0.7152 * lin(color.greenComponent) + 0.0722 * lin(color.blueComponent)
    }

    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
