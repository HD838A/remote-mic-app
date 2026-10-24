import Foundation

/// iPhone / Apple Watch 遥控连接在 Mac 端的会话状态。
///
/// 手机与手表这条连接是要会员的，所以「被会员挡住」是它的一种明确状态，
/// 而不是「点了没反应」。上层界面据此把原因和下一步告诉用户，
/// 而不是让用户对着一张永远扫不上的二维码发呆。
enum PhoneRemoteSessionState: Equatable, Sendable {
    /// 还没有发起过连接，或者上一次连接已经结束。
    case idle
    /// 最近一次连接尝试被会员权益挡住，连接服务并没有启动。
    case membershipRequired
}
