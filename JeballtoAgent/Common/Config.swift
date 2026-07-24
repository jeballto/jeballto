import Darwin
import Foundation
import Network

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
struct Config: Codable, Sendable {
  static let maximumConfigSize = 1_048_576

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
    try prepareWritableConfigDirectory(at: (configPath as NSString).deletingLastPathComponent)

    // If config doesn't exist, create it with defaults
    if !FileManager.default.fileExists(atPath: configPath) {
      let defaultConfig = Config.default
      try defaultConfig.save(to: configPath)
      return defaultConfig
    }

    let data = try readBoundedConfigData(at: configPath)
    let decoder = JSONDecoder()
    let config: Config
    do {
      config = try decoder.decode(Config.self, from: data)
    } catch let error as ConfigError {
      throw error
    } catch {
      throw ConfigError.invalidFormat(
        "Failed to decode configuration at \(configPath): \(error.localizedDescription)"
      )
    }
    try config.validate()
    return config
  }

  /// Saves configuration to disk
  func save(to path: String? = nil) throws {
    try validate()
    let configPath = path ?? Config.defaultConfigPath()

    let directory = (configPath as NSString).deletingLastPathComponent
    try Self.prepareWritableConfigDirectory(at: directory)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(self)
    } catch {
      throw ConfigError.invalidFormat("Failed to encode configuration: \(error.localizedDescription)")
    }
    guard data.count <= Self.maximumConfigSize else {
      throw ConfigError.invalidFormat("Encoded configuration exceeds the \(Self.maximumConfigSize)-byte limit")
    }
    do {
      try DurableMarkerStore.writeDataAtomically(
        data,
        to: configPath,
        maximumSize: Self.maximumConfigSize,
        permissions: 0o600
      )
    } catch {
      throw ConfigError.invalidFormat(
        "Failed to save configuration at \(configPath): \(error.localizedDescription)"
      )
    }
  }

  /// Returns the default configuration file path
  static func defaultConfigPath() -> String {
    "\(NSHomeDirectory())/Library/Application Support/Jeballto/config.json"
  }

  private static func readBoundedConfigData(at path: String) throws -> Data {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw ConfigError.invalidFormat("Failed to open configuration at \(path): \(posixMessage())")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw ConfigError.invalidFormat("Failed to inspect configuration at \(path): \(posixMessage())")
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw ConfigError.invalidFormat("Configuration at \(path) must be a regular file")
    }
    guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(maximumConfigSize) else {
      throw ConfigError.invalidFormat("Configuration at \(path) exceeds the \(maximumConfigSize)-byte limit")
    }

    do {
      let data = try handle.read(upToCount: maximumConfigSize + 1) ?? Data()
      guard data.count <= maximumConfigSize else {
        throw ConfigError.invalidFormat("Configuration at \(path) exceeds the \(maximumConfigSize)-byte limit")
      }
      return data
    } catch let error as ConfigError {
      throw error
    } catch {
      throw ConfigError.invalidFormat("Failed to read configuration at \(path): \(error.localizedDescription)")
    }
  }

  private static func prepareWritableConfigDirectory(at path: String) throws {
    var status = stat()
    let result = path.withCString { Darwin.lstat($0, &status) }
    if result == 0 {
      guard status.st_mode & S_IFMT == S_IFDIR else {
        throw ConfigError.invalidFormat("Configuration directory at \(path) must not be a symbolic link or file")
      }
      return
    }
    guard errno == ENOENT else {
      throw ConfigError.invalidFormat("Failed to inspect configuration directory at \(path): \(posixMessage())")
    }
    do {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    } catch {
      throw ConfigError.invalidFormat(
        "Failed to create configuration directory at \(path): \(error.localizedDescription)"
      )
    }
    guard path.withCString({ Darwin.lstat($0, &status) }) == 0,
          status.st_mode & S_IFMT == S_IFDIR else
    {
      throw ConfigError.invalidFormat("Created configuration path at \(path) is not a directory")
    }
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }

  func validate() throws {
    try api.validate()
    try storage.validate()
    try logging.validate()
    try networking.validate()
    try images.validate()

    let sshRange = networking.sshPortRangeStart ... networking.sshPortRangeEnd
    let vncRange = networking.vncPortRangeStart ... networking.vncPortRangeEnd
    guard sshRange.contains(api.port) == false, vncRange.contains(api.port) == false else {
      throw ConfigError.invalidFormat("api.port must not overlap an SSH or VNC forwarding port range")
    }

    let vmStoragePath = try ConfigPathValidator.directory(storage.vmStorageDir, label: "storage.vmStorageDir")
    let imageStoragePath = try ConfigPathValidator.directory(
      images.imageStorageDir,
      label: "images.imageStorageDir"
    )
    let logDirectoryPath = try ConfigPathValidator.directory(logging.logDirectory, label: "logging.logDirectory")
    guard ConfigPathValidator.pathsOverlap(vmStoragePath, imageStoragePath) == false else {
      throw ConfigError.invalidFormat("VM and image storage directories must not overlap")
    }
    guard ConfigPathValidator.pathsOverlap(vmStoragePath, logDirectoryPath) == false,
          ConfigPathValidator.pathsOverlap(imageStoragePath, logDirectoryPath) == false else
    {
      throw ConfigError.invalidFormat("Logging, VM, and image storage directories must not overlap")
    }

    let managedDataFiles = try [
      (storage.databasePath, "storage.databasePath"),
      (storage.databasePath + ".bak", "storage.databasePath backup"),
      (storage.imageIndexPath, "storage.imageIndexPath"),
      (storage.imageIndexPath + ".bak", "storage.imageIndexPath backup"),
    ].map { path, label in
      try (ConfigPathValidator.file(path, label: label), label)
    }
    for index in managedDataFiles.indices {
      for otherIndex in managedDataFiles.indices where otherIndex > index {
        guard ConfigPathValidator.pathsReferToDifferentEntries(
          managedDataFiles[index].0,
          managedDataFiles[otherIndex].0
        ) else {
          throw ConfigError.invalidFormat(
            "\(managedDataFiles[index].1) and \(managedDataFiles[otherIndex].1) must be different files"
          )
        }
      }
    }
    for (path, label) in managedDataFiles
      where ConfigPathValidator.path(path, isInside: vmStoragePath)
      || ConfigPathValidator.path(path, isInside: imageStoragePath)
      || ConfigPathValidator.path(path, isInside: logDirectoryPath)
    {
      throw ConfigError.invalidFormat("\(label) must be outside VM, image, and log directories")
    }
  }
}

