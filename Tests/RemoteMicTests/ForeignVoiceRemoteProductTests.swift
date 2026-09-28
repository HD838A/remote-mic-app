import Foundation
import Testing
@testable import RemoteMic

/// 这些用例锁定的不是实现细节，而是**产品约束**：App 里每款遥控器都有真机图片，
/// 采用一台认不出来的 ATVV 设备就等于给它套上别的型号的图和按键集合，界面会声称一台
/// 从未验证过的设备「已连接」。所以准入只接受两种证据：已保存身份，或已验证的型号名。
@Suite("Xiaomi bridge admission")
struct ForeignVoiceRemoteProductTests {
    @Test func otherProductNamesAreRejected() {
        let names = [
            "Chromecast Remote",
            "chromecast remote",
            "CHROMECAST-REMOTE",
            "chromecast_remote",
            "  Chromecast   Remote  ",
            // 真机日志里出现过裸 "Chromecast"（Bluetooth 系统名不带 Remote）。
            "Chromecast",
            "chromecast 遥控器",
            "RemoteG10",
            "Remote-G10",
            "G10",
        ]
        for name in names {
            #expect(ForeignVoiceRemoteProduct.isRejected(name: name), "应当拒绝 \(name)")
        }
    }

    @Test func missingOrXiaomiNamesAreNotRejected() {
        let names: [String?] = [
            nil,
            "",
            "   ",
            "MI RC",
            "小米蓝牙语音遥控器",
            "ARN9",
        ]
        for name in names {
            #expect(!ForeignVoiceRemoteProduct.isRejected(name: name), "不应当拒绝 \(name ?? "nil")")
        }
    }

    @Test func savedIdentityDoesNotOverrideOtherProductVeto() {
        let identifier = UUID()
        // 早先版本把 Chromecast Remote 误存成 Xiaomi 档案；只按 UUID 采纳会让这个错误一直重连。
        #expect(
            VoiceRemoteAdmission.decide(
                identifier: identifier,
                targetIdentifier: identifier,
                advertisesVoiceService: true,
                name: "Chromecast Remote",
                advertisedName: nil
            ) == .rejectForeignProduct("chromecast remote")
        )
    }

    @Test func otherProductIsRejectedOnEveryDiscoveryPath() {
        let identifier = UUID()
        // 扫描广播名
        #expect(
            VoiceRemoteAdmission.decide(
                identifier: identifier,
                targetIdentifier: nil,
                advertisesVoiceService: true,
                name: nil,
                advertisedName: "Chromecast Remote"
            ).isAdopted == false
        )
        // 系统已连接设备上报的名称
        #expect(
            VoiceRemoteAdmission.decide(
                identifier: identifier,
                targetIdentifier: nil,
                advertisesVoiceService: true,
                name: "Chromecast Remote",
                advertisedName: nil
            ).isAdopted == false
        )
    }

    @Test func savedIdentityAdoptsEvenWithoutName() {
        let identifier = UUID()
        // 真机日志里有 6 次「已保存身份 + 拿不到名字」的采用记录；这条路径必须继续可用，
        // 否则这些已经在用的用户升级后会突然连不上。
        let decision = VoiceRemoteAdmission.decide(
            identifier: identifier,
            targetIdentifier: identifier,
            advertisesVoiceService: true,
            name: nil,
            advertisedName: nil
        )
        #expect(decision == .adoptSavedIdentity)
        #expect(decision.isAdopted)
    }

    @Test func verifiedXiaomiNameIsAdopted() {
        // 老版本用户的主力设备是小米蓝牙遥控器 2 / 2 Pro（硬件型号 ARN9），
        // 这 7 个广播名一个都不能少——少一个，对应的老用户升级后就再也连不上。
        let names = [
            "mi rc",
            "xiaomi bluetooth remote 2",
            "xiaomi bluetooth remote 2 pro",
            "小米蓝牙语音遥控器",
            "小米蓝牙遥控器2",
            "小米蓝牙遥控器2 pro",
            "arn9",
        ]
        #expect(names.count == VoiceRemoteCatalog.adoptedAdvertisedNames.count)
        for name in names {
            #expect(
                VoiceRemoteAdmission.decide(
                    identifier: UUID(),
                    targetIdentifier: nil,
                    advertisesVoiceService: false,
                    name: name,
                    advertisedName: nil
                ).isAdopted,
                "已验证型号名应当被采用：\(name)"
            )
        }
    }

    @Test func unsupportedNameIsRejectedEvenWhenItAdvertisesVoiceService() {
        // ATVV 是通用服务：协议相同 ≠ 型号相同。没有型号证据就不采用，宁可明确拒绝。
        #expect(
            VoiceRemoteAdmission.decide(
                identifier: UUID(),
                targetIdentifier: nil,
                advertisesVoiceService: true,
                name: "客厅遥控器",
                advertisedName: nil
            ) == .rejectUnrecognizedName("客厅遥控器")
        )
    }

    @Test func unnamedVoiceDeviceIsRejected() {
        // 首台无名设备不采用。已保存身份那条路径不受影响（见 savedIdentityAdoptsEvenWithoutName）。
        #expect(
            VoiceRemoteAdmission.decide(
                identifier: UUID(),
                targetIdentifier: nil,
                advertisesVoiceService: true,
                name: nil,
                advertisedName: nil
            ) == .rejectUnnamed
        )
    }

    @Test func unrelatedDeviceIsIgnoredNotRejected() {
        // 既不是 ATVV 设备、也不是本桥目标：与本桥无关，不该记拒绝日志（否则日志会被刷屏）。
        #expect(
            VoiceRemoteAdmission.decide(
                identifier: UUID(),
                targetIdentifier: nil,
                advertisesVoiceService: false,
                name: "某人的 AirPods",
                advertisedName: nil
            ) == .ignore
        )
    }

    @Test func rejectionReasonsAreDistinguishableInLogs() {
        // 三种拒绝在日志里必须能分开：名字符合别的产品 / 名字不认识 / 根本没拿到名字。
        #expect(
            VoiceRemoteAdmissionDecision.rejectForeignProduct("chromecast remote").logReason
                == "foreign_product"
        )
        #expect(
            VoiceRemoteAdmissionDecision.rejectUnrecognizedName("客厅遥控器").logReason
                == "unrecognized_name"
        )
        #expect(VoiceRemoteAdmissionDecision.rejectUnnamed.logReason == "unnamed")
    }
}
