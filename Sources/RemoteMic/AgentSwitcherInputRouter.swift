import Foundation

/// Retains consumed presses until their matching release, even after OK closes
/// the panel. Only ordinary button events pass through this router.
final class AgentSwitcherInputRouter {
    private var consumedButtons: [String: Set<RemoteButton>] = [:]
    private var pressedButtons: [String: Set<RemoteButton>] = [:]

    func consume(
        button: RemoteButton,
        phase: RemoteButtonPhase,
        owner: String,
        isActive: Bool = false,
        handlePress: () -> Bool
    ) -> Bool {
        if phase == .release {
            pressedButtons[owner]?.remove(button)
            return consumedButtons[owner]?.remove(button) != nil
        }
        let isDuplicate = !pressedButtons[owner, default: []].insert(button).inserted
        if consumedButtons[owner]?.contains(button) == true { return true }
        if isDuplicate, isActive {
            consumedButtons[owner, default: []].insert(button)
            return true
        }
        guard handlePress() else { return false }
        consumedButtons[owner, default: []].insert(button)
        return true
    }

    func reset(owner: String) {
        consumedButtons.removeValue(forKey: owner)
        pressedButtons.removeValue(forKey: owner)
    }
}