private enum ConfigPathValidator {
  static func directory(_ path: String, label: String) throws -> String {
    let normalized = try absolute(path, label: label)
    let homeDirectory = (NSHomeDirectory() as NSString).standardizingPath
    guard normalized != "/", normalized != homeDirectory else {
      throw ConfigError.invalidFormat("\(label) must be a dedicated directory, not the filesystem or home root")
    }
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue == false {
      throw ConfigError.invalidFormat("\(label) must be a directory, not a regular file")
    }
    return normalized
  }

  static func file(_ path: String, label: String) throws -> String {
    let normalized = try absolute(path, label: label)
    let homeDirectory = (NSHomeDirectory() as NSString).standardizingPath
    guard normalized != "/", normalized != homeDirectory else {
      throw ConfigError.invalidFormat("\(label) must be a file path, not the filesystem or home root")
    }
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue {
      throw ConfigError.invalidFormat("\(label) must be a regular file, not a directory")
    }
    return normalized
  }

  static func executableFile(_ path: String, label: String) throws -> String {
    let normalized = try file(path, label: label)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
          isDirectory.boolValue == false else
    {
      throw ConfigError.invalidFormat("\(label) must point to an existing regular file")
    }
    guard FileManager.default.isExecutableFile(atPath: normalized) else {
      throw ConfigError.invalidFormat("\(label) must point to an executable file")
    }
    return normalized
  }

  static func pathsOverlap(_ first: String, _ second: String) -> Bool {
    pathsReferToSameEntry(first, second)
      || path(first, isInside: second)
      || path(second, isInside: first)
  }

  static func path(_ path: String, isInside directory: String) -> Bool {
    let pathKey = filesystemComparisonKey(path)
    let directoryKey = filesystemComparisonKey(directory)
    return pathKey == directoryKey || pathKey.hasPrefix(directoryKey + "/")
  }

  static func pathsReferToDifferentEntries(_ first: String, _ second: String) -> Bool {
    pathsReferToSameEntry(first, second) == false
  }

  private static func pathsReferToSameEntry(_ first: String, _ second: String) -> Bool {
    filesystemComparisonKey(first) == filesystemComparisonKey(second)
  }

