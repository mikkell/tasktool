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
}
