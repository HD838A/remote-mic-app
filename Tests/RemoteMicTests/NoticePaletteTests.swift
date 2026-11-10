import Foundation
import Testing
@testable import RemoteMic

/// 色值契约：设计稿里的对比度要求在这里变成可执行的断言。
///
/// 以后调色如果破坏「白字 ≥ 4.5」或「深色底分离 ≥ 3.0」，这些测试会直接红，
/// 而不是等到界面上看不清才发现。
@Suite("Notice palette contrast")
struct NoticePaletteTests {
    private let white: UInt32 = 0xFFFFFF
    private let darkSurface: UInt32 = NoticePalette.darkSurface

    @Test func lightFillsKeepWhiteTextReadable() {
        for tier in NoticeTier.allCases {
            let pair = NoticePalette.lightFill(tier)
            #expect(
                contrast(pair.base, white) >= 4.5,
                "\(tier) 浅色起点对比度不足：\(contrast(pair.base, white))"
            )
            #expect(
                contrast(pair.deep, white) >= 4.5,
                "\(tier) 浅色渐变末端对比度不足：\(contrast(pair.deep, white))"
            )
        }
    }

    @Test func darkFillsKeepWhiteTextReadable() {
        for tier in NoticeTier.allCases {
            let fill = NoticePalette.darkFill(tier)
            #expect(
                contrast(fill, white) >= 4.5,
                "\(tier) 深色填充对比度不足：\(contrast(fill, white))"
            )
        }
    }

    @Test func darkFillsSeparateFromWindowBackground() {
        for tier in NoticeTier.allCases {
            let fill = NoticePalette.darkFill(tier)
            #expect(
                contrast(fill, darkSurface) >= 3.0,
                "\(tier) 与深色窗口背景的分离度不足：\(contrast(fill, darkSurface))"
            )
        }
    }

    @Test func inlineBordersAreLighterThanAccent() {
        for tier in NoticeTier.allCases {
            let surface = NoticePalette.inlineSurface(tier)
            let accent = NoticePalette.inlineAccent(tier, dark: false)
            // 语义色条必须比浅底明显，否则左条会看不见。
            #expect(contrast(accent, surface) >= 3.0, "\(tier) 内联色条与底色对比不足")
        }
    }

    // MARK: - WCAG

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        let high = max(la, lb)
        let low = min(la, lb)
        return (high + 0.05) / (low + 0.05)
    }

    private func luminance(_ hex: UInt32) -> Double {
        0.2126 * channel((hex >> 16) & 0xFF)
            + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }

    private func channel(_ value: UInt32) -> Double {
        let c = Double(value) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
