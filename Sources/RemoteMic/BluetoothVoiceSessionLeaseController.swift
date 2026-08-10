import Foundation

struct BluetoothVoiceLeaseScheduledTask {
    private let cancellation: () -> Void

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }

    static func mainQueue(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        operation: @escaping () -> Void
    ) -> BluetoothVoiceLeaseScheduledTask {
        let source = DispatchSource.makeTimerSource(queue: .main)
        if let interval {
            source.schedule(deadline: .now() + delay, repeating: interval)
        } else {
            source.schedule(deadline: .now() + delay)
        }
        source.setEventHandler(handler: operation)
        source.resume()
        return BluetoothVoiceLeaseScheduledTask { source.cancel() }
    }
}

final class BluetoothVoiceSessionLeaseController {
    struct Configuration: Equatable {
        let keepAliveInterval: TimeInterval
        let maximumDuration: TimeInterval
        let closeConfirmationTimeout: TimeInterval

        static let threeMinuteTrial = Configuration(
            keepAliveInterval: 10,
            maximumDuration: 180,
            closeConfirmationTimeout: 2
        )
    }

    typealias Scheduler = (
        TimeInterval,
        TimeInterval?,
        @escaping () -> Void
    ) -> BluetoothVoiceLeaseScheduledTask

    private let configuration: Configuration
    private let schedule: Scheduler
    private var generation: UInt64 = 0
    private var keepAliveTask: BluetoothVoiceLeaseScheduledTask?
    private var limitTask: BluetoothVoiceLeaseScheduledTask?
    private var closeConfirmationTask: BluetoothVoiceLeaseScheduledTask?

    init(
        configuration: Configuration = .threeMinuteTrial,
        schedule: @escaping Scheduler = BluetoothVoiceLeaseScheduledTask.mainQueue
    ) {
        self.configuration = configuration
        self.schedule = schedule
    }

    func start(
        isActive: @escaping () -> Bool,
        requestExtend: @escaping () -> Bool,
        requestClose: @escaping () -> Bool,
        reconnect: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        stop()
        let sessionGeneration = generation

        limitTask = schedule(configuration.maximumDuration, nil) { [weak self] in
            guard let self,
                  self.generation == sessionGeneration,
                  isActive()
            else { return }
            self.keepAliveTask?.cancel()
            self.keepAliveTask = nil
            let closeWritten = requestClose()
            log(
                "ATVV VOICE LEASE limit seconds=" +
                    "\(Int(self.configuration.maximumDuration)) close_written=\(closeWritten)"
            )
            self.closeConfirmationTask = self.schedule(
                self.configuration.closeConfirmationTimeout,
                nil
            ) { [weak self] in
                guard let self,
                      self.generation == sessionGeneration,
                      isActive()
                else { return }
                log("ATVV VOICE LEASE close_timeout reconnecting=true")
                reconnect()
            }
        }

        keepAliveTask = schedule(
            configuration.keepAliveInterval,
            configuration.keepAliveInterval
        ) { [weak self] in
            guard let self,
                  self.generation == sessionGeneration,
                  isActive()
            else { return }
            let extended = requestExtend()
            log("ATVV VOICE LEASE extend written=\(extended)")
        }
    }

    func stop() {
        generation &+= 1
        keepAliveTask?.cancel()
        keepAliveTask = nil
        limitTask?.cancel()
        limitTask = nil
        closeConfirmationTask?.cancel()
        closeConfirmationTask = nil
    }
}
