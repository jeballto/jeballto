import Foundation

// MARK: - Byte Size Parsing

enum ByteSizeParseError: Error, LocalizedError {
  case invalidFormat(String)

  var errorDescription: String? {
    switch self {
    case .invalidFormat(let value):
      "Invalid size format: '\(value)'. Use number with MB, GB, or TB suffix (e.g., '4GB', '512MB', '1TB')"
    }
  }
}

enum ByteSize {
  private static let suffixes: [(suffix: String, multiplier: Double)] = [
    ("TB", 1024 * 1024 * 1024 * 1024),
    ("GB", 1024 * 1024 * 1024),
    ("MB", 1024 * 1024),
  ]

  static func parse(_ value: String) throws -> UInt64 {
    let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()

    for (suffix, multiplier) in suffixes {
      guard trimmed.hasSuffix(suffix) else { continue }
      let numberPart = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
      guard let number = Double(numberPart), number > 0 else {
        throw ByteSizeParseError.invalidFormat(value)
      }
      let bytes = number * multiplier
      guard bytes <= Double(UInt64.max) else {
        throw ByteSizeParseError.invalidFormat(value)
      }
      return UInt64(bytes)
    }

    throw ByteSizeParseError.invalidFormat(value)
  }
}

/// Accepts either a UInt64 (bytes) or a human-readable string ("4GB", "512MB")
struct FlexibleByteSize: Codable {
  let bytes: UInt64

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let intValue = try? container.decode(UInt64.self) {
      bytes = intValue
    } else if let stringValue = try? container.decode(String.self) {
      bytes = try ByteSize.parse(stringValue)
    } else {
      throw DecodingError.typeMismatch(
        FlexibleByteSize.self,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Expected UInt64 or String (e.g., '4GB', '512MB')"
        )
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(bytes)
  }
}

// MARK: - Request Models

/// Request to create a new VM
struct CreateVMRequest: Codable {
  let name: String
  let resources: VMResourcesDTO?
  let image: String?
  var ephemeral: Bool? = nil
  /// Optional max lifetime in seconds; VM stops (and is deleted if ephemeral) after this elapses from first start.
  var lifetimeSeconds: Int? = nil

  func validate() -> (valid: Bool, error: String?) {
    guard VMNameValidator.validate(name) else {
      return (false, "Invalid VM name. Must be 1-100 characters, alphanumeric, hyphens, underscores, spaces, and dots")
    }

    if let image, !image.isEmpty {
      do {
        _ = try ImageReference.parse(image)
      } catch {
        return (false, "Invalid image reference: \(error.localizedDescription)")
      }
      if resources != nil {
        return (
          false,
          "resources cannot be set when creating from an image; use PATCH /v1/vms/{id} to change resources afterwards"
        )
      }
    }
    if let ttl = lifetimeSeconds, ttl < 1 || ttl > 604_800 {
      return (false, "lifetimeSeconds must be between 1 and 604800 (7 days)")
    }
    return (true, nil)
  }
}

/// VM resources specification (accepts bytes as UInt64 or human-readable strings like "4GB", "512MB")
struct VMResourcesDTO: Codable {
  let cpuCount: Int?
  let memorySize: FlexibleByteSize?
  let diskSize: FlexibleByteSize?

  func toVMResources() -> VMResources {
    VMResources(
      cpuCount: cpuCount ?? 4,
      memorySize: memorySize?.bytes ?? (4 * 1024 * 1024 * 1024),
      diskSize: diskSize?.bytes ?? (64 * 1024 * 1024 * 1024)
    )
  }
}

/// Request to update a VM (name and/or resources, all fields optional, at least one required)
struct UpdateVMRequest: Codable {
  let name: String?
  let resources: UpdateVMResourcesDTO?

