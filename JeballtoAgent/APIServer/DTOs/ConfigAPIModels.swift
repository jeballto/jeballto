import Foundation

/// Safe subset of configuration, excluding tokens and file paths.
struct ConfigResponse: Codable {
  let api: APIConfigResponse
  let logging: LoggingConfigResponse
  let networking: NetworkingConfigResponse
  let images: ImageConfigResponse

  init(from config: Config) {
    api = APIConfigResponse(from: config.api)
    logging = LoggingConfigResponse(from: config.logging)
    networking = NetworkingConfigResponse(from: config.networking)
    images = ImageConfigResponse(from: config.images)
  }
}

struct APIConfigResponse: Codable {
  let port: Int
  let host: String
  let enableHTTPS: Bool
  let maxConcurrentRequests: Int

  init(from config: APIConfig) {
    port = config.port
    host = config.host
    enableHTTPS = config.enableHTTPS
    maxConcurrentRequests = config.maxConcurrentRequests
  }
}

struct LoggingConfigResponse: Codable {
  let level: String
  let enableFileLogging: Bool
  let retentionDays: Int
  let maxTotalSize: String
  let timezone: String?

  init(from config: LoggingConfig) {
    level = config.level
    enableFileLogging = config.enableFileLogging
    retentionDays = config.retentionDays
    maxTotalSize = config.maxTotalSize
    timezone = config.timezone
  }
}

struct NetworkingConfigResponse: Codable {
  let sshPortRangeStart: Int
  let sshPortRangeEnd: Int
  let autoEnableSSHForwarding: Bool
  let vncPortRangeStart: Int
  let vncPortRangeEnd: Int

  init(from config: NetworkingConfig) {
    sshPortRangeStart = config.sshPortRangeStart
    sshPortRangeEnd = config.sshPortRangeEnd
    autoEnableSSHForwarding = config.autoEnableSSHForwarding
    vncPortRangeStart = config.vncPortRangeStart
    vncPortRangeEnd = config.vncPortRangeEnd
  }
}

struct ImageConfigResponse: Codable {
  let defaultRegistry: String?
  let insecureRegistries: [String]
  let maxParallelImageBlobTransfers: Int
  let maxParallelImageCompressions: Int
  let maxParallelImageDecompressions: Int
  let maxParallelImageDiskWrites: Int

  init(from config: ImageConfig) {
    defaultRegistry = config.defaultRegistry
    insecureRegistries = config.insecureRegistries
    maxParallelImageBlobTransfers = config.maxParallelImageBlobTransfers
    maxParallelImageCompressions = config.maxParallelImageCompressions
    maxParallelImageDecompressions = config.maxParallelImageDecompressions
    maxParallelImageDiskWrites = config.maxParallelImageDiskWrites
  }
}

/// Request to update writable config values.
struct UpdateConfigRequest: Codable {
  let logging: LoggingConfigUpdate?
  let networking: NetworkingConfigUpdate?
  let images: ImageConfigUpdate?

  private static let validLogLevels = ["debug", "info", "warning", "error"]

  func validate(currentConfig: NetworkingConfig? = nil) -> (valid: Bool, error: String?) {
    if logging == nil, networking == nil, images == nil {
      return (false, "At least one supported config section must be provided: logging, networking, or images")
    }
    if let error = Self.validateLogging(logging) {
      return (false, error)
    }
    if let error = Self.validateNetworking(networking, currentConfig: currentConfig) {
      return (false, error)
    }
    if let error = Self.validateImages(images) {
      return (false, error)
    }
    return (true, nil)
  }

  private static func validateLogging(_ logging: LoggingConfigUpdate?) -> String? {
    guard let logging else { return nil }

    if let level = logging.level, !validLogLevels.contains(level) {
      return "Invalid log level. Must be one of: \(validLogLevels.joined(separator: ", "))"
    }
    if let retentionDays = logging.retentionDays, retentionDays < 1 {
      return "retentionDays must be at least 1"
    }
    if let error = validateLogSize(logging.maxTotalSize) {
      return error
    }
    if let timezone = logging.timezone, let tz = timezone, TimeZone(identifier: tz) == nil {
      return "Invalid timezone identifier '\(tz)'. Use an IANA timezone name (e.g. 'UTC', 'America/New_York')."
    }
    return nil
  }

  private static func validateLogSize(_ maxTotalSize: String?) -> String? {
    guard let maxTotalSize else { return nil }
    guard let bytes = LoggingConfig.parseSize(maxTotalSize) else {
      return "maxTotalSize must be a value with unit, e.g. \"500MB\" or \"2GB\""
    }
    guard bytes >= 1_048_576 else {
      return "maxTotalSize must be at least 1MB"
    }
    return nil
  }

