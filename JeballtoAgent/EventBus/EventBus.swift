import Foundation

/// Types of events that can be published through the event bus
enum VMEvent: Equatable {
  /// Published by `VMStateMachine` for every validated transition. Use `from` and `to` to react to specific
  /// transitions.
  case stateChanged(vmId: UUID, from: VMState, to: VMState)
  case vmCreated(vmId: UUID, name: String)
  case vmDeleted(vmId: UUID, name: String)
  case vmStarting(vmId: UUID)
  case vmRunning(vmId: UUID)
  case vmStopping(vmId: UUID)
  case vmStopped(vmId: UUID)
  case vmPaused(vmId: UUID)
  case vmResumed(vmId: UUID)
  case errorOccurred(vmId: UUID?, error: String)
  /// Published when `PortForwardingManager` allocates a forwarding port after the VM reaches `running` state.
  case sshPortAssigned(vmId: UUID, port: Int)
  case sshPortReleased(vmId: UUID)
  /// Published when the SSH daemon inside the guest OS is confirmed reachable (banner check succeeded).
  /// Fired at most once per VM start.
  case sshReady(vmId: UUID)
  case vncPortAssigned(vmId: UUID, port: Int)
  case vncPortReleased(vmId: UUID)
  case installStarted(vmId: UUID)
  /// Published at regular intervals during macOS installation.
  /// `bytesDownloaded` and `bytesTotal` are `nil` for non-download phases (setup, installing).
  case installProgress(
    vmId: UUID,
    progress: Double,
    phaseProgress: Double,
    message: String,
    phase: String,
    bytesDownloaded: UInt64?,
    bytesTotal: UInt64?,
    downloadSpeed: UInt64?
  )
  case installCompleted(vmId: UUID)
  case installFailed(vmId: UUID, error: String)
  case vmCloned(vmId: UUID, sourceVmId: UUID, name: String)
  case vmResourcesUpdated(vmId: UUID)
  case guiOpened(vmId: UUID)
  case guiClosed(vmId: UUID)

  // Image events
  case imagePullStarted(reference: String)
  case imagePulled(reference: String)
  case imagePullFailed(reference: String, error: String)
  case imagePushStarted(reference: String)
  case imagePushed(reference: String)
  case imagePushFailed(reference: String, error: String)
  case imageDeleted(reference: String)

  // Jeballtofile events
  case jeballtofileStarted(executionId: UUID, vmId: UUID)
  case jeballtofileStepStarted(executionId: UUID, step: Int, stepType: String)
  case jeballtofileStepCompleted(executionId: UUID, step: Int, stepType: String)
  case jeballtofileStepFailed(executionId: UUID, step: Int, stepType: String, error: String)
  case jeballtofileCompleted(executionId: UUID, vmId: UUID)
  case jeballtofileCancelled(executionId: UUID, vmId: UUID, step: Int)
  case jeballtofileFailed(executionId: UUID, vmId: UUID, step: Int, error: String)

  /// Returns a string identifier for the event type
  var eventType: String {
    switch self {
    case .stateChanged: "STATE_CHANGED"
    case .vmCreated: "VM_CREATED"
    case .vmDeleted: "VM_DELETED"
    case .vmStarting: "VM_STARTING"
    case .vmRunning: "VM_RUNNING"
    case .vmStopping: "VM_STOPPING"
    case .vmStopped: "VM_STOPPED"
    case .vmPaused: "VM_PAUSED"
    case .vmResumed: "VM_RESUMED"
    case .errorOccurred: "ERROR_OCCURRED"
    case .sshPortAssigned: "SSH_PORT_ASSIGNED"
    case .sshPortReleased: "SSH_PORT_RELEASED"
    case .sshReady: "SSH_READY"
    case .vncPortAssigned: "VNC_PORT_ASSIGNED"
    case .vncPortReleased: "VNC_PORT_RELEASED"
    case .installStarted: "INSTALL_STARTED"
    case .installProgress: "INSTALL_PROGRESS"
    case .installCompleted: "INSTALL_COMPLETED"
    case .installFailed: "INSTALL_FAILED"
    case .vmCloned: "VM_CLONED"
    case .vmResourcesUpdated: "VM_RESOURCES_UPDATED"
    case .guiOpened: "GUI_OPENED"
    case .guiClosed: "GUI_CLOSED"
    case .imagePullStarted: "IMAGE_PULL_STARTED"
    case .imagePulled: "IMAGE_PULLED"
    case .imagePullFailed: "IMAGE_PULL_FAILED"
    case .imagePushStarted: "IMAGE_PUSH_STARTED"
    case .imagePushed: "IMAGE_PUSHED"
    case .imagePushFailed: "IMAGE_PUSH_FAILED"
    case .imageDeleted: "IMAGE_DELETED"
    case .jeballtofileStarted: "JEBALLTOFILE_STARTED"
    case .jeballtofileStepStarted: "JEBALLTOFILE_STEP_STARTED"
    case .jeballtofileStepCompleted: "JEBALLTOFILE_STEP_COMPLETED"
    case .jeballtofileStepFailed: "JEBALLTOFILE_STEP_FAILED"
    case .jeballtofileCompleted: "JEBALLTOFILE_COMPLETED"
    case .jeballtofileCancelled: "JEBALLTOFILE_CANCELLED"
    case .jeballtofileFailed: "JEBALLTOFILE_FAILED"
    }
  }

