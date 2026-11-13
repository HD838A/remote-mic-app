/// 进入哪些页面时要重读组合动作库。
///
/// 组合动作改名后，键位方案页用的是按键方案组件自己那份宏库快照。同一进程内改名
/// 由组件内部的通知刷新；跨进程写入（另一份安装包、测试包、配置恢复流程）收不到
/// 通知，只能在进入按键页和键位方案页时主动重读一次。
enum ButtonProfileMacroRefreshPolicy {
    static func shouldRefresh(section: SettingsSection) -> Bool {
        section == .mapping || section == .buttonProfiles
    }
}