  private static func validateNetworking(
    _ networking: NetworkingConfigUpdate?,
    currentConfig: NetworkingConfig?
  ) -> String? {
    guard let networking else { return nil }

    if let error = validatePortRange(
      start: networking.sshPortRangeStart,
      end: networking.sshPortRangeEnd,
      currentStart: currentConfig?.sshPortRangeStart,
      currentEnd: currentConfig?.sshPortRangeEnd,
      label: "SSH"
    ) {
      return error
    }
    return validatePortRange(
      start: networking.vncPortRangeStart,
      end: networking.vncPortRangeEnd,
      currentStart: currentConfig?.vncPortRangeStart,
      currentEnd: currentConfig?.vncPortRangeEnd,
      label: "VNC"
    )
  }

  private static func validatePortRange(
    start: Int?,
    end: Int?,
    currentStart: Int?,
    currentEnd: Int?,
    label: String
  ) -> String? {
    if let start, start < 1024 || start > 65535 {
      return "\(label) port range start must be 1024-65535"
    }
    if let end, end < 1024 || end > 65535 {
      return "\(label) port range end must be 1024-65535"
    }

    let effectiveStart = start ?? currentStart
    let effectiveEnd = end ?? currentEnd
    if let effectiveStart, let effectiveEnd, effectiveStart > effectiveEnd {
      return "\(label) port range start must not exceed end"
    }
    return nil
  }

  private static func validateImages(_ images: ImageConfigUpdate?) -> String? {
    guard let images else { return nil }

    let parallelismFields = [
      (
        "maxParallelImageBlobTransfers",
        images.maxParallelImageBlobTransfers,
        ImageConfig.maximumParallelImageBlobTransfers
      ),
      (
        "maxParallelImageCompressions",
        images.maxParallelImageCompressions,
        ImageConfig.maximumParallelImageCompressions
      ),
      (
        "maxParallelImageDecompressions",
        images.maxParallelImageDecompressions,
        ImageConfig.maximumParallelImageDecompressions
      ),
      ("maxParallelImageDiskWrites", images.maxParallelImageDiskWrites, ImageConfig.maximumParallelImageDiskWrites),
    ]
    for (field, value, maximum) in parallelismFields {
      if let value, value < 1 || value > maximum {
        return "\(field) must be between 1 and \(maximum)"
      }
    }
    return nil
  }
}

struct LoggingConfigUpdate: Codable {
  let level: String?
  let retentionDays: Int?
  let maxTotalSize: String?
  let timezone: String??

  init(level: String?, retentionDays: Int?, maxTotalSize: String?, timezone: String??) {
    self.level = level
    self.retentionDays = retentionDays
    self.maxTotalSize = maxTotalSize
    self.timezone = timezone
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    level = try container.decodeIfPresent(String.self, forKey: .level)
    retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays)
    maxTotalSize = try container.decodeIfPresent(String.self, forKey: .maxTotalSize)
    timezone = try container.contains(.timezone)
      ? .some(container.decodeIfPresent(String.self, forKey: .timezone))
      : nil
  }
}

struct NetworkingConfigUpdate: Codable {
  let sshPortRangeStart: Int?
  let sshPortRangeEnd: Int?
  let autoEnableSSHForwarding: Bool?
  let vncPortRangeStart: Int?
  let vncPortRangeEnd: Int?
}

struct ImageConfigUpdate: Codable {
  let defaultRegistry: String??
  let insecureRegistries: [String]?
  let maxParallelImageBlobTransfers: Int?
  let maxParallelImageCompressions: Int?
  let maxParallelImageDecompressions: Int?
  let maxParallelImageDiskWrites: Int?

  init(
    defaultRegistry: String??,
    insecureRegistries: [String]?,
    maxParallelImageBlobTransfers: Int?,
    maxParallelImageCompressions: Int?,
    maxParallelImageDecompressions: Int?,
    maxParallelImageDiskWrites: Int?
  ) {
    self.defaultRegistry = defaultRegistry
    self.insecureRegistries = insecureRegistries
    self.maxParallelImageBlobTransfers = maxParallelImageBlobTransfers
    self.maxParallelImageCompressions = maxParallelImageCompressions
    self.maxParallelImageDecompressions = maxParallelImageDecompressions
    self.maxParallelImageDiskWrites = maxParallelImageDiskWrites
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    defaultRegistry = try container.contains(.defaultRegistry)
      ? .some(container.decodeIfPresent(String.self, forKey: .defaultRegistry))
      : nil
    insecureRegistries = try container.decodeIfPresent([String].self, forKey: .insecureRegistries)
    maxParallelImageBlobTransfers = try container.decodeIfPresent(Int.self, forKey: .maxParallelImageBlobTransfers)
    maxParallelImageCompressions = try container.decodeIfPresent(Int.self, forKey: .maxParallelImageCompressions)
    maxParallelImageDecompressions = try container.decodeIfPresent(Int.self, forKey: .maxParallelImageDecompressions)
    maxParallelImageDiskWrites = try container.decodeIfPresent(Int.self, forKey: .maxParallelImageDiskWrites)
  }
}
