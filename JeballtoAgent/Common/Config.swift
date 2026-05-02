import Foundation

/// Configuration errors
enum ConfigError: Error, LocalizedError {
  case fileNotFound(String)
  case invalidFormat(String)
  case missingRequiredField(String)

  var errorDescription: String? {
    switch self {
    case .fileNotFound(let path): "Configuration file not found: \(path)"
    case .invalidFormat(let reason): "Invalid configuration format: \(reason)"
    case .missingRequiredField(let field): "Missing required configuration field: \(field)"
    }
  }
}

/// Application configuration
struct Config: Codable {
  /// API server configuration
  var api: APIConfig

  /// Storage configuration
  var storage: StorageConfig

  /// Logging configuration
  var logging: LoggingConfig

  /// Networking configuration
  var networking: NetworkingConfig

  /// OCI image management configuration
  var images: ImageConfig

  /// Default configuration values
  static var `default`: Config {
    Config(
      api: APIConfig(),
      storage: StorageConfig(),
      logging: LoggingConfig(),
      networking: NetworkingConfig(),
      images: ImageConfig()
    )
  }

  /// Loads configuration from disk, falling back to defaults if not found
  static func load(from path: String? = nil) throws -> Config {
    let configPath = path ?? defaultConfigPath()

    // If config doesn't exist, create it with defaults
    if !FileManager.default.fileExists(atPath: configPath) {
      let defaultConfig = Config.default
      try defaultConfig.save(to: configPath)
      return defaultConfig
    }

    // Load existing config
    let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let decoder = JSONDecoder()
    return try decoder.decode(Config.self, from: data)
  }

  /// Saves configuration to disk
  func save(to path: String? = nil) throws {
    let configPath = path ?? Config.defaultConfigPath()

    // Ensure directory exists
    let directory = (configPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

    // Encode and save
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)

    // Set restrictive permissions (owner read/write only) since config contains the API token
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
  }

  /// Returns the default configuration file path
  static func defaultConfigPath() -> String {
    "\(NSHomeDirectory())/Library/Application Support/Jeballto/config.json"
  }
}

/// API server configuration
struct APIConfig: Codable {
  /// API server port
  var port: Int

  /// Binding address. `127.0.0.1` for localhost-only access; `0.0.0.0` to bind all interfaces.
  var host: String

  /// Bearer token for API authentication. Auto-generated as a UUID on first run. Treat as a secret.
  var token: String

  /// Enable HTTPS (requires certificate)
  /// Note: HTTPS is not yet implemented - this flag is reserved for future use.
  var enableHTTPS: Bool

  /// Maximum number of concurrent requests
  var maxConcurrentRequests: Int

  init(
    port: Int = 8011,
    host: String = "0.0.0.0",
    token: String = UUID().uuidString,
    enableHTTPS: Bool = false,
    maxConcurrentRequests: Int = 100
  ) {
    self.port = port
    self.host = host
    self.token = token
    self.enableHTTPS = enableHTTPS
    self.maxConcurrentRequests = maxConcurrentRequests
  }
}

/// Storage configuration
struct StorageConfig: Codable {
  /// Base directory for VM storage
  var vmStorageDir: String

  /// Path to VM database
  var databasePath: String

  /// Path to image index
  var imageIndexPath: String

  init(vmStorageDir: String? = nil, databasePath: String? = nil, imageIndexPath: String? = nil) {
    let defaultBase = "\(NSHomeDirectory())/Library/Application Support/Jeballto"
    self.vmStorageDir = vmStorageDir ?? "\(defaultBase)/VMs"
    self.databasePath = databasePath ?? "\(defaultBase)/vms.json"
    self.imageIndexPath = imageIndexPath ?? "\(defaultBase)/images.json"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaultBase = "\(NSHomeDirectory())/Library/Application Support/Jeballto"
    vmStorageDir = try container.decodeIfPresent(String.self, forKey: .vmStorageDir) ?? "\(defaultBase)/VMs"
    databasePath = try container.decodeIfPresent(String.self, forKey: .databasePath) ?? "\(defaultBase)/vms.json"
    imageIndexPath = try container.decodeIfPresent(String.self, forKey: .imageIndexPath) ?? "\(defaultBase)/images.json"
  }
}

