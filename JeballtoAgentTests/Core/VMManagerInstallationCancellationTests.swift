import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct VMManagerInstallationCancellationTests {
  @Test
  func downloadDelegateCancellationResumesAsCancellation() async throws {
    try await withTemporaryDirectory { root in
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "download-cancel",
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: root)
      )
      let installer = VMInstaller(vmDefinition: definition, eventBus: EventBus())
      let delegate = DownloadDelegate(
        installer: installer,
        destinationURL: URL(fileURLWithPath: root).appendingPathComponent("download.ipsw")
      )
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [SuspendedDownloadURLProtocol.self]
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      defer { session.invalidateAndCancel() }

      let downloadTask = Task<URL, Error> {
        try await withCheckedThrowingContinuation { continuation in
          delegate.startDownload(
            from: URL(string: "https://example.invalid/download.ipsw")!,
            session: session,
            continuation: continuation
          )
        }
      }

      await Task.yield()
      delegate.cancel()

      await #expect(throws: CancellationError.self) {
        try await downloadTask.value
      }
    }
  }

  @Test
  func downloadDelegateCancellationBeforeStartResumesAsCancellation() async throws {
    try await withTemporaryDirectory { root in
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "download-cancel-before-start",
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: root)
      )
      let installer = VMInstaller(vmDefinition: definition, eventBus: EventBus())
      let delegate = DownloadDelegate(
        installer: installer,
        destinationURL: URL(fileURLWithPath: root).appendingPathComponent("download.ipsw")
      )
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [SuspendedDownloadURLProtocol.self]
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      defer { session.invalidateAndCancel() }

      delegate.cancel()

      await #expect(throws: CancellationError.self) {
        try await withCheckedThrowingContinuation { continuation in
          delegate.startDownload(
            from: URL(string: "https://example.invalid/download.ipsw")!,
            session: session,
            continuation: continuation
          )
        }
      }
    }
  }

  @Test
  func cancelledInstallationFinalizersDoNotMutateDeletedVM() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let eventBus = EventBus()
      let networkManager = NetworkManager(eventBus: eventBus)
      let portForwardingManager = PortForwardingManager(config: config.networking, eventBus: eventBus)
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config,
        guiManager: nil,
        networkManager: networkManager,
        portForwardingManager: portForwardingManager
      )

      let definition = try await vmManager.createVM(name: "cancelled-install", resources: .default)
      let vmId = definition.id
      let instance = try await vmManager.getVMInstance(vmId)

      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
      }
      try await vmManager.updateVMDefinition(vmId, definition: MainActor.run { instance.definition })
      try await persistenceStore.deleteVM(vmId)

      let installer = VMInstaller(vmDefinition: definition, eventBus: eventBus)

      let completionTask = Task<Void, Error> {
        try await vmManager.completeInstallation(vmId: vmId, instance: instance, installer: installer)
      }
      completionTask.cancel()
      try await completionTask.value
      #expect(instance.currentState == .installing)

      let failureTask = Task<Void, Never> {
        await vmManager.handleInstallationFailure(vmId: vmId, instance: instance, error: CancellationError())
      }
      failureTask.cancel()
      await failureTask.value
      #expect(instance.currentState == .installing)
    }
  }
}

private final class SuspendedDownloadURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {}

  override func stopLoading() {}
}
