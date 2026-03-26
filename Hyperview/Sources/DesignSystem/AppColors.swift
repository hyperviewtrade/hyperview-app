import SwiftUI

// MARK: - Hyperliquid Design System
// Single source of truth for all brand colors.
// Every UI element that needs green or red MUST reference these values.
// Do NOT hardcode Color(red:green:blue:) for brand colors anywhere else.

enum AppColors {
    /// Hyperliquid accent green #25D695 — readable on dark backgrounds.
    static let hlGreen = Color(red: 0.145, green: 0.839, blue: 0.584)

    /// Trading red — used for sell buttons and bearish price movements.
    static let tradingRed = Color(red: 0.93, green: 0.25, blue: 0.33)

    /// Main page background (neutral dark).
    static let hlBackground = Color(white: 0.07)

    /// Card / elevated surface background.
    static let hlCardBackground = Color(white: 0.11)

    /// Interactive surface (inputs, search bars, borders).
    static let hlSurface = Color(white: 0.14)

    /// Dividers, grid lines.
    static let hlDivider = Color(white: 0.18)

    /// Dark green-tinted background for buttons / pills.
    /// Makes hlGreen text readable — used instead of plain gray on actionable elements.
    static let hlButtonBg = Color(red: 0.055, green: 0.118, blue: 0.098)
}

extension Color {
    /// Hyperliquid accent green — readable, saturated.
    static let hlGreen   = AppColors.hlGreen
    /// Trading red for sell-side and bearish UI.
    static let tradingRed = AppColors.tradingRed
    /// Main page background.
    static let hlBackground = AppColors.hlBackground
    /// Card surface.
    static let hlCardBackground = AppColors.hlCardBackground
    /// Interactive surface.
    static let hlSurface = AppColors.hlSurface
    /// Dividers.
    static let hlDivider = AppColors.hlDivider
    /// Dark green button/pill background.
    static let hlButtonBg = AppColors.hlButtonBg
}
