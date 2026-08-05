enum RemoteButtonPhase: String, Codable {
    case press
    case release
}

struct RemoteButtonGestureRecognizer {
    enum Command: Equatable {
        case scheduleDoubleClickTimeout(RemoteButton)
        case cancelDoubleClickTimeout(RemoteButton)
        case scheduleLongPressTimeout(RemoteButton)
        case cancelLongPressTimeout(RemoteButton)
        case trigger(RemoteButton, ButtonTrigger)
    }

    private struct State {
        var isPressed = true
        var isSecondPress = false
        var waitingForSecondPress = false
        var longPressTriggered = false
        let recognizesDoubleClick: Bool
        let recognizesLongPress: Bool
    }

    private var states: [RemoteButton: State] = [:]

    func isTracking(_ button: RemoteButton) -> Bool {
        states[button] != nil
    }

    mutating func handle(
        _ phase: RemoteButtonPhase,
        button: RemoteButton,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> [Command] {
        switch phase {
        case .press:
            return press(
                button,
                recognizesDoubleClick: recognizesDoubleClick,
                recognizesLongPress: recognizesLongPress
            )
        case .release:
            return release(button)
        }
    }

    mutating func press(
        _ button: RemoteButton,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> [Command] {
        if var state = states[button] {
            guard state.waitingForSecondPress else { return [] }
            state.isPressed = true
            state.isSecondPress = true
            state.waitingForSecondPress = false
            states[button] = state

            var commands: [Command] = [.cancelDoubleClickTimeout(button)]
            if state.recognizesLongPress {
                commands.append(.scheduleLongPressTimeout(button))
            }
            return commands
        }

        let state = State(
            recognizesDoubleClick: recognizesDoubleClick,
            recognizesLongPress: recognizesLongPress
        )
        states[button] = state
        return recognizesLongPress ? [.scheduleLongPressTimeout(button)] : []
    }

    mutating func release(_ button: RemoteButton) -> [Command] {
        guard var state = states[button], state.isPressed else { return [] }
        state.isPressed = false

        var commands: [Command] = []
        if state.recognizesLongPress {
            commands.append(.cancelLongPressTimeout(button))
        }
        if state.longPressTriggered {
            states.removeValue(forKey: button)
            return commands
        }
        if state.isSecondPress {
            states.removeValue(forKey: button)
            commands.append(.trigger(button, .doubleClick))
            return commands
        }
        if state.recognizesDoubleClick {
            state.waitingForSecondPress = true
            states[button] = state
            commands.append(.scheduleDoubleClickTimeout(button))
            return commands
        }

        states.removeValue(forKey: button)
        commands.append(.trigger(button, .singleClick))
        return commands
    }

    mutating func doubleClickTimedOut(_ button: RemoteButton) -> [Command] {
        guard let state = states[button], state.waitingForSecondPress, !state.isPressed else {
            return []
        }
        states.removeValue(forKey: button)
        return [.trigger(button, .singleClick)]
    }

    mutating func longPressTimedOut(_ button: RemoteButton) -> [Command] {
        guard var state = states[button], state.isPressed, state.recognizesLongPress else {
            return []
        }
        state.longPressTriggered = true
        states[button] = state
        return [.trigger(button, .longPress)]
    }

    mutating func reset() {
        states.removeAll()
    }
}