  func validate() -> (valid: Bool, error: String?) {
    let hasResources = resources?.cpuCount != nil || resources?.memorySize != nil || resources?.diskSize != nil
    if name == nil, !hasResources {
      return (
        false,
        "At least one field (name, resources.cpuCount, resources.memorySize, resources.diskSize) must be provided"
      )
    }
    if let name, !VMNameValidator.validate(name) {
      return (false, "Invalid VM name. Must be 1-100 characters, alphanumeric, hyphens, underscores, spaces, and dots")
    }
    if let resources {
      let resourceValidation = resources.validate()
      if !resourceValidation.valid { return resourceValidation }
    }
    return (true, nil)
  }
}

/// Resource fields for update (all optional)
struct UpdateVMResourcesDTO: Codable {
  let cpuCount: Int?
  let memorySize: FlexibleByteSize?
  let diskSize: FlexibleByteSize?

  func validate() -> (valid: Bool, error: String?) {
    if let cpu = cpuCount, cpu < 1 || cpu > 32 {
      return (false, "CPU count must be 1-32")
    }
    if let mem = memorySize {
      if mem.bytes < 2 * 1024 * 1024 * 1024 {
        return (false, "Memory must be at least 2GB")
      }
      if mem.bytes > 128 * 1024 * 1024 * 1024 {
        return (false, "Memory must not exceed 128GB")
      }
    }
    if let disk = diskSize {
      if disk.bytes < 20 * 1024 * 1024 * 1024 {
        return (false, "Disk must be at least 20GB")
      }
      if disk.bytes > 8 * 1024 * 1024 * 1024 * 1024 {
        return (false, "Disk must not exceed 8TB")
      }
    }
    return (true, nil)
  }
}

/// Request to clone a VM
struct CloneVMRequest: Codable {
  let name: String
  let resources: VMResourcesDTO?
  var ephemeral: Bool? = nil

  func validate() -> (valid: Bool, error: String?) {
    guard VMNameValidator.validate(name) else {
      return (false, "Invalid VM name. Must be 1-100 characters, alphanumeric, hyphens, underscores, spaces, and dots")
    }
    return (true, nil)
  }
}

struct InstallVMRequest: Codable {
  /// Unified source field: HTTPS URL, file:// URL, absolute path, or omit for latest macOS
  let source: String?

  func validate() -> (valid: Bool, error: String?) {
    guard let source, !source.isEmpty else {
      return (true, nil) // omitted = download latest macOS
    }

    let lowered = source.lowercased()

    if lowered.hasPrefix("https://") {
      guard URL(string: source) != nil else {
        return (false, "Invalid HTTPS URL format")
      }
      return (true, nil)
    }

    if lowered.hasPrefix("http://") {
      return (false, "HTTP is not supported for security reasons. Use HTTPS or a local file path")
    }

    if lowered.hasPrefix("file://") {
      let path = String(source.dropFirst("file://".count))
      guard path.hasPrefix("/") else {
        return (false, "file:// URL must use an absolute path (e.g., file:///path/to/file.ipsw)")
      }
      return (true, nil)
    }

    if source.hasPrefix("/") {
      return (true, nil) // bare absolute path
    }

    return (false, "Invalid source format. Use an HTTPS URL, file:// URL, or absolute path (e.g., /path/to/file.ipsw)")
  }

  /// Resolved source for downstream consumption (strips file:// scheme)
  var effectiveIPSWSource: String? {
    guard let source, !source.isEmpty else { return nil }
    if source.lowercased().hasPrefix("file://") {
      return String(source.dropFirst("file://".count))
    }
    return source
  }
}

struct CommandExecuteRequest: Codable {
  let command: String
  let user: String?
  let password: String?
  let timeout: Int?

  private static let maxTimeoutSeconds = 600

