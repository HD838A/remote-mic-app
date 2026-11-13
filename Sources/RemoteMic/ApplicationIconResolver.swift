import Foundation

/// 「APP 适配」列表的图标来源。配置导入会清空 `applicationPath`，旧档案也可能
/// 指向当前 Mac 上已不存在的 App；这两种情况都按 bundle identifier 重新解析。
enum ApplicationIconResolver {
    static func iconPath(
        for profile: CustomApplicationProfile,
        fileExists: (String) -> Bool,
        resolveBundle: (String) -> URL?
    ) -> String {
        if !profile.applicationPath.isEmpty, fileExists(profile.applicationPath) {
            return profile.applicationPath
        }
        return resolveBundle(profile.bundleIdentifier)?.path ?? profile.applicationPath
    }
}
