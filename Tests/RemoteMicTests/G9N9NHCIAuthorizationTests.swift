import Foundation
import Testing
import AppleRemotePacketLogger

struct G9N9NHCIAuthorizationTests {
    private var strong: [String: Any] {
        ["class": "user", "group": "admin", "authenticate-user": true,
         "shared": false, "timeout": 0]
    }

    @Test func omittedAndExplicitFalseSessionOwnerAreEquivalent() {
        #expect(PacketLoggerAuthorizationRulePolicy.isStrongEnough(strong))
        var normalized = strong
        normalized["session-owner"] = false
        #expect(PacketLoggerAuthorizationRulePolicy.isStrongEnough(normalized))
        normalized["session-owner"] = true
        #expect(!PacketLoggerAuthorizationRulePolicy.isStrongEnough(normalized))
        normalized["session-owner"] = "false"
        #expect(!PacketLoggerAuthorizationRulePolicy.isStrongEnough(normalized))
    }

    @Test func everyAuthenticationBoundaryIsStillRequired() {
        for (key, value) in [("class", "allow" as Any), ("group", "everyone"),
            ("authenticate-user", false), ("shared", true), ("timeout", 300),
            ("rule", ["allow"])] {
            var rule = strong
            rule[key] = value
            #expect(!PacketLoggerAuthorizationRulePolicy.isStrongEnough(rule))
        }
        for key in ["class", "group", "authenticate-user", "shared", "timeout"] {
            var rule = strong
            rule.removeValue(forKey: key)
            #expect(!PacketLoggerAuthorizationRulePolicy.isStrongEnough(rule))
        }
    }
}