  func validate() -> (valid: Bool, error: String?) {
    if command.isEmpty {
      return (false, "'command' must not be empty")
    }
    if command.count > CommandExecutor.maxCommandLength {
      return (false, "Command too long (max \(CommandExecutor.maxCommandLength) characters)")
    }
    if let t = timeout {
      if t <= 0 { return (false, "Timeout must be positive") }
      if t > Self.maxTimeoutSeconds { return (false, "Timeout must not exceed \(Self.maxTimeoutSeconds) seconds") }
    }
    return (true, nil)
  }

  var effectiveUser: String { user ?? "admin" }
  var effectivePassword: String? { password ?? "admin" }
  var effectiveTimeout: TimeInterval { TimeInterval(timeout ?? 30) }
}

struct CommandExecuteResponse: Codable {
  let vmId: String
  let exitCode: Int
  let stdout: String
  let stderr: String
}

struct KeystrokesRequest: Codable {
  let keystrokes: [String]

  private static let maxKeystrokeSequences = 1000
  private static let maxKeystrokeSequenceLength = 10000

  func validate() -> (valid: Bool, error: String?) {
    if keystrokes.isEmpty {
      return (false, "'keystrokes' array must not be empty")
    }
    if keystrokes.count > Self.maxKeystrokeSequences {
      return (false, "Too many keystroke sequences (max \(Self.maxKeystrokeSequences))")
    }
    for seq in keystrokes where seq.count > Self.maxKeystrokeSequenceLength {
      return (false, "Keystroke sequence too long (max \(Self.maxKeystrokeSequenceLength) characters)")
    }
    return (true, nil)
  }
}

struct KeystrokesResponse: Codable {
  let vmId: String
  let keystrokesCount: Int
  let message: String
}

// MARK: - Response Models

/// Response for VM details
struct VMResponse: Codable {
  let id: String
  let name: String
  let state: String
  let ephemeral: Bool
  let resources: VMResourcesResponse
  let network: VMNetworkResponse?
  let guiOpen: Bool
  let uptime: Int? // seconds since VM started running, nil if not running
  let lifetimeSeconds: Int?
  let expiresAt: String?
  let createdAt: String
  let updatedAt: String

  /// Creates response from VMDefinition
  init(from definition: VMDefinition, guiOpen: Bool = false, uptime: Int? = nil) {
    id = definition.id.uuidString
    name = definition.name
    state = definition.state.rawValue
    ephemeral = definition.ephemeral
    resources = VMResourcesResponse(from: definition.resources)
    network = VMNetworkResponse(from: definition.network)
    self.guiOpen = guiOpen
    self.uptime = uptime
    lifetimeSeconds = definition.lifetimeSeconds
    expiresAt = definition.expiresAt.map { iso8601Formatter.string(from: $0) }
    createdAt = iso8601Formatter.string(from: definition.createdAt)
    updatedAt = iso8601Formatter.string(from: definition.updatedAt)
  }
}

/// VM resources in response
struct VMResourcesResponse: Codable {
  let cpuCount: Int
  let memorySize: String
  let diskSize: String

  init(from resources: VMResources) {
    cpuCount = resources.cpuCount
    memorySize = Self.formatByteSize(resources.memorySize)
    diskSize = Self.formatByteSize(resources.diskSize)
  }

  /// Formats bytes as a human-readable string like "4GB" or "4.5GB"
  static func formatByteSize(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    if gb >= 1, gb == gb.rounded() {
      return "\(Int(gb))GB"
    } else if gb >= 1 {
      return String(format: "%.1fGB", gb)
    } else {
      let mb = Double(bytes) / (1024 * 1024)
      if mb == mb.rounded() {
        return "\(Int(mb))MB"
      }
      return String(format: "%.1fMB", mb)
    }
  }
}

/// VM network information in response
struct VMNetworkResponse: Codable {
  let macAddress: String
  let sshPort: Int?
  let vncPort: Int?
  let natIP: String?

  init(from network: VMNetwork) {
    macAddress = network.macAddress
    sshPort = network.sshPort
    vncPort = network.vncPort
    natIP = network.natIP
  }
}

