import Cocoa
import Darwin
import Foundation
import Sparkle

#if arch(arm64)

@main @MainActor final class JeballtoAgent: NSObject, NSApplicationDelegate {
  private var config: Config?
  private var eventBus: EventBus?
  private var persistenceStore: PersistenceStore?
  private var networkManager: NetworkManager?
  private var portForwardingManager: PortForwardingManager?
  private var guiManager: GUIManager?
  private var vmManager: VMManager?
  private var imageManager: ImageManager?
  private var apiServer: APIServer?
  private var statusBarManager: StatusBarManager?
  private var updaterManager: UpdaterManager?
  private var singleInstanceLock: SingleInstanceLock?
  private var imageWorkSessionLock: ImageWorkSessionLock?

  /// Termination signal handlers (both must be retained to stay active)
  private var sigTermSource: DispatchSourceSignal?
  private var sigIntSource: DispatchSourceSignal?
  private var isTerminationInProgress = false

  static func main() {
    if let wrapperExitCode = ImageWorkChildProcessLease.runWrapperIfRequested(arguments: CommandLine.arguments) {
      Darwin.exit(wrapperExitCode)
    }
    let agent = JeballtoAgent()
    agent.run()
  }

  func run() {
    if Self.isRunningUnderXCTest {
      let app = NSApplication.shared
      app.delegate = self
      app.setActivationPolicy(.accessory)
      app.run()
      return
    }

    logInfo("=== Jeballto VM Agent Starting ===", category: "Main")
    signal(SIGPIPE, SIG_IGN)

    let app = NSApplication.shared
    app.delegate = self
    app.setActivationPolicy(.accessory)

    // Create UI components synchronously before async init Task.
    // This eliminates the race between applicationDidFinishLaunching and the Task:
    // previously, if the Task completed before applicationDidFinishLaunching fired,
    // statusBarManager was nil and configure() was a silent no-op.
    let updaterManager = UpdaterManager()
    self.updaterManager = updaterManager
    let sbm = StatusBarManager()
    sbm.setup(updaterManager: updaterManager)
    statusBarManager = sbm

    Task<Void, Never> {
      do {
        singleInstanceLock = try SingleInstanceLock()
        let imageWorkSessionLock = try ImageWorkSessionLock(sessionURL: JeballtoCachePaths.imageWorkSession)
        self.imageWorkSessionLock = imageWorkSessionLock
        let imageWorkRoot = JeballtoCachePaths.imageWork
        let imageWorkSessionURL = imageWorkSessionLock.sessionURL
        await Task.detached(priority: .utility) {
          ImageManager.cleanupImageWorkDirectory(
            imageWorkRoot: imageWorkRoot,
            activeSessionURL: imageWorkSessionURL,
            exclusiveProcessOwnershipConfirmed: true
          )
        }.value
        try await loadConfiguration()
        try await initializeComponents()

        guard let vmManager, let apiServer else {
          throw AgentStartupError.componentsNotInitialized
        }

        await LocalNetworkPermission.trigger()

        try await vmManager.loadPersistedVMs()
        // Listener readiness is a blocking Network-framework bridge. Keep it off MainActor so
        // AppKit can finish launching and the menu-bar status remains responsive.
        try await Task.detached(priority: .userInitiated) {
          try apiServer.start()
        }.value

        setupSignalHandlers()

        if let config {
          logInfo("=== Jeballto VM Agent Started Successfully ===", category: "Main")
          logInfo("API Server: http://\(config.api.host):\(config.api.port)", category: "Main")
          logInfo("API Token: \(maskToken(config.api.token))", category: "Main")
          logInfo("Press Ctrl+C to stop", category: "Main")

          let totalVMs = try await vmManager.vmCount()
          await MainActor.run {
            statusBarManager?.configure(
              token: config.api.token,
              vmManager: vmManager,
              serverStartUptime: apiServer.startUptime,
              initialVMCount: totalVMs,
              logDirectory: config.logging.logDirectory
            )
          }
        }

      } catch {
        logError("Failed to start agent: \(error)", category: "Main")
        exit(1)
      }
    }

    app.run()
  }

  // MARK: - NSApplicationDelegate

  func applicationDidFinishLaunching(_ notification: Notification) {
    logInfo("Application did finish launching", category: "Main")
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard isTerminationInProgress == false else { return .terminateLater }
    isTerminationInProgress = true
    logInfo("=== Jeballto VM Agent Shutting Down ===", category: "Main")

    Task<Void, Never> {
      let cleanupTask = Task<Void, Never> { [apiServer, vmManager, portForwardingManager] in
        await apiServer?.stop()
        logInfo("API server stopped", category: "Main")

        ChildProcessTracker.shared.terminateAll()
        logInfo("Child processes terminated", category: "Main")

        await vmManager?.cleanupForShutdown()
        logInfo("VM shutdown cleanup complete", category: "Main")

        await portForwardingManager?.stopAllForwarding()
        logInfo("Port forwarding stopped", category: "Main")
      }

      let completed = await Self.waitForShutdownCleanup(cleanupTask, timeoutNanoseconds: 30_000_000_000)
      if completed == false {
        cleanupTask.cancel()
        ChildProcessTracker.shared.terminateAll()
        logError("Shutdown cleanup timed out after 30 seconds, terminating anyway", category: "Main")
      }

      logInfo("=== Jeballto VM Agent Stopped ===", category: "Main")
      NSApp.reply(toApplicationShouldTerminate: true)
    }

    return .terminateLater
  }

