import Testing
@testable import RemoteMic

@Suite("App build mode")
struct AppBuildModeTests {
    @Test func localDevelopmentModeRequiresBooleanTrue() {
        #expect(AppBuildMode.isLocalDevelopmentBuild(in: [
            AppBuildMode.localDevelopmentInfoKey: true,
        ]))
        #expect(!AppBuildMode.isLocalDevelopmentBuild(in: [:]))
        #expect(!AppBuildMode.isLocalDevelopmentBuild(in: [
            AppBuildMode.localDevelopmentInfoKey: false,
        ]))
        #expect(!AppBuildMode.isLocalDevelopmentBuild(in: [
            AppBuildMode.localDevelopmentInfoKey: "true",
        ]))
    }
}
