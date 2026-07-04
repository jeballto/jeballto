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
      return true
    case .started, .running, .cancelling:
      return false
    }
  }
}

enum ImageOperationStage: String, Codable, Sendable {
  case compressing
  case uploading
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
  var stageStartedAt: Date?
  var updatedAt: Date
  var completedAt: Date?
  var digest: String?
  var image: ImageRecord?
  var error: String?
}

actor ImageOperationTracker {
  private var operations: [UUID: ImageOperationStatus] = [:]
  private let maxCompletedOperations = 100

  func start(kind: ImageOperationKind, reference: String, source: String? = nil) -> ImageOperationStatus {
    let now = Date()
    let status = ImageOperationStatus(
      id: UUID(),
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
      stageStartedAt: nil,
      updatedAt: now,
      completedAt: nil,
      digest: nil,
      image: nil,
      error: nil
    )
    operations[status.id] = status
    trimCompletedOperationsIfNeeded()
    return status
  }

  func update(_ id: UUID, _ update: ImageOperationProgressUpdate) {
    guard var status = operations[id], status.state.isTerminal == false else { return }

    let now = Date()
    if status.state != .cancelling {
      status.state = .running
    }
    if let stage = update.stage, status.stage != stage {
      status.stage = stage
      status.stageStartedAt = now
    }
    if let chunksTotal = update.chunksTotal { status.chunksTotal = chunksTotal }
    if let bytesTotal = update.bytesTotal { status.bytesTotal = bytesTotal }
    if let setChunksCompleted = update.setChunksCompleted {
      status.chunksCompleted = max(0, setChunksCompleted)
    } else if let chunksCompletedDelta = update.chunksCompletedDelta {
      status.chunksCompleted += chunksCompletedDelta
    }
    if let setBytesCompleted = update.setBytesCompleted {
      status.bytesCompleted = setBytesCompleted
    } else if let bytesCompletedDelta = update.bytesCompletedDelta {
      status.bytesCompleted += bytesCompletedDelta
    }
    if let stageProgress = update.stageProgress {
      status.stageProgress = clampedProgress(stageProgress)
    } else if status.stage != nil {
      status.stageProgress = computedProgress(for: status)
    }
    if let progress = update.progress {
      status.progress = clampedProgress(progress)
    } else if let stage = status.stage, let stageProgress = status.stageProgress {
      status.progress = weightedProgress(stage: stage, stageProgress: stageProgress)
    } else if let bytesTotal = status.bytesTotal, bytesTotal > 0 {
      status.progress = clampedProgress(Double(status.bytesCompleted) / Double(bytesTotal))
    } else if let chunksTotal = status.chunksTotal, chunksTotal > 0 {
      status.progress = clampedProgress(Double(status.chunksCompleted) / Double(chunksTotal))
    }
    status.updatedAt = now
    operations[id] = status
  }

  func complete(_ id: UUID, record: ImageRecord) {
    guard var status = operations[id], status.state.isTerminal == false else { return }
    let now = Date()
    status.state = .completed
    status.progress = 1.0
    status.digest = record.digest
    status.image = record
    status.error = nil
    status.updatedAt = now
    status.completedAt = now
    operations[id] = status
    trimCompletedOperationsIfNeeded()
  }

  func fail(_ id: UUID, error: Error) {
    guard var status = operations[id], status.state.isTerminal == false else { return }
    let now = Date()
    status.state = error is CancellationError ? .cancelled : .failed
    status.error = error.localizedDescription
    status.updatedAt = now
    status.completedAt = now
    operations[id] = status
    trimCompletedOperationsIfNeeded()
  }

  @discardableResult
  func cancel(_ id: UUID) -> Bool {
    guard var status = operations[id], status.state.isTerminal == false else { return false }
    let now = Date()
    status.state = .cancelling
    status.error = nil
    status.updatedAt = now
    status.completedAt = nil
    operations[id] = status
    return true
  }

  func get(_ id: UUID) -> ImageOperationStatus? {
    operations[id]
  }

  func hasActiveOperation(source: String) -> Bool {
    operations.values.contains { status in
      status.source == source && status.state.isTerminal == false
    }
  }

  private func trimCompletedOperationsIfNeeded() {
    let completed = operations.values
      .filter { $0.completedAt != nil }
      .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }

    let overflow = completed.count - maxCompletedOperations
    guard overflow > 0 else { return }

    for status in completed.prefix(overflow) {
      operations.removeValue(forKey: status.id)
    }
  }

  private func clampedProgress(_ value: Double) -> Double {
    max(0.0, min(1.0, value))
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
      return clampedProgress(stageProgress * 0.5)
    case .uploading:
      return clampedProgress(0.5 + stageProgress * 0.5)
    }
  }
}