/// Response for list of VMs
struct VMListResponse: Codable {
  let vms: [VMResponse]
  let total: Int
  let limit: Int?
  let offset: Int?

  init(vms: [VMResponse], total: Int? = nil, limit: Int? = nil, offset: Int? = nil) {
    self.vms = vms
    self.total = total ?? vms.count
    self.limit = limit
    self.offset = offset
  }
}

/// Response for SSH connection information
struct SSHInfoResponse: Codable {
  let host: String
  let port: Int?
  let status: String
  let user: String?

  init(host: String = "127.0.0.1", port: Int?, status: String = "ready", user: String? = nil) {
    self.host = host
    self.port = port
    self.status = status
    self.user = user
  }
}

/// Response for VNC connection information
struct VNCInfoResponse: Codable {
  let host: String
  let port: Int?
  let status: String

  init(host: String = "127.0.0.1", port: Int?, status: String = "ready") {
    self.host = host
    self.port = port
    self.status = status
  }
}

/// Response for VM state query
struct VMStateResponse: Codable {
  let state: String
  let uptime: Int? // seconds, if running

  init(state: VMState, uptime: Int? = nil) {
    self.state = state.rawValue
    self.uptime = uptime
  }
}

/// Response for health check
struct HealthResponse: Codable {
  let status: String
  let version: String
  let vmsTotal: Int
  let vmsRunning: Int
  let uptime: Int // seconds

  init(
    status: String = "healthy",
    version: String = AppVersion.marketing,
    vmsTotal: Int,
    vmsRunning: Int,
    uptime: Int
  ) {
    self.status = status
    self.version = version
    self.vmsTotal = vmsTotal
    self.vmsRunning = vmsRunning
    self.uptime = uptime
  }
}

/// Response for installation status
struct InstallStatusResponse: Codable {
  let vmId: String
  let status: String // "not_started", "installing", "completed", "failed"
  let progress: Double? // overall 0.0 to 1.0
  let phaseProgress: Double? // progress within current phase 0.0 to 1.0
  let message: String?
  let phase: String? // "setup", "downloading", "installing"
  let bytesDownloaded: UInt64? // bytes downloaded so far
  let bytesTotal: UInt64? // total bytes expected
  let downloadSpeed: UInt64? // bytes per second (instantaneous)

  init(
    vmId: UUID, status: String, progress: Double? = nil, phaseProgress: Double? = nil,
    message: String? = nil, phase: String? = nil, bytesDownloaded: UInt64? = nil,
    bytesTotal: UInt64? = nil, downloadSpeed: UInt64? = nil
  ) {
    self.vmId = vmId.uuidString
    self.status = status
    self.progress = progress
    self.phaseProgress = phaseProgress
    self.message = message
    self.phase = phase
    self.bytesDownloaded = bytesDownloaded
    self.bytesTotal = bytesTotal
    self.downloadSpeed = downloadSpeed
  }
}

/// Response for events
struct EventResponse: Codable {
  let timestamp: String
  let type: String
  let vmId: String?
  let data: [String: String]?