/// Logging configuration
struct LoggingConfig: Codable {
  /// Log level (debug, info, warning, error)
  var level: String

  /// Enable file logging
  var enableFileLogging: Bool

  /// Directory for log files
  var logDirectory: String

  /// Number of days to retain log files
  var retentionDays: Int

  /// Maximum total size of all log files (e.g. "2GB", "500MB")
  var maxTotalSize: String

  /// IANA timezone identifier for log timestamps (e.g. "UTC", "America/New_York"). nil = system timezone.
  var timezone: String?

  init(
    level: String = "info",
    enableFileLogging: Bool = true,
    logDirectory: String? = nil,
    retentionDays: Int = 7,
    maxTotalSize: String = "2GB",
    timezone: String? = nil
  ) {
    self.level = level
    self.enableFileLogging = enableFileLogging
    self.logDirectory = logDirectory ?? "\(NSHomeDirectory())/Library/Logs/Jeballto"
    self.retentionDays = retentionDays
    self.maxTotalSize = maxTotalSize
    self.timezone = timezone
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    level = try container.decodeIfPresent(String.self, forKey: .level) ?? "info"
    enableFileLogging = try container.decodeIfPresent(Bool.self, forKey: .enableFileLogging) ?? true
    logDirectory = try container.decodeIfPresent(String.self, forKey: .logDirectory)
      ?? "\(NSHomeDirectory())/Library/Logs/Jeballto"
    retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
    maxTotalSize = try container.decodeIfPresent(String.self, forKey: .maxTotalSize) ?? "2GB"
    timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
  }

  /// Parses a human-readable size string (e.g. "2GB", "500MB") into bytes.
  /// Supported units: MB, GB (case-insensitive). Returns nil for invalid input.
  static func parseSize(_ value: String) -> Int? {
    let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()
    if trimmed.hasSuffix("GB"), let num = Int(trimmed.dropLast(2).trimmingCharacters(in: .whitespaces)) {
      return num * 1_073_741_824
    }
    if trimmed.hasSuffix("MB"), let num = Int(trimmed.dropLast(2).trimmingCharacters(in: .whitespaces)) {
      return num * 1_048_576
    }
    return nil
  }
}

/// Networking configuration
struct NetworkingConfig: Codable {
  /// Starting port for SSH forwarding
  var sshPortRangeStart: Int

  /// Ending port for SSH forwarding
  var sshPortRangeEnd: Int

  /// Enable automatic port forwarding for new VMs
  var autoEnableSSHForwarding: Bool

  /// Starting port for VNC forwarding
  var vncPortRangeStart: Int

  /// Ending port for VNC forwarding
  var vncPortRangeEnd: Int

  init(
    sshPortRangeStart: Int = 2222,
    sshPortRangeEnd: Int = 2223,
    autoEnableSSHForwarding: Bool = true,
    vncPortRangeStart: Int = 5901,
    vncPortRangeEnd: Int = 5902
  ) {
    self.sshPortRangeStart = sshPortRangeStart
    self.sshPortRangeEnd = sshPortRangeEnd
    self.autoEnableSSHForwarding = autoEnableSSHForwarding
    self.vncPortRangeStart = vncPortRangeStart
    self.vncPortRangeEnd = vncPortRangeEnd
  }
}

/// OCI image management configuration
struct ImageConfig: Codable {
  /// Base directory for local image storage
  var imageStorageDir: String

  /// Path to the `oras` CLI binary. When `nil`, uses the binary bundled in the app's Resources directory.
  var orasPath: String?

  /// Default OCI registry (optional, used when reference has no registry prefix)
  var defaultRegistry: String?

  /// Registries allowed to use plain HTTP instead of HTTPS
  var insecureRegistries: [String]

  init(
    imageStorageDir: String? = nil,
    orasPath: String? = nil,
    defaultRegistry: String? = nil,
    insecureRegistries: [String] = []
  ) {
    let defaultBase = "\(NSHomeDirectory())/Library/Application Support/Jeballto"
    self.imageStorageDir = imageStorageDir ?? "\(defaultBase)/Images"
    self.orasPath = orasPath
    self.defaultRegistry = defaultRegistry
    self.insecureRegistries = insecureRegistries
  }
}
