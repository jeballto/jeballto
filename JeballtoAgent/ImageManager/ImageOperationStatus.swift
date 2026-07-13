import Foundation

enum ImageOperationKind: String, Codable, Sendable {
  case pull
  case push
}

enum ImageOperationState: String, Codable, Sendable {
  case started
  case running
  case cancelling
  case completed
  case failed
  case cancelled

  var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled:
      true
    case .started, .running, .cancelling:
      false
    }
  }
}

enum ImageOperationStage: String, Codable, Sendable {
  case compressing
  case uploading
  case finalizing
}

/// Stable API error codes recorded for terminal image operations.
enum ImageOperationErrorCode: String, CaseIterable, Sendable {
  case imagePullFailed = "IMAGE_PULL_FAILED"
  case imagePushFailed = "IMAGE_PUSH_FAILED"
  case imagePushCommitOutcomeUnknown = "IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN"
  case imagePushPartiallyCommitted = "IMAGE_PUSH_PARTIALLY_COMMITTED"
  case imagePullTimeout = "IMAGE_PULL_TIMEOUT"
  case imagePushTimeout = "IMAGE_PUSH_TIMEOUT"
  case imagePullRegistryUnavailable = "IMAGE_PULL_REGISTRY_UNAVAILABLE"
  case imagePushRegistryUnavailable = "IMAGE_PUSH_REGISTRY_UNAVAILABLE"
  case imagePullCancelled = "IMAGE_PULL_CANCELLED"
  case imagePushCancelled = "IMAGE_PUSH_CANCELLED"
  case imageNotFound = "IMAGE_NOT_FOUND"
  case imageInUse = "IMAGE_IN_USE"
  case invalidReference = "INVALID_REFERENCE"
  case invalidImage = "INVALID_IMAGE"
  case unsupportedImageFormat = "UNSUPPORTED_IMAGE_FORMAT"
}

struct ImageOperationProgressUpdate: Sendable {
  var stage: ImageOperationStage?
  var progress: Double?
  var stageProgress: Double?
  var setChunksCompleted: Int?
  var chunksCompletedDelta: Int?
  var chunksTotal: Int?
  var setBytesCompleted: UInt64?
  var bytesCompletedDelta: UInt64?
  var bytesTotal: UInt64?

  init(
    stage: ImageOperationStage? = nil,
    progress: Double? = nil,
    stageProgress: Double? = nil,
    setChunksCompleted: Int? = nil,
    chunksCompletedDelta: Int? = nil,
    chunksTotal: Int? = nil,
    setBytesCompleted: UInt64? = nil,
    bytesCompletedDelta: UInt64? = nil,
    bytesTotal: UInt64? = nil
  ) {
    self.stage = stage
    self.progress = progress
    self.stageProgress = stageProgress
    self.setChunksCompleted = setChunksCompleted
    self.chunksCompletedDelta = chunksCompletedDelta
    self.chunksTotal = chunksTotal
    self.setBytesCompleted = setBytesCompleted
    self.bytesCompletedDelta = bytesCompletedDelta
    self.bytesTotal = bytesTotal
  }
}

typealias ImageOperationProgressSink = @Sendable (ImageOperationProgressUpdate) async -> Void

struct ImageOperationStatus: Sendable {
  let id: UUID
  let kind: ImageOperationKind
  let reference: String
  let source: String?
  var state: ImageOperationState
  var stage: ImageOperationStage?
  var progress: Double?
  var stageProgress: Double?
  var chunksCompleted: Int
  var chunksTotal: Int?
  var bytesCompleted: UInt64
  var bytesTotal: UInt64?
  let startedAt: Date
  let startedUptime: TimeInterval
  var stageStartedAt: Date?
  var stageStartedUptime: TimeInterval?
  var updatedAt: Date
  var updatedUptime: TimeInterval
  var completedAt: Date?
  var completedUptime: TimeInterval?
  var digest: String?
  var image: ImageRecord?
  var errorCode: ImageOperationErrorCode?
  var error: String?
}

enum ImageOperationTrackerError: Error, LocalizedError {
  case capacityReached(limit: Int)

  var errorDescription: String? {
    switch self {
    case .capacityReached(let limit):
      "Too many active image operations (max \(limit))"
    }
  }
}

