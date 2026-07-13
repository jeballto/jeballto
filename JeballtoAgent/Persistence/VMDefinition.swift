import Darwin
import Foundation

/// Complete definition of a virtual machine including all configuration and metadata
struct VMDefinition: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var state: VMState
  var ephemeral: Bool
  var resources: VMResources
  var network: VMNetwork
  var paths: VMPaths
  var metadata: [String: String]
  /// Installation lifecycle persisted independently from the runtime VM state.
  var installation: VMInstallation?
  /// True after the guest reached `running` at least once.
  var hasBooted: Bool
  /// Max lifetime in seconds from first `.running` transition. `nil` = no TTL.
  var lifetimeSeconds: Int?
  /// Absolute expiry instant; set when the VM first enters `.running`. Persisted so TTL survives restart.
  var expiresAt: Date?
  let createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    name: String,
    state: VMState = .created,
    ephemeral: Bool = false,
    resources: VMResources,
    network: VMNetwork = VMNetwork(),
    paths: VMPaths,
    metadata: [String: String] = [:],
    installation: VMInstallation? = nil,
    hasBooted: Bool = false,
    lifetimeSeconds: Int? = nil,
    expiresAt: Date? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.state = state
    self.ephemeral = ephemeral
    self.resources = resources
    self.network = network
    self.paths = paths
    self.metadata = metadata
    self.installation = installation
    self.hasBooted = hasBooted
    self.lifetimeSeconds = lifetimeSeconds
    self.expiresAt = expiresAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// Updates the VM state and sets updatedAt timestamp
  mutating func updateState(_ newState: VMState) {
    state = newState
    updatedAt = Date()
  }

  /// Updates the SSH port assignment
  mutating func updateSSHPort(_ port: Int) {
    network.sshPort = port
    updatedAt = Date()
  }

  /// Updates the VNC port assignment
  mutating func updateVNCPort(_ port: Int) {
    network.vncPort = port
    updatedAt = Date()
  }

  /// Clears the VNC port assignment
  mutating func clearVNCPort() {
    network.vncPort = nil
    updatedAt = Date()
  }

  mutating func updateNATIP(_ ip: String) {
    network.natIP = ip
    updatedAt = Date()
  }

  mutating func clearNATIP() {
    network.natIP = nil
    updatedAt = Date()
  }

  mutating func clearSSHPort() {
    network.sshPort = nil
    updatedAt = Date()
  }

  mutating func setExpiry(_ date: Date) {
    expiresAt = date
    updatedAt = Date()
  }

  mutating func clearExpiry() {
    expiresAt = nil
    updatedAt = Date()
  }

  mutating func markBooted() {
    hasBooted = true
    updatedAt = Date()
  }

  mutating func updateInstallation(_ installation: VMInstallation) {
    self.installation = installation
    updatedAt = Date()
  }
}

/// Durable installation lifecycle for a VM.
struct VMInstallation: Codable, Equatable, Sendable {
  enum State: String, Codable, Equatable, Sendable {
    case installing
    case finalizing
    case completed
    case failed
    case cancelled
    case interrupted

    var isActive: Bool { self == .installing || self == .finalizing }
  }

  var state: State
  var message: String
  var error: String?
  let startedAt: Date
  var updatedAt: Date
  var completedAt: Date?

  init(
    state: State,
    message: String,
    error: String? = nil,
    startedAt: Date = Date(),
    updatedAt: Date = Date(),
    completedAt: Date? = nil
  ) {
    self.state = state
    self.message = message
    self.error = error
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.completedAt = completedAt
  }

  mutating func finish(as state: State, message: String, error: String? = nil) {
    self.state = state
    self.message = message
    self.error = error
    updatedAt = Date()
    completedAt = Date()
  }

  static func completed(message: String, at date: Date = Date()) -> VMInstallation {
    VMInstallation(
      state: .completed,
      message: message,
      startedAt: date,
      updatedAt: date,
      completedAt: date
    )
  }
}

/// Hardware resource configuration for a VM
struct VMResources: Codable, Equatable, Sendable {
  var cpuCount: Int
  /// Memory allocated to the VM, in bytes. Use `memoryGB` for display.
  var memorySize: UInt64
  /// Disk image size, in bytes. Use `diskGB` for display.
  var diskSize: UInt64

  /// Default configuration: 4 CPUs, 4GB RAM, 64GB disk
  static var `default`: VMResources {
    VMResources(
      cpuCount: 4,
      memorySize: 4 * 1024 * 1024 * 1024, // 4GB
      diskSize: 64 * 1024 * 1024 * 1024 // 64GB
    )
  }

  /// Validates that resources are within acceptable bounds
  func validate() -> Bool {
    cpuCount >= 1 && cpuCount <= 32
      && memorySize >= 2 * 1024 * 1024 * 1024
      && memorySize <= 128 * 1024 * 1024 * 1024
      && diskSize >= 20 * 1024 * 1024 * 1024
      && diskSize <= 8 * 1024 * 1024 * 1024 * 1024
  }

