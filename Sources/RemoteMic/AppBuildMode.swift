import Foundation

enum AppBuildMode {
    static let localDevelopmentInfoKey = "SayAllDevelopmentBuild"

    static var isLocalDevelopmentBuild: Bool {
        isLocalDevelopmentBuild(in: Bundle.main.infoDictionary ?? [:])
    }

    static func isLocalDevelopmentBuild(in infoDictionary: [String: Any]) -> Bool {
        infoDictionary[localDevelopmentInfoKey] as? Bool == true
    }
}