  init(from event: RecordedEvent) {
    timestamp = iso8601Formatter.string(from: event.timestamp)
    type = event.event.eventType
    vmId = event.event.vmId?.uuidString

    // Extract event-specific data
    switch event.event {
    case .stateChanged(_, let from, let to): data = ["from": from.rawValue, "to": to.rawValue]
    case .vmCreated(_, let name): data = ["name": name]
    case .vmDeleted(_, let name): data = ["name": name]
    case .errorOccurred(_, let error): data = ["error": error]
    case .sshPortAssigned(_, let port): data = ["port": String(port)]
    case .sshPortReleased: data = nil
    case .vncPortAssigned(_, let port): data = ["port": String(port)]
    case .vncPortReleased: data = nil
    case .imagePullStarted(let ref), .imagePulled(let ref), .imagePushStarted(let ref), .imagePushed(let ref),
         .imageDeleted(let ref):
      data = ["reference": ref]
    case .imagePullFailed(let ref, let error), .imagePushFailed(let ref, let error):
      data = ["reference": ref, "error": error]
    case .vmCloned(_, let sourceVmId, let name): data = ["sourceVmId": sourceVmId.uuidString, "name": name]
    case .guiOpened, .guiClosed: data = nil
    case .jeballtofileStarted(let execId, let vmId):
      data = ["executionId": execId.uuidString, "vmId": vmId.uuidString]
    case .jeballtofileStepStarted(let execId, let step, let stepType):
      data = ["executionId": execId.uuidString, "step": String(step), "stepType": stepType]
    case .jeballtofileStepCompleted(let execId, let step, let stepType):
      data = ["executionId": execId.uuidString, "step": String(step), "stepType": stepType]
    case .jeballtofileStepFailed(let execId, let step, let stepType, let error):
      data = ["executionId": execId.uuidString, "step": String(step), "stepType": stepType, "error": error]
    case .jeballtofileCompleted(let execId, let vmId):
      data = ["executionId": execId.uuidString, "vmId": vmId.uuidString]
    case .jeballtofileCancelled(let execId, let vmId, let step):
      data = ["executionId": execId.uuidString, "vmId": vmId.uuidString, "step": String(step)]
    case .jeballtofileFailed(let execId, let vmId, let step, let error):
      data = ["executionId": execId.uuidString, "vmId": vmId.uuidString, "step": String(step), "error": error]
    default: data = nil
    }
  }
}

/// Response for event list
struct EventListResponse: Codable {
  let events: [EventResponse]
  let total: Int

  init(events: [RecordedEvent]) {
    self.events = events.map { EventResponse(from: $0) }
    total = events.count
  }
}

struct GUIStatusResponse: Codable {
  let vmId: String
  let guiOpen: Bool

  init(vmId: UUID, guiOpen: Bool) {
    self.vmId = vmId.uuidString
    self.guiOpen = guiOpen
  }
}

// MARK: - Error Response

/// Standard error response
struct ErrorResponse: Codable {
  let error: ErrorDetail

  struct ErrorDetail: Codable {
    let code: String
    let message: String
    let details: [String: String]?

    init(code: String, message: String, details: [String: String]? = nil) {
      self.code = code
      self.message = message
      self.details = details
    }
  }

  init(code: String, message: String, details: [String: String]? = nil) {
    error = ErrorDetail(code: code, message: message, details: details)
  }
}

// MARK: - Success Response

/// Response for wipe all VMs operation
struct WipeAllResponse: Codable {
  let deleted: Int
  let failed: Int
  let errors: [String]?
}

/// Generic success response
struct SuccessResponse: Codable {
  let success: Bool
  let message: String?

  init(message: String? = nil) {
    success = true
    self.message = message
  }
}

// MARK: - Image Request Models

struct PullImageRequest: Codable {
  static let maxTimeoutSeconds = 604_800

  let reference: String
  let timeout: Int?
  var asyncRequested: Bool? = nil

  enum CodingKeys: String, CodingKey {
    case reference
    case timeout
    case asyncRequested = "async"
  }

  var shouldRunAsync: Bool {
    asyncRequested ?? false
  }

  func validate() -> (valid: Bool, error: String?) {
    guard !reference.isEmpty else {
      return (false, "Image reference is required")
    }
    if let t = timeout {
      if t <= 0 { return (false, "Timeout must be positive if specified") }
      if t > Self.maxTimeoutSeconds { return (false, "Timeout must not exceed \(Self.maxTimeoutSeconds) seconds") }
    }
    do {
      _ = try ImageReference.parse(reference)
      return (true, nil)
    } catch {
      return (false, "Invalid image reference: \(error.localizedDescription)")
    }
  }
}

struct PushImageRequest: Codable {
  static let maxTimeoutSeconds = 604_800

