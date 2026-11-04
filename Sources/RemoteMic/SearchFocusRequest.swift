import Combine
import Foundation

/// 搜索框聚焦的跨仓契约。
///
/// 私有包无法 import 公开仓（公开仓是 executable target，依赖方向单向），
/// 因此这里只固定两个通知名字面量。私有包侧必须使用逐字节相同的字符串，
/// 一致性由 `SearchFocusTests` 与私有包各自的测试共同保证。
enum SearchFocusRequest {
    /// 页面 → 宿主：登记/注销「当前页面存在主搜索框」。
    ///
    /// `userInfo`: `section: String`、`isRegistered: Bool`。
    /// 必须从主线程发送（`SearchFocusCoordinator` 只在主线程维护状态）。
    static let registerNotification = Notification.Name("sayall.search.focus.register")

    /// 宿主 → 页面：请求聚焦当前页面的主搜索框。
    static let focusNotification = Notification.Name("sayall.search.focus.request")

    static let sectionUserInfoKey = "section"
    static let isRegisteredUserInfoKey = "isRegistered"
}

/// 页面侧登记辅助。公开仓与私有包使用同一套通知契约，不共享 Swift 类型。
enum SearchFieldRegistration {
    static func post(section: String, isRegistered: Bool) {
        NotificationCenter.default.post(
            name: SearchFocusRequest.registerNotification,
            object: nil,
            userInfo: [
                SearchFocusRequest.sectionUserInfoKey: section,
                SearchFocusRequest.isRegisteredUserInfoKey: isRegistered,
            ]
        )
    }
}

/// 搜索框聚焦协调器，由 AppDelegate 持有。
///
/// 页面在主搜索框出现时登记、消失时注销；宿主据此判断「查找…」是否可用，
/// 并只广播一次聚焦请求。登记与请求分离，是为了让菜单校验成为纯状态查询
/// ——打开「编辑」菜单本身不会产生聚焦副作用。
///
/// 沿用 `ButtonProfileImportRequestStore` 的范式，仅在主线程使用。
final class SearchFocusCoordinator: ObservableObject {
    @Published private(set) var registeredSections: Set<String> = []
    private var registrationObserver: NSObjectProtocol?

    init() {
        registrationObserver = NotificationCenter.default.addObserver(
            forName: SearchFocusRequest.registerNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.applyRegistration(userInfo: notification.userInfo)
        }
    }

    deinit {
        if let registrationObserver {
            NotificationCenter.default.removeObserver(registrationObserver)
        }
    }

    /// 同步解析一次登记更新；通知回调与测试共用。
    func applyRegistration(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let section = userInfo[SearchFocusRequest.sectionUserInfoKey] as? String,
              let isRegistered = userInfo[SearchFocusRequest.isRegisteredUserInfoKey] as? Bool
        else { return }
        if isRegistered {
            registeredSections.insert(section)
        } else {
            registeredSections.remove(section)
        }
    }

    /// 是否有任何页面登记了主搜索框。不可见的页面会注销，因此这份状态
    /// 天然等价于「当前可见页面有没有可聚焦的搜索框」。
    var hasRegisteredSearchField: Bool { !registeredSections.isEmpty }

    /// 广播聚焦请求。幂等：重复调用只是重复把同一个搜索框聚焦，
    /// 不清空内容、不改变已有选区。
    func requestFocus() {
        NotificationCenter.default.post(name: SearchFocusRequest.focusNotification, object: nil)
    }
}
