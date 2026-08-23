import SwiftUI

/// Pharos visual theme, derived from the DeepSeek Harness Web design tokens
/// (dsh-core/packages/client/ui-theme/src/styles/design-platform.css).
///
/// DSH Web's hierarchy: near-black primary controls + DeepSeek blue as the
/// accent/info/active color, on a neutral white/gray surface with hairline
/// borders. We keep that shape but let macOS own the surfaces (Liquid Glass,
/// semantic materials) so light/dark just works.
enum PharosTheme {
    /// DeepSeek brand blue (--dsw-static-deepseek-500, #4176E6).
    static let accent = Color(red: 65 / 255, green: 118 / 255, blue: 230 / 255)

    /// Semantic state colors (--dsw-alias-state-*).
    static let success = Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)    // #22C55E
    static let warning = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)   // #F59E0B
    static let danger  = Color(red: 236 / 255, green: 19 / 255, blue: 19 / 255)    // #EC1313

    /// Blue-tinted selection, adaptive across light/dark via the accent color.
    static let selection = Color.accentColor.opacity(0.12)

    /// Base surface behind the rounded workspace card (macOS under-page gray,
    /// adapts to light/dark so the card reads as floating).
    static let surface = Color(nsColor: .underPageBackgroundColor)
}