  let reference: String
  let source: String?
  let timeout: Int?
  var asyncRequested: Bool? = nil

  enum CodingKeys: String, CodingKey {
    case reference
    case source
    case timeout
    case asyncRequested = "async"
  }

  var shouldRunAsync: Bool {
    asyncRequested ?? false
  }

  func validate() -> (valid: Bool, error: String?) {
    guard !reference.isEmpty else {
      return (false, "Image reference is required")
    }
    if let t = timeout {
      if t <= 0 { return (false, "Timeout must be positive if specified") }
      if t > Self.maxTimeoutSeconds { return (false, "Timeout must not exceed \(Self.maxTimeoutSeconds) seconds") }
    }
    do {
      _ = try ImageReference.parse(reference)
    } catch {
      return (false, "Invalid image reference: \(error.localizedDescription)")
    }

    guard let source, !source.isEmpty else {
      return (false, "Source is required. Use 'vm:<uuid>' or 'image:<uuid>'")
    }

    let parsed = parseSource()
    guard let parsed else {
      return (false, "Invalid source format. Use 'vm:<uuid>' or 'image:<uuid>'")
    }

    guard UUID(uuidString: parsed.id) != nil else {
      return (false, "Invalid UUID in source: '\(parsed.id)'")
    }

    return (true, nil)
  }

  /// Parsed source type and UUID
  struct ParsedSource {
    enum SourceType: String { case vm, image }
    let type: SourceType
    let id: String
  }

  func parseSource() -> ParsedSource? {
    guard let source else { return nil }
    let parts = source.split(separator: ":", maxSplits: 1)
    guard parts.count == 2,
          let type = ParsedSource.SourceType(rawValue: String(parts[0])) else
    {
      return nil
    }
    return ParsedSource(type: type, id: String(parts[1]))
  }
}

struct RegistryLoginRequest: Codable {
  let registry: String
  let username: String
  let password: String

  private static let hostPattern = "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]{1,5})?$"

  func validate() -> (valid: Bool, error: String?) {
    guard !registry.isEmpty else { return (false, "Registry is required") }
    guard !username.isEmpty else { return (false, "Username is required") }
    guard !password.isEmpty else { return (false, "Password is required") }
    guard registry.range(of: Self.hostPattern, options: .regularExpression) != nil else {
      return (false, "Invalid registry hostname")
    }
    return (true, nil)
  }
}

struct RegistryLogoutRequest: Codable {
  let registry: String

  private static let hostPattern = "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]{1,5})?$"

  func validate() -> (valid: Bool, error: String?) {
    guard !registry.isEmpty else {
      return (false, "Registry is required")
    }
    guard registry.range(of: Self.hostPattern, options: .regularExpression) != nil else {
      return (false, "Invalid registry hostname")
    }
    return (true, nil)
  }
}

// MARK: - Image Response Models

struct ImageResponse: Codable {
  let id: String
  let reference: String
  let digest: String?
  let localPath: String
  let size: UInt64?
  let pulledAt: String?
  let pushedAt: String?
  let metadata: [String: String]?

  init(from record: ImageRecord) {
    id = record.id.uuidString
    reference = record.reference
    digest = record.digest
    localPath = record.localPath
    size = record.size
    pulledAt = record.pulledAt.map { iso8601Formatter.string(from: $0) }
    pushedAt = record.pushedAt.map { iso8601Formatter.string(from: $0) }
    metadata = record.metadata.isEmpty ? nil : record.metadata
  }
}

struct ImageListResponse: Codable {
  let images: [ImageResponse]
  let total: Int
  let limit: Int?
  let offset: Int?

  init(images: [ImageRecord], total: Int? = nil, limit: Int? = nil, offset: Int? = nil) {
    self.images = images.map { ImageResponse(from: $0) }
    self.total = total ?? images.count
    self.limit = limit
    self.offset = offset
  }
}

