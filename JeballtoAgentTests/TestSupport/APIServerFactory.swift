import Foundation
@testable import JeballtoAgent

func makeTestConfig(root: String) -> Config {
  Config(
    api: APIConfig(
      port: 18080,
      host: "127.0.0.1",
      token: "test-token-1234567890-abcdefghijkl",
      maxConcurrentRequests: 10
    ),
    storage: StorageConfig(
      vmStorageDir: "\(root)/vms",
      databasePath: "\(root)/vms.json",
      imageIndexPath: "\(root)/images.json"
    ),
    logging: LoggingConfig(
      level: "debug",
      enableFileLogging: false,
      logDirectory: "\(root)/logs",
      retentionDays: 1,
      maxTotalSize: "10MB"
    ),
    networking: NetworkingConfig(
      sshPortRangeStart: 2222,
      sshPortRangeEnd: 2223,
      autoEnableSSHForwarding: false,
      vncPortRangeStart: 5901,
      vncPortRangeEnd: 5902
    ),
    images: ImageConfig(
      imageStorageDir: "\(root)/images",
      orasPath: "/usr/bin/false",
      defaultRegistry: nil,
      insecureRegistries: []
    )
  )
}

func makeTestAPIServer(
  root: String,
  configure: (inout Config) -> Void = { _ in },
  useLiveRegistryAvailabilityCheck: Bool = false,
  capabilityProvider: @escaping @Sendable () -> VirtualizationCapabilities = { testVirtualizationCapabilities() },
  systemResetEnvironment: SystemResetEnvironment? = nil
) -> APIServer {
  var config = makeTestConfig(root: root)
  configure(&config)
  let eventBus = EventBus()
  let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
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
  let imageStore = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
  let orasClient = OrasClient(
    config: config.images,
    temporaryRoot: URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("cache/ImageWork/sessions/\(UUID().uuidString)", isDirectory: true),
    credentialStore: makeTestRegistryCredentialStore()
  )
  let registryAvailabilityChecker: RegistryAvailabilityChecker? = if useLiveRegistryAvailabilityCheck {
    nil
  } else {
    { _, _ in }
  }
  let imageManager = ImageManager(
    imageStore: imageStore,
    orasClient: orasClient,
    eventBus: eventBus,
    config: config,
    diskImageCapacityValidator: { _, _ in },
    registryAvailabilityChecker: registryAvailabilityChecker
  )
  let resetEnvironment = systemResetEnvironment ?? SystemResetEnvironment(
    appSupportDirectory: "\(root)/app-support",
    defaultLogDirectory: "\(root)/default-logs",
    cacheRoot: URL(fileURLWithPath: "\(root)/cache", isDirectory: true),
    deleteSecrets: {},
    terminate: {}
  )

  return APIServer(
    vmManager: vmManager,
    portForwardingManager: portForwardingManager,
    imageManager: imageManager,
    eventBus: eventBus,
    config: config,
    configPath: "\(root)/config.json",
    systemResetEnvironment: resetEnvironment,
    capabilityProvider: capabilityProvider
  )
}

func testVirtualizationCapabilities() -> VirtualizationCapabilities {
  VirtualizationCapabilities(
    probe: VirtualizationHostProbe(
      architecture: "arm64",
      operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
      virtualizationSupported: true,
      entitlements: ["com.apple.security.virtualization"]
    )
  )
}