  private static func filesystemComparisonKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
  }

  private static func absolute(_ path: String, label: String) throws -> String {
    guard path.hasPrefix("/") else {
      throw ConfigError.invalidFormat("\(label) must be an absolute path")
    }
    return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
}

/// API server configuration
enum APIToken {
  static let minimumLength = 32
  static let maximumLength = 512

  static func generate() -> String {
    UUID().uuidString
  }

  static func isValid(_ token: String) -> Bool {
    guard (minimumLength ... maximumLength).contains(token.utf8.count) else { return false }
    return token.utf8.allSatisfy { (0x21 ... 0x7E).contains($0) }
  }
}

struct APIConfig: Codable, Sendable {
  /// API server port
  var port: Int

  /// Binding address. `127.0.0.1` for localhost-only access; `0.0.0.0` to bind all interfaces.
  var host: String

  /// Bearer token for API authentication. Auto-generated as a UUID on first run. Treat as a secret.
  var token: String

  /// Maximum number of concurrent requests
  var maxConcurrentRequests: Int

  init(
    port: Int = 8011,
    host: String = "0.0.0.0",
    token: String = APIToken.generate(),
    maxConcurrentRequests: Int = 100
  ) {
    self.port = port
    self.host = host
    self.token = token
    self.maxConcurrentRequests = maxConcurrentRequests
  }

  private enum CodingKeys: String, CodingKey {
    case port
    case host
    case maxConcurrentRequests
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8011
    host = try container.decodeIfPresent(String.self, forKey: .host) ?? "0.0.0.0"
    token = APIToken.generate()
    maxConcurrentRequests = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRequests) ?? 100
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(port, forKey: .port)
    try container.encode(host, forKey: .host)
    try container.encode(maxConcurrentRequests, forKey: .maxConcurrentRequests)
  }

  func validate() throws {
    guard (1 ... 65535).contains(port) else {
      throw ConfigError.invalidFormat("api.port must be between 1 and 65535")
    }
    guard Self.isValidBindHost(host) else {
      throw ConfigError.invalidFormat("api.host must be a valid IP address or localhost")
    }
    guard APIToken.isValid(token) else {
      throw ConfigError.invalidFormat("api.token must be 32-512 printable ASCII characters")
    }
    guard (1 ... 10000).contains(maxConcurrentRequests) else {
      throw ConfigError.invalidFormat("api.maxConcurrentRequests must be between 1 and 10000")
    }
  }

  private static func isValidBindHost(_ host: String) -> Bool {
    guard host.trimmingCharacters(in: .whitespacesAndNewlines) == host, host.isEmpty == false else {
      return false
    }
    if host == "localhost" { return true }
    if IPv4Address(host) != nil || IPv6Address(host) != nil { return true }
    return false
  }
}

/// Storage configuration
struct StorageConfig: Codable, Sendable {
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

  func validate() throws {
    guard vmStorageDir.isEmpty == false else {
      throw ConfigError.invalidFormat("storage.vmStorageDir must not be empty")
    }
    guard databasePath.isEmpty == false else {
      throw ConfigError.invalidFormat("storage.databasePath must not be empty")
    }
    guard imageIndexPath.isEmpty == false else {
      throw ConfigError.invalidFormat("storage.imageIndexPath must not be empty")
    }
  }
}

/// Logging configuration
struct LoggingConfig: Codable, Sendable {
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
      guard num > 0 else { return nil }
      let result = num.multipliedReportingOverflow(by: 1_073_741_824)
      return result.overflow ? nil : result.partialValue
    }
    if trimmed.hasSuffix("MB"), let num = Int(trimmed.dropLast(2).trimmingCharacters(in: .whitespaces)) {
      guard num > 0 else { return nil }
      let result = num.multipliedReportingOverflow(by: 1_048_576)
      return result.overflow ? nil : result.partialValue
    }
    return nil
  }

  func validate() throws {
    let validLogLevels = ["debug", "info", "warning", "error"]
    guard validLogLevels.contains(level) else {
      throw ConfigError.invalidFormat("logging.level must be one of: \(validLogLevels.joined(separator: ", "))")
    }
    guard logDirectory.isEmpty == false else {
      throw ConfigError.invalidFormat("logging.logDirectory must not be empty")
    }
    guard retentionDays >= 1 else {
      throw ConfigError.invalidFormat("logging.retentionDays must be at least 1")
    }
    guard let maxSize = Self.parseSize(maxTotalSize), maxSize >= 1_048_576 else {
      throw ConfigError.invalidFormat("logging.maxTotalSize must be at least 1MB")
    }
    if let timezone, TimeZone(identifier: timezone) == nil {
      throw ConfigError.invalidFormat("logging.timezone must be a valid IANA timezone identifier")
    }
  }
}

