import Foundation
@testable import JeballtoAgent

func makeTestConfig(root: String) -> Config {
  Config(
    api: APIConfig(port: 18080, host: "127.0.0.1", token: "test-token", enableHTTPS: false, maxConcurrentRequests: 10),
    storage: StorageConfig(vmStorageDir: "\(root)/vms", databasePath: "\(root)/vms.json"),
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
  capabilityProvider: @escaping @Sendable () -> VirtualizationCapabilities = { testVirtualizationCapabilities() }
) -> APIServer {
  let config = makeTestConfig(root: root)
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
  let imageStore = ImageStore(storagePath: config.images.imageStorageDir)
  let orasClient = OrasClient(config: config.images)
  let imageManager = ImageManager(imageStore: imageStore, orasClient: orasClient, eventBus: eventBus, config: config)

  return APIServer(
    vmManager: vmManager,
    portForwardingManager: portForwardingManager,
    imageManager: imageManager,
    eventBus: eventBus,
    config: config,
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
