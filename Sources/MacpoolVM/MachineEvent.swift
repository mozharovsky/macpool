import Synchronization

/// A lifecycle event that the framework reports through the VM delegate.
public enum MachineEvent: Sendable, Hashable {
    /// The guest shut itself down.
    case guestStopped

    /// The VM stopped because of an error.
    ///
    /// - Parameter description: The framework's description of the error.
    case stoppedWithError(description: String)

    /// The network attachment disconnected while the VM kept running.
    ///
    /// - Parameter description: The framework's description of the error.
    case networkDisconnected(description: String)
}

/// A buffer that hands VM events from the delegate to one waiting task.
///
/// The delegate posts on the VM's queue, and the consumer waits from any task. A mutex guards the
/// buffer because posting must not suspend and waiting must not depend on the VM's queue.
final class EventMailbox: Sendable {
    /// A task that waits for the next event.
    private struct Waiter {
        /// The number that tells this wait from later ones when its timer fires.
        let id: UInt64
        /// The suspended task's continuation.
        let continuation: CheckedContinuation<Result<MachineEvent?, MacpoolError>, Never>
        /// The task that ends the wait after its timeout, once it exists.
        var timer: Task<Void, Never>?
    }

    /// The buffered events and the current waiter.
    private struct State {
        /// Events that arrived while no task waited, oldest first.
        var events: [MachineEvent] = []
        /// The task that waits for the next event.
        var waiter: Waiter?
        /// The identifier of the most recent wait.
        var lastWaiterID: UInt64 = 0
    }

    /// The outcome of checking the buffer when a wait begins.
    private enum Claim {
        /// The wait ends at once with this result.
        case ready(Result<MachineEvent?, MacpoolError>)
        /// The wait registered with this identifier and needs a timer.
        case waiting(UInt64)
    }

    /// The protected buffer.
    private let state = Mutex(State())

    /// Delivers an event to the waiting task or buffers it.
    ///
    /// - Parameter event: The event to deliver.
    func post(_ event: MachineEvent) {
        let waiter: Waiter? = state.withLock { state in
            guard let waiter = state.waiter else {
                state.events.append(event)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(returning: .success(event))
    }

    /// Whether a task currently waits for an event.
    ///
    /// Tests read it to know that a wait has registered before they act on it.
    var hasWaiter: Bool {
        state.withLock { $0.waiter != nil }
    }

    /// Returns the next event, waiting at most for a timeout.
    ///
    /// Cancelling the calling task ends the wait at once with `nil`. A task that is already
    /// cancelled still takes a buffered event.
    ///
    /// - Parameter timeout: The longest wait. A zero timeout only takes a buffered event.
    /// - Returns: The oldest undelivered event, or `nil` when none arrived in time or the task was
    ///   cancelled.
    /// - Throws: ``MacpoolError/eventWaitInProgress`` when another task already waits.
    func next(within timeout: Duration) async throws(MacpoolError) -> MachineEvent? {
        // The identifier exists before the wait registers, so a cancellation that races with the
        // registration still finds the wait it has to end.
        let id = state.withLock { state in
            state.lastWaiterID += 1
            return state.lastWaiterID
        }
        let result = await withTaskCancellationHandler {
            await wait(id: id, timeout: timeout)
        } onCancel: {
            expire(id)
        }
        return try result.get()
    }

    /// Registers a wait and suspends until an event, the timeout, or cancellation ends it.
    ///
    /// - Parameters:
    ///   - id: The wait's identifier, unique within this mailbox.
    ///   - timeout: The longest wait.
    /// - Returns: The event, `nil` for a timeout or cancellation, or the failure of a second wait.
    private func wait(id: UInt64, timeout: Duration) async -> Result<MachineEvent?, MacpoolError> {
        await withCheckedContinuation { continuation in
            let claim: Claim = state.withLock { state in
                if !state.events.isEmpty {
                    return .ready(.success(state.events.removeFirst()))
                }
                if state.waiter != nil {
                    return .ready(.failure(.eventWaitInProgress))
                }
                // Checking under the lock orders this with the cancellation handler, which takes
                // the lock only after the task's cancelled flag is set.
                if timeout <= .zero || Task.isCancelled {
                    return .ready(.success(nil))
                }
                state.waiter = Waiter(id: id, continuation: continuation)
                return .waiting(id)
            }
            switch claim {
            case let .ready(result):
                continuation.resume(returning: result)
            case let .waiting(id):
                let timer = Task { [self] in
                    try? await Task.sleep(for: timeout)
                    expire(id)
                }
                let isCurrent = state.withLock { state in
                    guard state.waiter?.id == id else {
                        return false
                    }
                    state.waiter?.timer = timer
                    return true
                }
                if !isCurrent {
                    timer.cancel()
                }
            }
        }
    }

    /// Ends a wait whose timeout elapsed or whose task was cancelled before an event arrived.
    ///
    /// - Parameter id: The identifier of the wait to end. Any other wait is left alone, and a wait
    ///   that has already ended makes the call do nothing.
    private func expire(_ id: UInt64) {
        let waiter: Waiter? = state.withLock { state in
            guard state.waiter?.id == id else {
                return nil
            }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(returning: .success(nil))
    }
}