  // MARK: - Initialization

  private func loadConfiguration() async throws {
    logInfo("Loading configuration...", category: "Main")

    var loadedConfig = try await Task.detached(priority: .utility) {
      try Config.load()
    }.value
    loadedConfig.api.token = try await APISecretStore.shared.resolveToken(
      configurationCandidate: loadedConfig.api.token
    )
    let configToSave = loadedConfig
    try await Task.detached(priority: .utility) {
      try configToSave.save()
    }.value
    Logger.shared.configure(with: loadedConfig.logging)
    config = loadedConfig

    logInfo("Configuration loaded successfully", category: "Main")
  }

  private func initializeComponents() async throws {
    logInfo("Initializing components...", category: "Main")

    guard let config else {
      throw AgentStartupError.configurationNotLoaded
    }
    guard let imageWorkSessionLock else {
      throw AgentStartupError.imageWorkSessionNotInitialized
    }

    let eventBus = EventBus()
    self.eventBus = eventBus
    logInfo("Event bus initialized", category: "Main")

    let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
    self.persistenceStore = persistenceStore
    logInfo("Persistence store initialized: \(config.storage.databasePath)", category: "Main")

    let networkManager = NetworkManager(eventBus: eventBus)
    self.networkManager = networkManager
    logInfo("Network manager initialized", category: "Main")

    let portForwardingManager = PortForwardingManager(config: config.networking, eventBus: eventBus)
    self.portForwardingManager = portForwardingManager
    logInfo("Port forwarding manager initialized", category: "Main")

    let guiManager = await MainActor.run { GUIManager(eventBus: eventBus) }
    self.guiManager = guiManager
    logInfo("GUI manager initialized", category: "Main")

    let vmManager = VMManager(
      persistenceStore: persistenceStore,
      eventBus: eventBus,
      config: config,
      guiManager: guiManager,
      networkManager: networkManager,
      portForwardingManager: portForwardingManager
    )
    self.vmManager = vmManager
    logInfo("VM manager initialized", category: "Main")

    let imageStore = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
    guard let agentExecutableURL = Bundle.main.executableURL else {
      throw AgentStartupError.imageChildWrapperUnavailable
    }
    let childProcessLease = try imageWorkSessionLock.childProcessLease(
      wrapperExecutableURL: agentExecutableURL
    )
    let orasClient = OrasClient(
      config: config.images,
      temporaryRoot: imageWorkSessionLock.sessionURL,
      childProcessLease: childProcessLease
    )
    let imageManager = ImageManager(
      imageStore: imageStore,
      orasClient: orasClient,
      eventBus: eventBus,
      config: config
    )
    try await imageManager.recoverPendingDeletions()
    self.imageManager = imageManager
    logInfo("Image manager initialized", category: "Main")

    let apiServer = APIServer(
      vmManager: vmManager,
      portForwardingManager: portForwardingManager,
      imageManager: imageManager,
      eventBus: eventBus,
      config: config
    )
    self.apiServer = apiServer
    logInfo("API server initialized", category: "Main")

    logInfo("All components initialized successfully", category: "Main")
  }

  // MARK: - Signal Handling

  private func setupSignalHandlers() {
    // Handle SIGTERM (kill) and SIGINT (Ctrl+C)
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler { [weak self] in
      logInfo("Received SIGTERM, shutting down gracefully...", category: "Main")
      self?.shutdown()
    }
    termSource.resume()
    sigTermSource = termSource

    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intSource.setEventHandler { [weak self] in
      logInfo("Received SIGINT, shutting down gracefully...", category: "Main")
      self?.shutdown()
    }
    intSource.resume()
    sigIntSource = intSource

    logInfo("Signal handlers configured", category: "Main")
  }

  private func shutdown() {
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }

  private static var isRunningUnderXCTest: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  private static func waitForShutdownCleanup(_ task: Task<Void, Never>, timeoutNanoseconds: UInt64) async -> Bool {
    await withCheckedContinuation { continuation in
      let state = ShutdownWaitState(continuation: continuation)
      Task<Void, Never> {
        await task.value
        state.resume(true)
      }
      Task<Void, Never> {
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        state.resume(false)
      }
    }
  }
}

private final class ShutdownWaitState: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false
  private let continuation: CheckedContinuation<Bool, Never>

  init(continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func resume(_ value: Bool) {
    lock.lock()
    guard didResume == false else {
      lock.unlock()
      return
    }
    didResume = true
    lock.unlock()
    continuation.resume(returning: value)
  }
}

private enum AgentStartupError: Error, LocalizedError {
  case componentsNotInitialized
  case configurationNotLoaded
  case imageWorkSessionNotInitialized
  case imageChildWrapperUnavailable

  var errorDescription: String? {
    switch self {
    case .componentsNotInitialized:
      "Agent components were not initialized"
    case .configurationNotLoaded:
      "Agent configuration was not loaded"
    case .imageWorkSessionNotInitialized:
      "Image work session was not initialized"
    case .imageChildWrapperUnavailable:
      "Image child process wrapper executable is unavailable"
    }
  }
}

#else

@main struct JeballtoAgent {
  static func main() {
    print("Error: Jeballto VM Agent requires Apple Silicon (arm64)")
    print("This application only runs on Apple Silicon Macs")
    exit(1)
  }
}

#endif
