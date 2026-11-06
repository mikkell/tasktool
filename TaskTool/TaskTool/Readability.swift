//
//  Readability.swift
//  TaskTool
//
//  Shared text colors tuned for legibility in both light and dark appearances.
//
//  System accent colors (`.red`, `.green`, `.orange`, …) are designed for fills and icons;
//  as small text on a white or tinted card they fall well below the WCAG 4.5:1 contrast
//  ratio, and `.secondary` sits at roughly 3.9:1 on white. Use these instead for text.
//

import SwiftUI
import AppKit

extension Color {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// De-emphasised text that still meets ≥ 4.5:1 contrast (`.secondary` does not).
    static let taskToolSecondaryText = adaptive(
        light: NSColor(white: 0, alpha: 0.62),
        dark: NSColor(white: 1, alpha: 0.62)
    )

    /// Error / overdue text. Stays ≥ 4.5:1 on white and on red-tinted card backgrounds.
    static let taskToolDanger = adaptive(light: rgb(0.72, 0.10, 0.10), dark: rgb(1.00, 0.45, 0.42))

    /// Completed / success text.
    static let taskToolSuccess = adaptive(light: rgb(0.05, 0.45, 0.18), dark: rgb(0.40, 0.85, 0.50))

    /// Warning / due-soon text (readable on white and on yellow-tinted backgrounds).
    static let taskToolWarning = adaptive(light: rgb(0.65, 0.32, 0.00), dark: rgb(1.00, 0.70, 0.30))

    /// Informational text (e.g. "due soon" badges).
    static let taskToolInfo = adaptive(light: rgb(0.00, 0.34, 0.80), dark: rgb(0.45, 0.70, 1.00))

    /// Blocked / waiting text.
    static let taskToolBlocked = adaptive(light: rgb(0.50, 0.20, 0.70), dark: rgb(0.78, 0.60, 1.00))

    /// Plan colors whose system fill is too light for white text.
    /// Plan colors whose system fill is too light for white text without extra darkening.
    private static let lightPlanColorNames: Set<String> = ["yellow", "orange", "gray", "green"]

    /// The plan color as a fill behind white text, darkened enough (more for light colors like
    /// yellow or green) that white stays legible.
    static func fillForWhiteText(planColor colorName: String) -> Color {
        let amount = lightPlanColorNames.contains(colorName.lowercased()) ? 0.4 : 0.15
        return Color.from(string: colorName).mix(with: .black, by: amount)
    }
}