  /// Returns memory size in GB for display
  var memoryGB: Double { Double(memorySize) / (1024 * 1024 * 1024) }

  /// Returns disk size in GB for display
  var diskGB: Double { Double(diskSize) / (1024 * 1024 * 1024) }
}

/// Network configuration for a VM
struct VMNetwork: Codable, Equatable, Sendable {
  var macAddress: String
  var sshPort: Int?
  var vncPort: Int?
  /// NAT IP assigned by the Virtualization framework's DHCP server after the VM boots.
  /// `nil` until DHCP assignment completes - typically a few seconds after `vmRunning` is published.
  var natIP: String?

  init(macAddress: String? = nil, sshPort: Int? = nil, vncPort: Int? = nil, natIP: String? = nil) {
    self.macAddress = macAddress ?? VMNetwork.generateMACAddress()
    self.sshPort = sshPort
    self.vncPort = vncPort
    self.natIP = natIP
  }

  /// Generates a random MAC address in the locally administered unicast range
  static func generateMACAddress() -> String {
    let bytes = (0 ..< 6).map { index -> UInt8 in
      if index == 0 {
        // First byte: set locally administered bit (bit 1) and clear multicast bit (bit 0)
        // This ensures a valid unicast, locally administered address
        return (UInt8.random(in: 0 ... 255) | 0x02) & 0xFE
      } else {
        return UInt8.random(in: 0 ... 255)
      }
    }
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
  }

  /// Validates MAC address format
  var isValidMACAddress: Bool {
    let pattern = "^([0-9A-Fa-f]{2}:){5}([0-9A-Fa-f]{2})$"
    guard macAddress.range(of: pattern, options: .regularExpression) != nil,
          let firstOctetText = macAddress.split(separator: ":").first,
          let firstOctet = UInt8(firstOctetText, radix: 16) else
    {
      return false
    }
    return firstOctet & 0x01 == 0 && firstOctet & 0x02 == 0x02
  }

  var isValidNATIPAddress: Bool {
    guard let natIP else { return true }
    var address = in_addr()
    return natIP.withCString { inet_pton(AF_INET, $0, &address) == 1 }
  }
}

/// File paths associated with a VM bundle
struct VMPaths: Codable, Equatable, Sendable {
  var bundlePath: String
  var diskImagePath: String
  /// NVRAM data required by the Virtualization framework. Must not be deleted while the VM is running.
  var auxiliaryStoragePath: String
  var hardwareModelPath: String
  var machineIdentifierPath: String
  /// Path where VM save state is written (`SaveFile.vzvmsave`). The path is configured for every VM bundle.
  /// The file itself exists only while a saved paused state is present.
  var saveFilePath: String

  /// Creates paths for a VM with the given ID in the standard location
  static func forVM(id: UUID, baseDir: String? = nil) -> VMPaths {
    // If baseDir is provided, it's already the full VM storage directory
    // Otherwise, construct the default path
    let vmStorageDir: String
    if let baseDir {
      // baseDir is already the full path (e.g., "/Users/.../Jeballto/VMs")
      vmStorageDir = baseDir
    } else {
      // Construct default path using Apple's recommended API
      let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Jeballto").appendingPathComponent("VMs")
      vmStorageDir = appSupportURL.path
    }

    let bundlePath = "\(vmStorageDir)/\(id.uuidString).bundle"

    return VMPaths(
      bundlePath: bundlePath,
      diskImagePath: "\(bundlePath)/Disk.img",
      auxiliaryStoragePath: "\(bundlePath)/AuxiliaryStorage",
      hardwareModelPath: "\(bundlePath)/HardwareModel",
      machineIdentifierPath: "\(bundlePath)/MachineIdentifier",
      saveFilePath: "\(bundlePath)/SaveFile.vzvmsave"
    )
  }

  /// Checks if all required files exist
  func allFilesExist() -> Bool {
    let fileManager = FileManager.default
    return fileManager.fileExists(atPath: diskImagePath) && fileManager.fileExists(atPath: auxiliaryStoragePath)
      && fileManager.fileExists(atPath: hardwareModelPath) && fileManager.fileExists(atPath: machineIdentifierPath)
  }

  /// Checks if bundle directory exists
  func bundleExists() -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: bundlePath, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }
}

/// Top-level database structure containing all VMs
struct VMDatabase: Codable, Sendable {
  var version: Int
  var vms: [UUID: VMDefinition]

  init(version: Int = 1, vms: [UUID: VMDefinition] = [:]) {
    self.version = version
    self.vms = vms
  }

  /// Creates an empty database with current version
  static var empty: VMDatabase { VMDatabase(version: 1, vms: [:]) }
}
