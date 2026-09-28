import Foundation
import Testing
@testable import RemoteMic

/// 这些用例把「每个接入的遥控器都有真机图」从口头约定变成 CI 门禁：
/// 目录是「支持哪些遥控器」的唯一事实源，新增一款型号如果忘了放图，这里会直接红。
@Suite("Voice remote catalog")
struct VoiceRemoteCatalogTests {

    @Test func everyCatalogEntryHasAPhotoResourceOnDisk() {
        // #filePath = <repo>/Tests/RemoteMicTests/VoiceRemoteCatalogTests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RemoteMicTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        for entry in VoiceRemoteCatalog.entries {
            let path = repoRoot
                .appendingPathComponent("Resources/\(entry.photoResource).png")
                .path
            #expect(
                FileManager.default.fileExists(atPath: path),
                "型号 \(entry.model.rawValue) 声明的真机图不存在：Resources/\(entry.photoResource).png"
            )
        }
    }

    @Test func disModelNumbersAreUniqueAcrossEntries() {
        var seen: Set<String> = []
        for entry in VoiceRemoteCatalog.entries {
            for pattern in entry.disModelNumbers {
                #expect(
                    seen.insert(pattern).inserted,
                    "DIS 型号串 \(pattern) 在多个目录项里重复，会产生歧义"
                )
            }
        }
    }

    @Test func identificationMatchesCatalogForEveryEntry() {
        for entry in VoiceRemoteCatalog.entries {
            for pattern in entry.disModelNumbers {
                #expect(
                    XiaomiRemoteModel.identified(by: pattern) == entry.model,
                    "DIS 型号串 \(pattern) 应识别为 \(entry.model.rawValue)"
                )
            }
        }
    }

    @Test func identificationMatchesVerifiedHardware() {
        // 真机证实（2026-09-19，双机实测）：小米蓝牙遥控器 2 报 RC001、2 Pro 报 RC003。
        // 两台的广播名都是「小米蓝牙语音遥控器」，只有 DIS 能区分。
        #expect(XiaomiRemoteModel.identified(by: "RC001") == .rc001)
        #expect(XiaomiRemoteModel.identified(by: "RC003") == .rc003)
        #expect(XiaomiRemoteModel.identified(by: " rc003 ") == .rc003)
        // ARN9 从未在任何真机上出现过（历史日志 0 次），归属无证据 → 不映射型号。
        // 型号不回写只影响展示名；连接（广播名白名单含 "arn9"）与音频解码
        // （桥里独立的 ADPCM 字节序检测）都不受影响。
        #expect(XiaomiRemoteModel.identified(by: "ARN9") == nil)
        #expect(XiaomiRemoteModel.identified(by: "XX-ARN9-XX") == nil)
        // 真机实测的未识别串（别的产品）必须返回 nil——识别不出就不采用。
        #expect(XiaomiRemoteModel.identified(by: "A0") == nil)
        #expect(XiaomiRemoteModel.identified(by: "A3") == nil)
        #expect(XiaomiRemoteModel.identified(by: "") == nil)
        #expect(XiaomiRemoteModel.identified(by: "   ") == nil)
    }

    @Test func photoResourceIsExplicitPerModelAndAbsentForUnrecognized() {
        // 共用是同一份素材的**显式声明**，不是默认行为：rc001/rc003 明确各写一遍。
        #expect(VoiceRemoteCatalog.photoResource(for: .rc001) == "RC003-remote-photo")
        #expect(VoiceRemoteCatalog.photoResource(for: .rc003) == "RC003-remote-photo")
        // 未识别型号 / 走私有包链路的型号：目录里没有，调用方必须显示占位。
        #expect(VoiceRemoteCatalog.photoResource(for: .unknown) == nil)
        #expect(VoiceRemoteCatalog.photoResource(for: .appleSiriRemoteA2854) == nil)
        #expect(VoiceRemoteCatalog.photoResource(for: .appleSiriRemoteA2540) == nil)
        #expect(VoiceRemoteCatalog.photoResource(for: .chromecastVoiceRemote) == nil)
    }

    @Test func advertisedNamesCoverEveryNameTheBridgeHasEverAdopted() {
        // 真机日志里出现过的、本桥应当继续采用的广播名，一个都不能少。
        for name in ["mi rc", "小米蓝牙语音遥控器", "arn9", "小米蓝牙遥控器2", "小米蓝牙遥控器2 pro"] {
            #expect(
                VoiceRemoteCatalog.adoptedAdvertisedNames.contains(name),
                "目录遗漏了已在真机上采用过的广播名：\(name)"
            )
        }
        // 别的产品的名字不得出现在采用名单里。
        #expect(!VoiceRemoteCatalog.adoptedAdvertisedNames.contains("chromecast remote"))
        #expect(!VoiceRemoteCatalog.adoptedAdvertisedNames.contains("chromecast"))
    }
}