/// Networking configuration
struct NetworkingConfig: Codable, Sendable {
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

  func validate() throws {
    try Self.validateRange(start: sshPortRangeStart, end: sshPortRangeEnd, label: "networking SSH")
    try Self.validateRange(start: vncPortRangeStart, end: vncPortRangeEnd, label: "networking VNC")
    let rangesOverlap = sshPortRangeStart <= vncPortRangeEnd && vncPortRangeStart <= sshPortRangeEnd
    guard rangesOverlap == false else {
      throw ConfigError.invalidFormat("networking SSH and VNC port ranges must not overlap")
    }
  }

  private static func validateRange(start: Int, end: Int, label: String) throws {
    guard (1024 ... 65535).contains(start) else {
      throw ConfigError.invalidFormat("\(label) port range start must be 1024-65535")
    }
    guard (1024 ... 65535).contains(end) else {
      throw ConfigError.invalidFormat("\(label) port range end must be 1024-65535")
    }
    guard start <= end else {
      throw ConfigError.invalidFormat("\(label) port range start must not exceed end")
    }
  }
}

/// OCI image management configuration
struct ImageConfig: Codable, Sendable {
  static let defaultMaxParallelImageBlobTransfers = 16
  static let defaultMaxParallelImageCompressions = 4
  static let defaultMaxParallelImageDecompressions = 2
  static let defaultMaxParallelImageDiskWrites = 1
  static let maximumParallelImageBlobTransfers = 64
  static let maximumParallelImageCompressions = 32
  static let maximumParallelImageDecompressions = 8
  static let maximumParallelImageDiskWrites = 4

  /// Base directory for local image storage
  var imageStorageDir: String

  /// Path to the `oras` CLI binary. When `nil`, uses the binary bundled in the app's Resources directory.
  var orasPath: String?

  /// Path to the `zstd` CLI binary. When `nil`, uses the binary bundled in the app's Resources directory.
  var zstdPath: String?

  /// Maximum number of OCI image blob transfers to run concurrently.
  var maxParallelImageBlobTransfers: Int

  /// Maximum number of image chunks to compress concurrently while pushing.
  var maxParallelImageCompressions: Int

  /// Maximum number of image chunks to decompress concurrently while pulling.
  var maxParallelImageDecompressions: Int

  /// Maximum number of image chunk writes to perform concurrently while pulling.
  var maxParallelImageDiskWrites: Int

  /// Default OCI registry (optional, used when reference has no registry prefix)
  var defaultRegistry: String?

  /// Registries allowed to use plain HTTP instead of HTTPS
  var insecureRegistries: [String]