struct ImageOperationListResponse: Codable {
  let operations: [ImageOperationStatusResponse]
  let total: Int
  let activeOnly: Bool
  let type: String?

  init(operations: [ImageOperationStatus], activeOnly: Bool, type: ImageOperationKind?) {
    self.operations = operations.map { ImageOperationStatusResponse(from: $0) }
    total = operations.count
    self.activeOnly = activeOnly
    self.type = type?.rawValue
  }
}

struct ImageOperationCancelAllResponse: Codable {
  let cancelled: Int
  let tasksCancelled: Int
  let operations: [ImageOperationStatusResponse]

  init(cancelled: Int, tasksCancelled: Int, operations: [ImageOperationStatus]) {
    self.cancelled = cancelled
    self.tasksCancelled = tasksCancelled
    self.operations = operations.map { ImageOperationStatusResponse(from: $0) }
  }
}

struct ImageOperationStatusResponse: Codable {
  let operationId: String
  let statusUrl: String
  let type: String
  let reference: String
  let source: String?
  let status: String
  let stage: String?
  let progress: Double?
  let stageProgress: Double?
  let averageSpeedMBps: Double?
  let chunksCompleted: Int
  let chunksTotal: Int?
  let bytesCompleted: UInt64
  let bytesTotal: UInt64?
  let startedAt: String
  let updatedAt: String
  let completedAt: String?
  let digest: String?
  let image: ImageResponse?
  let error: String?

  init(from status: ImageOperationStatus) {
    operationId = status.id.uuidString
    statusUrl = "/v1/images/\(status.kind.rawValue)/operations/\(status.id.uuidString)"
    type = status.kind.rawValue
    reference = status.reference
    source = status.source
    self.status = status.state.rawValue
    stage = status.stage?.rawValue
    progress = status.progress.map(Self.roundTwoDecimals)
    stageProgress = status.stageProgress.map(Self.roundTwoDecimals)
    averageSpeedMBps = Self.averageSpeedMBps(for: status)
    chunksCompleted = status.chunksCompleted
    chunksTotal = status.chunksTotal
    bytesCompleted = status.bytesCompleted
    bytesTotal = status.bytesTotal
    startedAt = iso8601Formatter.string(from: status.startedAt)
    updatedAt = iso8601Formatter.string(from: status.updatedAt)
    completedAt = status.completedAt.map { iso8601Formatter.string(from: $0) }
    digest = status.digest
    image = status.image.map { ImageResponse(from: $0) }
    error = status.error
  }

  private static func averageSpeedMBps(for status: ImageOperationStatus) -> Double? {
    let endDate = status.completedAt ?? status.updatedAt
    let startedAt = status.stageStartedAt ?? status.startedAt
    let elapsed = endDate.timeIntervalSince(startedAt)
    guard elapsed > 0, status.bytesCompleted > 0 else { return nil }
    let speed = Double(status.bytesCompleted) / elapsed / 1_000_000.0
    return roundTwoDecimals(speed)
  }

  private static func roundTwoDecimals(_ value: Double) -> Double {
    (value * 100).rounded() / 100
  }
}

struct RegistryLoginResponse: Codable {
  let registry: String
  let status: String
  let message: String?
}

// MARK: - System Reset Models

struct SystemResetRequest: Codable {
  let mode: String

  private static let validModes = ["soft", "hard"]

  func validate() -> (valid: Bool, error: String?) {
    guard Self.validModes.contains(mode) else {
      return (false, "Invalid mode '\(mode)'. Must be one of: \(Self.validModes.joined(separator: ", "))")
    }
    return (true, nil)
  }
}

struct SystemResetResponse: Codable {
  let mode: String
  let vmsDeleted: Int
  let vmsFailed: Int
  let imagesDeleted: Int
  let imagesFailed: Int
  let ipswCacheCleared: Bool
  let configDeleted: Bool
  let logsDeleted: Bool
  let willTerminate: Bool
  let errors: [String]?
}
