import Foundation

enum ImageOperationCoordinatorError: Error, LocalizedError {
  case admissionsClosed
  case capacityReached(limit: Int)

  var errorDescription: String? {
    switch self {
    case .admissionsClosed:
      "The agent is performing destructive maintenance"
    case .capacityReached(let limit):
      "Too many active image operations (max \(limit))"
    }
  }
}

struct ImageOperationProgressReporter: Sendable {
  let sink: ImageOperationProgressSink
}

struct ImageOperationPreparedWork: Sendable {
  let run: @Sendable (ImageOperationProgressReporter) async throws -> ImageRecord
  let release: @Sendable () async -> Void

  init(
    run: @escaping @Sendable (ImageOperationProgressReporter) async throws -> ImageRecord,
    release: @escaping @Sendable () async -> Void = {}
  ) {
    self.run = run
    self.release = release
  }
}

struct ImageOperationRegistration: Sendable {
  let status: ImageOperationStatus
}

actor ImageOperationCoordinator {
  private struct OperationEntry: Sendable {
    var status: ImageOperationStatus
    var task: Task<Result<ImageRecord, Error>, Never>?
  }

  private struct PendingAdmission: Sendable {
    let task: Task<ImageOperationPreparedWork, Error>
  }

  private var operations: [UUID: OperationEntry] = [:]
  private var pendingAdmissions: [UUID: PendingAdmission] = [:]
  private var acceptsAdmissions = true
  private let maxActiveOperations: Int
  private let maxTerminalOperations: Int

  init(maxActiveOperations: Int = 8, maxTerminalOperations: Int = 100) {
    self.maxActiveOperations = max(1, maxActiveOperations)
    self.maxTerminalOperations = max(0, maxTerminalOperations)
  }

  func start(
    kind: ImageOperationKind,
    reference: String,
    source: String? = nil,
    prepare: @Sendable @escaping () async throws -> ImageOperationPreparedWork
  ) async throws -> ImageOperationRegistration {
    guard acceptsAdmissions else {
      throw ImageOperationCoordinatorError.admissionsClosed
    }

    let activeCount = operations.values.count(where: { $0.status.state.isTerminal == false })
      + pendingAdmissions.count
    guard activeCount < maxActiveOperations else {
      throw ImageOperationCoordinatorError.capacityReached(limit: maxActiveOperations)
    }

    let operationId = UUID()
    let preparationTask = Task<ImageOperationPreparedWork, Error> {
      try Task.checkCancellation()
      return try await prepare()
    }
    pendingAdmissions[operationId] = PendingAdmission(task: preparationTask)

    let prepared: ImageOperationPreparedWork
    do {
      prepared = try await withTaskCancellationHandler {
        try await preparationTask.value
      } onCancel: {
        preparationTask.cancel()
      }
    } catch {
      pendingAdmissions.removeValue(forKey: operationId)
      if acceptsAdmissions == false {
        throw ImageOperationCoordinatorError.admissionsClosed
      }
      if error is CancellationError {
        throw error
      }
      return registerPreparationFailure(
        id: operationId,
        kind: kind,
        reference: reference,
        source: source,
        error: error
      )
    }

    guard Task.isCancelled == false,
          acceptsAdmissions,
          pendingAdmissions.removeValue(forKey: operationId) != nil else
    {
      preparationTask.cancel()
      await prepared.release()
      throw CancellationError()
    }

    let status = ImageOperationStatusReducer.makeStatus(
      id: operationId,
      kind: kind,
      reference: reference,
      source: source
    )
    operations[operationId] = OperationEntry(status: status, task: nil)

    let coordinator = self
    let task = Task<Result<ImageRecord, Error>, Never> {
      let progressSink: ImageOperationProgressSink = { update in
        await coordinator.update(operationId, update: update)
      }

      let result: Result<ImageRecord, Error>
      do {
        try Task.checkCancellation()
        result = try await .success(prepared.run(ImageOperationProgressReporter(sink: progressSink)))
      } catch is CancellationError {
        result = .failure(CancellationError())
      } catch {
        result = .failure(error)
      }

      await prepared.release()
      await coordinator.finish(operationId, result: result)
      return result
    }
    operations[operationId]?.task = task

    return ImageOperationRegistration(status: status)
  }

  func wait(for operationId: UUID) async -> Result<ImageRecord, Error>? {
    guard let task = operations[operationId]?.task else { return nil }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  @discardableResult
  func cancelAndWait(_ operationId: UUID) async -> Bool {
    guard var entry = operations[operationId], entry.status.state.isTerminal == false else {
      return false
    }
    ImageOperationStatusReducer.requestCancellation(&entry.status)
    operations[operationId] = entry
    guard let task = entry.task else {
      ImageOperationStatusReducer.fail(&entry.status, error: CancellationError())
      operations[operationId] = entry
      trimTerminalOperationsIfNeeded()
      return true
    }

    task.cancel()
    _ = await task.value
    return true
  }

  @discardableResult
  func cancelAll(kind: ImageOperationKind? = nil) async -> [ImageOperationStatus] {
    let ids = operations.values
      .map(\.status)
      .filter { status in
        status.state.isTerminal == false && (kind == nil || status.kind == kind)
      }
      .map(\.id)

    let tasks = markCancellingAndCollectTasks(ids)
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      _ = await task.value
    }
    terminalizeTasklessCancellations(ids)

    return ids.compactMap { operations[$0]?.status }.sorted(by: Self.statusSort)
  }

  func closeAdmissionsAndDrain() async -> Int {
    acceptsAdmissions = false

    let pending = pendingAdmissions.values.map(\.task)
    pendingAdmissions.removeAll()
    for task in pending {
      task.cancel()
    }

    let activeIds = operations.values
      .map(\.status)
      .filter { $0.state.isTerminal == false }
      .map(\.id)
    let tasks = markCancellingAndCollectTasks(activeIds)
    for task in tasks {
      task.cancel()
    }
    for task in pending {
      _ = try? await task.value
    }
    for task in tasks {
      _ = await task.value
    }
    terminalizeTasklessCancellations(activeIds)

    return activeIds.count
  }

  func resumeAdmissions() {
    acceptsAdmissions = true
  }

  func status(for operationId: UUID) -> ImageOperationStatus? {
    operations[operationId]?.status
  }

  func list(kind: ImageOperationKind? = nil, activeOnly: Bool = false) -> [ImageOperationStatus] {
    operations.values
      .map(\.status)
      .filter { status in
        (kind == nil || status.kind == kind) && (activeOnly == false || status.state.isTerminal == false)
      }
      .sorted(by: Self.statusSort)
  }

  func hasActiveOperation(source: String) -> Bool {
    operations.values.contains { entry in
      entry.status.source == source && entry.status.state.isTerminal == false
    }
  }

  func update(_ operationId: UUID, update: ImageOperationProgressUpdate) {
    guard var entry = operations[operationId] else { return }
    ImageOperationStatusReducer.update(&entry.status, update: update)
    operations[operationId] = entry
  }

  private func finish(_ operationId: UUID, result: Result<ImageRecord, Error>) {
    guard var entry = operations[operationId] else { return }
    switch result {
    case .success(let record):
      ImageOperationStatusReducer.complete(&entry.status, record: record)
    case .failure(let error):
      ImageOperationStatusReducer.fail(&entry.status, error: error)
    }
    operations[operationId] = entry
    trimTerminalOperationsIfNeeded()
  }

  private func registerPreparationFailure(
    id: UUID,
    kind: ImageOperationKind,
    reference: String,
    source: String?,
    error: Error
  ) -> ImageOperationRegistration {
    var status = ImageOperationStatusReducer.makeStatus(
      id: id,
      kind: kind,
      reference: reference,
      source: source
    )
    ImageOperationStatusReducer.fail(&status, error: error)
    let task = Task<Result<ImageRecord, Error>, Never> {
      .failure(error)
    }
    operations[id] = OperationEntry(status: status, task: task)
    trimTerminalOperationsIfNeeded()
    return ImageOperationRegistration(status: status)
  }

  private func markCancellingAndCollectTasks(_ operationIds: [UUID]) -> [Task<Result<ImageRecord, Error>, Never>] {
    var tasks: [Task<Result<ImageRecord, Error>, Never>] = []
    for operationId in operationIds {
      guard var entry = operations[operationId], entry.status.state.isTerminal == false else { continue }
      ImageOperationStatusReducer.requestCancellation(&entry.status)
      operations[operationId] = entry
      if let task = entry.task {
        tasks.append(task)
      }
    }
    return tasks
  }

  private func terminalizeTasklessCancellations(_ operationIds: [UUID]) {
    for operationId in operationIds {
      guard var entry = operations[operationId],
            entry.status.state.isTerminal == false,
            entry.task == nil else { continue }
      ImageOperationStatusReducer.fail(&entry.status, error: CancellationError())
      operations[operationId] = entry
    }
    trimTerminalOperationsIfNeeded()
  }

  private func trimTerminalOperationsIfNeeded() {
    let terminal = operations.values
      .map(\.status)
      .filter { $0.completedUptime != nil }
      .sorted { lhs, rhs in
        let lhsUptime = lhs.completedUptime ?? 0
        let rhsUptime = rhs.completedUptime ?? 0
        if lhsUptime != rhsUptime { return lhsUptime < rhsUptime }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    let overflow = terminal.count - maxTerminalOperations
    guard overflow > 0 else { return }
    for status in terminal.prefix(overflow) {
      operations.removeValue(forKey: status.id)
    }
  }

  private static func statusSort(_ lhs: ImageOperationStatus, _ rhs: ImageOperationStatus) -> Bool {
    if lhs.startedUptime != rhs.startedUptime { return lhs.startedUptime > rhs.startedUptime }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