  /// Returns the VM ID associated with this event, if any
  var vmId: UUID? {
    switch self {
    case .stateChanged(let vmId, _, _), .vmCreated(let vmId, _), .vmDeleted(let vmId, _), .vmStarting(let vmId),
         .vmRunning(let vmId), .vmStopping(let vmId), .vmStopped(let vmId), .vmPaused(let vmId), .vmResumed(let vmId),
         .vmCloned(let vmId, _, _), .vmResourcesUpdated(let vmId), .sshPortAssigned(let vmId, _),
         .sshPortReleased(let vmId), .sshReady(let vmId),
         .vncPortAssigned(let vmId, _), .vncPortReleased(let vmId),
         .installStarted(let vmId), .installProgress(let vmId, _, _, _, _, _, _, _),
         .installCompleted(let vmId), .installFailed(let vmId, _), .guiOpened(let vmId), .guiClosed(let vmId):
      vmId
    case .errorOccurred(let vmId, _): vmId
    case .jeballtofileStarted(_, let vmId), .jeballtofileCompleted(_, let vmId),
         .jeballtofileCancelled(_, let vmId, _),
         .jeballtofileFailed(_, let vmId, _, _):
      vmId
    case .jeballtofileStepStarted, .jeballtofileStepCompleted, .jeballtofileStepFailed:
      nil
    case .imagePullStarted, .imagePulled, .imagePullFailed, .imagePushStarted, .imagePushed, .imagePushFailed,
         .imageDeleted:
      nil
    }
  }
}

/// A recorded event with timestamp
struct RecordedEvent {
  let timestamp: Date
  let event: VMEvent

  var description: String {
    let formatter = ISO8601DateFormatter()
    return "[\(formatter.string(from: timestamp))] \(event.eventType)"
  }
}

/// Type alias for event subscriber callback
typealias EventSubscriber = (VMEvent) -> Void

/// Event bus for pub/sub messaging across the application
class EventBus {
  /// Subscription identifier
  typealias SubscriptionToken = UUID

  /// Storage for subscribers
  private var subscribers: [SubscriptionToken: EventSubscriber] = [:]

  /// Event history for debugging
  private var eventHistory: [RecordedEvent] = []

  /// Maximum number of events to keep in history
  private let maxHistorySize: Int

  /// Queue for thread-safe operations
  private let queue = DispatchQueue(label: "com.jeballto.eventbus", attributes: .concurrent)

  init(maxHistorySize: Int = 1000) { self.maxHistorySize = maxHistorySize }

  // MARK: - Public API

  /// Subscribes to all events
  /// - Parameter callback: The closure to call when events are published
  /// - Returns: A token that can be used to unsubscribe
  @discardableResult func subscribe(_ callback: @escaping EventSubscriber) -> SubscriptionToken {
    let token = UUID()
    queue.async(flags: .barrier) { self.subscribers[token] = callback }
    return token
  }

  /// Unsubscribes from events
  /// - Parameter token: The subscription token returned from subscribe()
  func unsubscribe(_ token: SubscriptionToken) {
    queue.async(flags: .barrier) { self.subscribers.removeValue(forKey: token) }
  }

  /// Publishes an event to all subscribers
  /// - Parameter event: The event to publish
  func publish(_ event: VMEvent) {
    queue.async(flags: .barrier) {
      // Record in history
      let recorded = RecordedEvent(timestamp: Date(), event: event)
      self.eventHistory.append(recorded)

      // Trim history if needed
      if self.eventHistory.count > self.maxHistorySize {
        self.eventHistory.removeFirst(self.eventHistory.count - self.maxHistorySize)
      }

      // Notify each subscriber independently so one slow subscriber cannot block others
      let currentSubscribers = self.subscribers.values
      for subscriber in currentSubscribers {
        DispatchQueue.global(qos: .userInitiated).async { subscriber(event) }
      }
    }
  }

  /// Returns recent events for a specific VM
  /// - Parameters:
  ///   - vmId: The VM ID to filter by
  ///   - limit: Maximum number of events to return
  /// - Returns: Array of recorded events
  func getEvents(forVM vmId: UUID, limit: Int = 100) -> [RecordedEvent] {
    queue.sync { eventHistory.filter { $0.event.vmId == vmId }.suffix(limit).map { $0 } }
  }

  /// Returns all recent events
  /// - Parameter limit: Maximum number of events to return
  /// - Returns: Array of recorded events
  func getAllEvents(limit: Int = 100) -> [RecordedEvent] {
    queue.sync { Array(eventHistory.suffix(limit)) }
  }

  /// Clears all event history
  func clearHistory() { queue.async(flags: .barrier) { self.eventHistory.removeAll() } }

  /// Returns the number of active subscribers
  var subscriberCount: Int { queue.sync { subscribers.count } }

  /// Returns the number of events in history
  var eventCount: Int { queue.sync { eventHistory.count } }
}
