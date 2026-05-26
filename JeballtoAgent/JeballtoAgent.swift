import Cocoa
import Foundation
import ServiceManagement
import Sparkle

#if arch(arm64)

@main class JeballtoAgent: NSObject, NSApplicationDelegate {
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

  /// Termination signal handlers (both must be retained to stay active)
  private var sigTermSource: DispatchSourceSignal?
  private var sigIntSource: DispatchSourceSignal?

  static func main() {
    let agent = JeballtoAgent()
    agent.run()
  }

  func run() {
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
        try loadConfiguration()
        try await initializeComponents()

        guard let vmManager, let apiServer else {
          throw NSError(
            domain: "JeballtoAgent",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Components not initialized"]
          )
        }

        await LocalNetworkPermission.trigger()

        try await vmManager.loadPersistedVMs()
        try apiServer.start()

        setupSignalHandlers()

        if let config {
          logInfo("=== Jeballto VM Agent Started Successfully ===", category: "Main")
          logInfo("API Server: http://\(config.api.host):\(config.api.port)", category: "Main")
          logInfo("API Token: \(maskToken(config.api.token))", category: "Main")
          logInfo("Press Ctrl+C to stop", category: "Main")

          let totalVMs = await vmManager.vmCount()
          await MainActor.run {
            statusBarManager?.configure(
              token: config.api.token,
              vmManager: vmManager,
              serverStartTime: apiServer.startTime,
              initialVMCount: totalVMs
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
    DispatchQueue.main.async {
      self.registerLoginItem()
    }
  }

  private func registerLoginItem() {
    let service = SMAppService.mainApp
    if service.status != .enabled {
      do {
        try service.register()
        logInfo("Registered as login item", category: "Main")
      } catch {
        logError("Failed to register as login item: \(error)", category: "Main")
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    logInfo("=== Jeballto VM Agent Shutting Down ===", category: "Main")

    Task<Void, Never> {
      apiServer?.stop()
      logInfo("API server stopped", category: "Main")

      ChildProcessTracker.shared.terminateAll()
      logInfo("Child processes terminated", category: "Main")

      await withTaskGroup(of: Void.self) { group in
        group.addTask { [vmManager, portForwardingManager] in
          await vmManager?.cleanupForShutdown()
          logInfo("VM shutdown cleanup complete", category: "Main")

          await portForwardingManager?.stopAllForwarding()
          logInfo("Port forwarding stopped", category: "Main")
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        await group.next()
        group.cancelAll()
      }

      logInfo("=== Jeballto VM Agent Stopped ===", category: "Main")
      NSApp.reply(toApplicationShouldTerminate: true)
    }

    return .terminateLater
  }

  // MARK: - Initialization

  private func loadConfiguration() throws {
    logInfo("Loading configuration...", category: "Main")

    let loadedConfig = try Config.load()
    Logger.shared.configure(with: loadedConfig.logging)
    config = loadedConfig

    logInfo("Configuration loaded successfully", category: "Main")
  }

  private func initializeComponents() async throws {
    logInfo("Initializing components...", category: "Main")

    guard let config else {
      throw NSError(
        domain: "JeballtoAgent",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Configuration not loaded"]
      )
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
    let orasClient = OrasClient(config: config.images)
    let imageManager = ImageManager(
      imageStore: imageStore,
      orasClient: orasClient,
      eventBus: eventBus,
      config: config
    )
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