actor ImageOperationTracker {
  private var operations: [UUID: ImageOperationStatus] = [:]
  private let maxCompletedOperations = 100
  private let maxActiveOperations: Int

  init(maxActiveOperations: Int = 8) {
    self.maxActiveOperations = max(1, maxActiveOperations)
  }

  func start(
    id: UUID = UUID(),
    kind: ImageOperationKind,
    reference: String,
    source: String? = nil
  ) -> ImageOperationStatus {
    makeStatus(id: id, kind: kind, reference: reference, source: source)
  }

  func admit(
    id: UUID,
    kind: ImageOperationKind,
    reference: String,
    source: String? = nil
  ) throws -> ImageOperationStatus {
    let activeCount = operations.values.filter { $0.state.isTerminal == false }.count
    guard activeCount < maxActiveOperations else {
      throw ImageOperationTrackerError.capacityReached(limit: maxActiveOperations)
    }
    return makeStatus(id: id, kind: kind, reference: reference, source: source)
  }

  private func makeStatus(
    id: UUID,
    kind: ImageOperationKind,
    reference: String,
    source: String?
  ) -> ImageOperationStatus {
    let now = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    let status = ImageOperationStatus(
      id: id,
      kind: kind,
      reference: reference,
      source: source,
      state: .started,
      stage: nil,
      progress: nil,
      stageProgress: nil,
      chunksCompleted: 0,
      chunksTotal: nil,
      bytesCompleted: 0,
      bytesTotal: nil,
      startedAt: now,
      startedUptime: uptime,
      stageStartedAt: nil,
      stageStartedUptime: nil,
      updatedAt: now,
      updatedUptime: uptime,
      completedAt: nil,
      completedUptime: nil,
      digest: nil,
      image: nil,
      errorCode: nil,
      error: nil
    )
    operations[status.id] = status
    trimCompletedOperationsIfNeeded()
    return status
  }

  func update(_ id: UUID, _ update: ImageOperationProgressUpdate) {
    guard var status = operations[id], status.state.isTerminal == false else { return }

    let now = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    if status.state != .cancelling {
      status.state = .running
    }
    if let stage = update.stage, status.stage != stage {
      status.stage = stage
      status.stageStartedAt = now
      status.stageStartedUptime = uptime
      if stage == .finalizing {
        status.chunksCompleted = 0
        status.chunksTotal = nil
        status.bytesCompleted = 0
        status.bytesTotal = nil
      }
    }
    if let chunksTotal = update.chunksTotal { status.chunksTotal = max(0, chunksTotal) }
    if let bytesTotal = update.bytesTotal { status.bytesTotal = bytesTotal }
    if let setChunksCompleted = update.setChunksCompleted {
      status.chunksCompleted = max(0, setChunksCompleted)
    } else if let chunksCompletedDelta = update.chunksCompletedDelta {
      status.chunksCompleted = adding(chunksCompletedDelta, to: status.chunksCompleted)
    }
    if let setBytesCompleted = update.setBytesCompleted {
      status.bytesCompleted = setBytesCompleted
    } else if let bytesCompletedDelta = update.bytesCompletedDelta {
      status.bytesCompleted = adding(bytesCompletedDelta, to: status.bytesCompleted)
    }
    if let stageProgress = update.stageProgress {
      status.stageProgress = clampedProgress(stageProgress)
    } else if status.stage != nil {
      status.stageProgress = computedProgress(for: status)
    }
    if let progress = update.progress {
      status.progress = clampedActiveProgress(progress)
    } else if let stage = status.stage, let stageProgress = status.stageProgress {
      status.progress = weightedProgress(stage: stage, stageProgress: stageProgress)
    } else if let bytesTotal = status.bytesTotal, bytesTotal > 0 {
      status.progress = clampedActiveProgress(Double(status.bytesCompleted) / Double(bytesTotal))
    } else if let chunksTotal = status.chunksTotal, chunksTotal > 0 {
      status.progress = clampedActiveProgress(Double(status.chunksCompleted) / Double(chunksTotal))
    }
    status.updatedAt = now
    status.updatedUptime = uptime
    operations[id] = status
  }

  func complete(_ id: UUID, record: ImageRecord) {
    guard var status = operations[id], status.state.isTerminal == false else { return }
    let now = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    status.state = .completed
    status.progress = 1.0
    if status.stage == .finalizing {
      status.stageProgress = 1.0
    }
    status.digest = record.digest
    status.image = record
    status.errorCode = nil
    status.error = nil
    status.updatedAt = now
    status.updatedUptime = uptime
    status.completedAt = now
    status.completedUptime = uptime
    operations[id] = status
    trimCompletedOperationsIfNeeded()
  }

  func fail(_ id: UUID, error: Error) {
    guard var status = operations[id], status.state.isTerminal == false else { return }
    let now = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    status.state = error is CancellationError ? .cancelled : .failed
    if let imageManagerError = error as? ImageManagerError {
      switch imageManagerError {
      case .pushCommitOutcomeUnknown(_, let digest, _), .pushPartiallyCommitted(_, let digest, _):
        status.digest = digest
      default:
        break
      }
    }
    status.errorCode = Self.errorCode(for: error, kind: status.kind)
    status.error = error.localizedDescription
    status.updatedAt = now
    status.updatedUptime = uptime
    status.completedAt = now
    status.completedUptime = uptime
    operations[id] = status
    trimCompletedOperationsIfNeeded()
  }

  @discardableResult
  func cancel(_ id: UUID) -> Bool {
    guard var status = operations[id], status.state.isTerminal == false else { return false }
    let now = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    status.state = .cancelling
    status.errorCode = nil
    status.error = nil
    status.updatedAt = now
    status.updatedUptime = uptime
    status.completedAt = nil
    status.completedUptime = nil
    operations[id] = status
    return true
  }

  func get(_ id: UUID) -> ImageOperationStatus? {
    operations[id]
  }

  func list(kind: ImageOperationKind? = nil, activeOnly: Bool = false) -> [ImageOperationStatus] {
    operations.values
      .filter { status in
        (kind == nil || status.kind == kind) && (!activeOnly || status.state.isTerminal == false)
      }
      .sorted { lhs, rhs in
        if lhs.startedUptime != rhs.startedUptime { return lhs.startedUptime > rhs.startedUptime }
        return lhs.id.uuidString < rhs.id.uuidString
      }
  }

  func hasActiveOperation(source: String) -> Bool {
    operations.values.contains { status in
      status.source == source && status.state.isTerminal == false
    }
  }

  private func trimCompletedOperationsIfNeeded() {
    let completed = operations.values
      .filter { $0.completedUptime != nil }
      .sorted { lhs, rhs in
        let lhsUptime = lhs.completedUptime ?? 0
        let rhsUptime = rhs.completedUptime ?? 0
        if lhsUptime != rhsUptime { return lhsUptime < rhsUptime }
        return lhs.id.uuidString < rhs.id.uuidString
      }

    let overflow = completed.count - maxCompletedOperations
    guard overflow > 0 else { return }

    for status in completed.prefix(overflow) {
      operations.removeValue(forKey: status.id)
    }
  }

  private func clampedProgress(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return max(0.0, min(1.0, value))
  }

  private func clampedActiveProgress(_ value: Double) -> Double {
    min(0.99, clampedProgress(value))
  }

  private func adding(_ delta: Int, to value: Int) -> Int {
    let (result, overflow) = value.addingReportingOverflow(delta)
    if overflow { return delta >= 0 ? Int.max : 0 }
    return max(0, result)
  }

  private func adding(_ delta: UInt64, to value: UInt64) -> UInt64 {
    let (result, overflow) = value.addingReportingOverflow(delta)
    return overflow ? UInt64.max : result
  }

  private func computedProgress(for status: ImageOperationStatus) -> Double? {
    if let bytesTotal = status.bytesTotal, bytesTotal > 0 {
      return clampedProgress(Double(status.bytesCompleted) / Double(bytesTotal))
    }
    if let chunksTotal = status.chunksTotal, chunksTotal > 0 {
      return clampedProgress(Double(status.chunksCompleted) / Double(chunksTotal))
    }
    return nil
  }

  private func weightedProgress(stage: ImageOperationStage, stageProgress: Double) -> Double {
    switch stage {
    case .compressing:
      clampedActiveProgress(stageProgress * 0.5)
    case .uploading:
      clampedActiveProgress(0.5 + stageProgress * 0.5)
    case .finalizing:
      0.99
    }
  }

  private static func errorCode(for error: Error, kind: ImageOperationKind) -> ImageOperationErrorCode {
    if error is CancellationError {
      return kind == .pull ? .imagePullCancelled : .imagePushCancelled
    }

    if let imageManagerError = error as? ImageManagerError {
      switch imageManagerError {
      case .imageNotFound, .imageNotFoundById:
        return .imageNotFound
      case .invalidReference:
        return .invalidReference
      case .invalidImage:
        return .invalidImage
      case .unsupportedImageFormat:
        return .unsupportedImageFormat
      case .imageInUse:
        return .imageInUse
      case .registryUnavailable:
        return kind == .pull ? .imagePullRegistryUnavailable : .imagePushRegistryUnavailable
      case .timeout:
        return kind == .pull ? .imagePullTimeout : .imagePushTimeout
      case .pushCommitOutcomeUnknown:
        return .imagePushCommitOutcomeUnknown
      case .pushPartiallyCommitted:
        return .imagePushPartiallyCommitted
      case .pullFailed, .pushFailed, .deleteFailed:
        break
      }
    }

    return kind == .pull ? .imagePullFailed : .imagePushFailed
  }
}