  init(
    imageStorageDir: String? = nil,
    orasPath: String? = nil,
    zstdPath: String? = nil,
    maxParallelImageBlobTransfers: Int = Self.defaultMaxParallelImageBlobTransfers,
    maxParallelImageCompressions: Int = Self.defaultMaxParallelImageCompressions,
    maxParallelImageDecompressions: Int = Self.defaultMaxParallelImageDecompressions,
    maxParallelImageDiskWrites: Int = Self.defaultMaxParallelImageDiskWrites,
    defaultRegistry: String? = nil,
    insecureRegistries: [String] = []
  ) {
    let defaultBase = "\(NSHomeDirectory())/Library/Application Support/Jeballto"
    self.imageStorageDir = imageStorageDir ?? "\(defaultBase)/Images"
    self.orasPath = orasPath
    self.zstdPath = zstdPath
    self.maxParallelImageBlobTransfers = maxParallelImageBlobTransfers
    self.maxParallelImageCompressions = maxParallelImageCompressions
    self.maxParallelImageDecompressions = maxParallelImageDecompressions
    self.maxParallelImageDiskWrites = maxParallelImageDiskWrites
    self.defaultRegistry = defaultRegistry
    self.insecureRegistries = insecureRegistries
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaultBase = "\(NSHomeDirectory())/Library/Application Support/Jeballto"
    imageStorageDir = try container.decodeIfPresent(String.self, forKey: .imageStorageDir) ?? "\(defaultBase)/Images"
    orasPath = try container.decodeIfPresent(String.self, forKey: .orasPath)
    zstdPath = try container.decodeIfPresent(String.self, forKey: .zstdPath)
    maxParallelImageBlobTransfers = try container.decodeIfPresent(
      Int.self,
      forKey: .maxParallelImageBlobTransfers
    ) ?? Self.defaultMaxParallelImageBlobTransfers
    maxParallelImageCompressions = try container.decodeIfPresent(
      Int.self,
      forKey: .maxParallelImageCompressions
    ) ?? Self.defaultMaxParallelImageCompressions
    maxParallelImageDecompressions = try container.decodeIfPresent(
      Int.self,
      forKey: .maxParallelImageDecompressions
    ) ?? Self.defaultMaxParallelImageDecompressions
    maxParallelImageDiskWrites = try container.decodeIfPresent(
      Int.self,
      forKey: .maxParallelImageDiskWrites
    ) ?? Self.defaultMaxParallelImageDiskWrites
    try Self.validateParallelism(
      maxParallelImageBlobTransfers: maxParallelImageBlobTransfers,
      maxParallelImageCompressions: maxParallelImageCompressions,
      maxParallelImageDecompressions: maxParallelImageDecompressions,
      maxParallelImageDiskWrites: maxParallelImageDiskWrites
    )
    defaultRegistry = try container.decodeIfPresent(String.self, forKey: .defaultRegistry)
    insecureRegistries = try container.decodeIfPresent([String].self, forKey: .insecureRegistries) ?? []
  }

  func validate() throws {
    guard imageStorageDir.isEmpty == false else {
      throw ConfigError.invalidFormat("images.imageStorageDir must not be empty")
    }
    try Self.validateParallelism(
      maxParallelImageBlobTransfers: maxParallelImageBlobTransfers,
      maxParallelImageCompressions: maxParallelImageCompressions,
      maxParallelImageDecompressions: maxParallelImageDecompressions,
      maxParallelImageDiskWrites: maxParallelImageDiskWrites
    )
    if let orasPath {
      _ = try ConfigPathValidator.executableFile(orasPath, label: "images.orasPath")
    }
    if let zstdPath {
      _ = try ConfigPathValidator.executableFile(zstdPath, label: "images.zstdPath")
    }
    if let defaultRegistry, ImageReference.isValidRegistry(defaultRegistry) == false {
      throw ConfigError.invalidFormat("images.defaultRegistry must be a lowercase hostname with an optional valid port")
    }
    var uniqueRegistries: Set<String> = []
    for registry in insecureRegistries {
      guard ImageReference.isValidRegistry(registry) else {
        throw ConfigError.invalidFormat(
          "images.insecureRegistries entries must be lowercase hostnames with optional valid ports"
        )
      }
      guard uniqueRegistries.insert(registry).inserted else {
        throw ConfigError.invalidFormat("images.insecureRegistries must not contain duplicates")
      }
    }
  }

  private static func validateParallelism(
    maxParallelImageBlobTransfers: Int,
    maxParallelImageCompressions: Int,
    maxParallelImageDecompressions: Int,
    maxParallelImageDiskWrites: Int
  ) throws {
    guard (1 ... maximumParallelImageBlobTransfers).contains(maxParallelImageBlobTransfers) else {
      throw ConfigError.invalidFormat(
        "images.maxParallelImageBlobTransfers must be between 1 and \(maximumParallelImageBlobTransfers)"
      )
    }
    guard (1 ... maximumParallelImageCompressions).contains(maxParallelImageCompressions) else {
      throw ConfigError.invalidFormat(
        "images.maxParallelImageCompressions must be between 1 and \(maximumParallelImageCompressions)"
      )
    }
    guard (1 ... maximumParallelImageDecompressions).contains(maxParallelImageDecompressions) else {
      throw ConfigError.invalidFormat(
        "images.maxParallelImageDecompressions must be between 1 and \(maximumParallelImageDecompressions)"
      )
    }
    guard (1 ... maximumParallelImageDiskWrites).contains(maxParallelImageDiskWrites) else {
      throw ConfigError.invalidFormat(
        "images.maxParallelImageDiskWrites must be between 1 and \(maximumParallelImageDiskWrites)"
      )
    }
  }
}
