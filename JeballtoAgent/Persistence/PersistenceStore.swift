import Darwin
import Foundation

/// Errors that can occur during persistence operations
enum PersistenceError: Error, LocalizedError {
  case fileNotFound(String)
  case invalidData(String)
  case unsupportedDatabaseVersion(found: Int, expected: Int)
  case encodingFailed(Error)
  case writeFailed(path: String, error: Error)
  case decodingFailed(Error)
  case vmNotFound(UUID)
  case vmAlreadyExists(UUID)
  case directoryCreationFailed(String)

  var errorDescription: String? {
    switch self {
    case .fileNotFound(let path): "File not found at path: \(path)"
    case .invalidData(let reason): "Invalid data: \(reason)"
    case .unsupportedDatabaseVersion(let found, let expected):
      "Unsupported VM database version \(found), expected \(expected)"
    case .encodingFailed(let error): "Failed to encode data: \(error.localizedDescription)"
    case .writeFailed(let path, let error): "Failed to write data at \(path): \(error.localizedDescription)"
    case .decodingFailed(let error): "Failed to decode data: \(error.localizedDescription)"
    case .vmNotFound(let id): "VM not found with ID: \(id.uuidString)"
    case .vmAlreadyExists(let id): "VM already exists with ID: \(id.uuidString)"
    case .directoryCreationFailed(let path): "Failed to create directory: \(path)"
    }
  }
}

enum VMNetworkFieldUpdate: Sendable {
  case sshPort(Int?)
  case vncPort(Int?)
  case natIP(String?)
}

/// Manages persistence of VM definitions to disk using JSON format
actor PersistenceStore {
  private static let currentDatabaseVersion = 1
  static let maxDatabaseSize = 16 * 1024 * 1024

  private let databasePath: String
  private let fileManager = FileManager.default
  private var database: VMDatabase
  private var isLoaded = false
  private var loadFailure: Error?
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let postPublishSync: DurableMarkerStore.PostPublishSync?

  init(
    databasePath: String? = nil,
    postPublishSync: DurableMarkerStore.PostPublishSync? = nil
  ) {
    // Default to ~/Library/Application Support/Jeballto/vms.json
    if let customPath = databasePath {
      self.databasePath = customPath
    } else {
      let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Jeballto")
      self.databasePath = appSupportURL.appendingPathComponent("vms.json").path
    }

    // Configure encoder/decoder for pretty printing and ISO dates
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.postPublishSync = postPublishSync

    // Initialize database as empty first
    database = .empty

    // Note: Cannot call async methods in init, so we load lazily on first access
  }

  // MARK: - Initialization Helper

  /// Ensures database is loaded (called automatically on first access)
  private func ensureLoaded() {
    guard !isLoaded else { return }
    isLoaded = true

    do {
      try createStorageDirectoryIfNeeded()
      database = try loadFromDisk()
    } catch {
      loadFailure = error
      logWarning(
        "Failed to initialize database at \(databasePath): \(error). Refusing access until the issue is repaired.",
        category: "PersistenceStore"
      )
    }
  }

  // MARK: - Public API

  /// Saves the current database to disk
  func save() throws {
    try ensureLoadedForMutation()
    try writeToDisk(database)
  }

  /// Verifies that the on-disk database was loaded successfully.
  /// Startup calls this before exposing any read APIs so corruption cannot look like an empty database.
  func validateLoaded() throws {
    ensureLoaded()
    if let loadFailure {
      throw PersistenceError.invalidData(
        "Failed to load database at \(databasePath): \(loadFailure.localizedDescription)"
      )
    }
  }

  /// Creates a new VM definition
  func createVM(_ definition: VMDefinition) throws {
    try ensureLoadedForMutation()
    guard database.vms[definition.id] == nil else { throw PersistenceError.vmAlreadyExists(definition.id) }
    var candidate = database
    candidate.vms[definition.id] = definition
    try commit(candidate)
  }

  /// Updates an existing VM definition
  func updateVM(_ id: UUID, _ definition: VMDefinition) throws {
    try ensureLoadedForMutation()
    guard definition.id == id else {
      throw PersistenceError.invalidData("Definition ID \(definition.id) does not match key \(id)")
    }
    guard database.vms[id] != nil else { throw PersistenceError.vmNotFound(id) }
    var candidate = database
    candidate.vms[id] = definition
    try commit(candidate)
  }

  /// Atomically updates one network field without replacing unrelated VM state.
  @discardableResult
  func updateVMNetworkField(_ id: UUID, update: VMNetworkFieldUpdate) throws -> VMDefinition {
    try ensureLoadedForMutation()
    guard var definition = database.vms[id] else { throw PersistenceError.vmNotFound(id) }

    switch update {
    case .sshPort(let port):
      if let port {
        definition.updateSSHPort(port)
      } else {
        definition.clearSSHPort()
      }
    case .vncPort(let port):
      if let port {
        definition.updateVNCPort(port)
      } else {
        definition.clearVNCPort()
      }
    case .natIP(let ip):
      if let ip {
        definition.updateNATIP(ip)
      } else {
        definition.clearNATIP()
      }
    }

    var candidate = database
    candidate.vms[id] = definition
    try commit(candidate)
    return definition
  }

  /// Atomically merges user-editable configuration and operation metadata without replacing network or lifecycle data.
  @discardableResult
  func updateVMConfiguration(
    _ id: UUID,
    name: String? = nil,
    resources: VMResources? = nil,
    metadataUpdates: [String: String?] = [:]
  ) throws -> VMDefinition {
    try ensureLoadedForMutation()
    guard var definition = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    if let name { definition.name = name }
    if let resources { definition.resources = resources }
    for (key, value) in metadataUpdates {
      if let value {
        definition.metadata[key] = value
      } else {
        definition.metadata.removeValue(forKey: key)
      }
    }
    definition.updatedAt = Date()
    var candidate = database
    candidate.vms[id] = definition
    try commit(candidate)
    return definition
  }

  /// Atomically merges runtime lifecycle fields without replacing resources, network, or operation metadata.
  @discardableResult
  func updateVMLifecycle(_ id: UUID, state: VMState, markBooted: Bool) throws -> VMDefinition {
    try ensureLoadedForMutation()
    guard var definition = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    guard state != .running else {
      throw PersistenceError.invalidData(
        "Running state must be recorded with updateVMRunning so first-boot fields remain atomic"
      )
    }
    definition.updateState(state)
    if markBooted {
      definition.markBooted()
    }
    var candidate = database
    candidate.vms[id] = definition
    try commit(candidate)
    return definition
  }

  /// Atomically records the running state, first-boot marker, and lifetime deadline.
  @discardableResult
  func updateVMRunning(_ id: UUID, runningAt: Date) throws -> VMDefinition {
    try ensureLoadedForMutation()
    guard var definition = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    definition.updateState(.running)
    definition.markBooted()
    if definition.expiresAt == nil, let lifetime = definition.lifetimeSeconds {
      definition.setExpiry(runningAt.addingTimeInterval(TimeInterval(lifetime)))
    }
    var candidate = database
    candidate.vms[id] = definition
    try commit(candidate)
    return definition
  }

  /// Atomically merges installation and logical state while preserving unrelated fields.
  @discardableResult
  func updateVMInstallation(
    _ id: UUID,
    state: VMState,
    installation: VMInstallation
  ) throws -> VMDefinition {
    try ensureLoadedForMutation()
    guard var definition = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    definition.updateInstallation(installation)
    definition.updateState(state)
    var candidate = database
    candidate.vms[id] = definition
    try commit(candidate)
    return definition
  }

  /// Deletes a VM definition
  func deleteVM(_ id: UUID) throws {
    try ensureLoadedForMutation()
    guard database.vms[id] != nil else { throw PersistenceError.vmNotFound(id) }
    var candidate = database
    candidate.vms.removeValue(forKey: id)
    try commit(candidate)
  }

  /// Retrieves a specific VM definition
  func getVM(_ id: UUID) throws -> VMDefinition {
    ensureLoaded()
    if let loadFailure {
      throw PersistenceError.invalidData(
        "Failed to load database at \(databasePath): \(loadFailure.localizedDescription)"
      )
    }
    guard let vm = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    return vm
  }

  /// Lists all VM definitions
  func listVMs() throws -> [VMDefinition] {
    try ensureLoadedForRead()
    return Array(database.vms.values).sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// Checks if a VM exists
  func vmExists(_ id: UUID) throws -> Bool {
    try ensureLoadedForRead()
    return database.vms[id] != nil
  }

  /// Returns the total number of VMs
  func count() throws -> Int {
    try ensureLoadedForRead()
    return database.vms.count
  }

  /// Deletes all VM definitions from the database
  func deleteAllVMs() throws {
    try ensureLoadedForMutation()
    let count = database.vms.count
    var candidate = database
    candidate.vms.removeAll()
    try commit(candidate)
    logInfo("Cleared all \(count) VMs from persistent store", category: "PersistenceStore")
  }

  /// Updates just the state of a VM (convenience method)
  func updateVMState(_ id: UUID, state: VMState) throws {
    if state == .running {
      _ = try updateVMRunning(id, runningAt: Date())
      return
    }
    try ensureLoadedForMutation()
    guard var vm = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    vm.updateState(state)
    var candidate = database
    candidate.vms[id] = vm
    try commit(candidate)
  }

  // MARK: - Private Methods

  private func loadFromDisk() throws -> VMDatabase {
    let backupPath = databasePath + ".bak"
    guard Self.filesystemEntryExists(at: databasePath) else {
      if Self.filesystemEntryExists(at: backupPath) {
        let recovered = try decodeDatabase(at: backupPath)
        try restorePrimaryDatabase(from: backupPath)
        logWarning("Recovered missing VM database from backup at \(backupPath)", category: "PersistenceStore")
        return recovered
      }
      return .empty
    }

    do {
      return try decodeDatabase(at: databasePath)
    } catch {
      let primaryError = error
      if let persistenceError = error as? PersistenceError,
         case .unsupportedDatabaseVersion = persistenceError
      {
        throw persistenceError
      }
      guard Self.filesystemEntryExists(at: backupPath) else { throw primaryError }

      do {
        let recovered = try decodeDatabase(at: backupPath)
        try restorePrimaryDatabase(from: backupPath)
        logWarning("Recovered VM database from backup at \(backupPath)", category: "PersistenceStore")
        return recovered
      } catch {
        throw PersistenceError.invalidData(
          "Failed to load VM database and backup. Primary: \(primaryError.localizedDescription). "
            + "Backup: \(error.localizedDescription)"
        )
      }
    }
  }

  private func ensureLoadedForMutation() throws {
    ensureLoaded()
    if let loadFailure {
      throw PersistenceError.invalidData(
        "Failed to load existing database at \(databasePath): \(loadFailure.localizedDescription). "
          + "Refusing to overwrite it"
      )
    }
  }

  private func ensureLoadedForRead() throws {
    ensureLoaded()
    if let loadFailure {
      throw PersistenceError.invalidData(
        "Failed to load database at \(databasePath): \(loadFailure.localizedDescription)"
      )
    }
  }

  private func decodeDatabase(at path: String) throws -> VMDatabase {
    do {
      let data = try readBoundedData(at: path)
      let decoded = try decoder.decode(VMDatabase.self, from: data)
      guard decoded.version == Self.currentDatabaseVersion else {
        throw PersistenceError.unsupportedDatabaseVersion(
          found: decoded.version,
          expected: Self.currentDatabaseVersion
        )
      }
      try validateDatabase(decoded)
      return decoded
    } catch let error as PersistenceError {
      throw error
    } catch let error as DecodingError {
      throw PersistenceError.decodingFailed(error)
    } catch {
      throw PersistenceError.invalidData("Failed to read database at \(path): \(error.localizedDescription)")
    }
  }

  private func commit(_ candidate: VMDatabase) throws {
    try validateDatabase(candidate)
    try writeToDisk(candidate)
    database = candidate
  }

  private func validateDatabase(_ candidate: VMDatabase) throws {
    guard candidate.version == Self.currentDatabaseVersion else {
      throw PersistenceError.unsupportedDatabaseVersion(
        found: candidate.version,
        expected: Self.currentDatabaseVersion
      )
    }
    var macAddressOwners: [String: UUID] = [:]
    var forwardingPortOwners: [Int: UUID] = [:]
    for (key, definition) in candidate.vms {
      guard key == definition.id else {
        throw PersistenceError.invalidData(
          "VM database key \(key) does not match definition ID \(definition.id)"
        )
      }
      try validateDefinition(definition)

      let normalizedMAC = definition.network.macAddress.lowercased()
      if let owner = macAddressOwners[normalizedMAC] {
        throw PersistenceError.invalidData(
          "VMs \(owner) and \(definition.id) use the same MAC address \(definition.network.macAddress)"
        )
      }
      macAddressOwners[normalizedMAC] = definition.id

      for port in [definition.network.sshPort, definition.network.vncPort].compactMap({ $0 }) {
        if let owner = forwardingPortOwners[port] {
          throw PersistenceError.invalidData(
            "VMs \(owner) and \(definition.id) use the same forwarding port \(port)"
          )
        }
        forwardingPortOwners[port] = definition.id
      }
    }
  }

  private func validateDefinition(_ definition: VMDefinition) throws {
    guard VMNameValidator.validate(definition.name) else {
      throw PersistenceError.invalidData("VM \(definition.id) has an invalid name")
    }
    guard definition.resources.validate() else {
      throw PersistenceError.invalidData("VM \(definition.id) has invalid resource limits")
    }
    guard definition.network.isValidMACAddress else {
      throw PersistenceError.invalidData("VM \(definition.id) has an invalid MAC address")
    }
    guard definition.network.isValidNATIPAddress else {
      throw PersistenceError.invalidData("VM \(definition.id) has an invalid NAT IPv4 address")
    }

    for (label, port) in [
      ("SSH", definition.network.sshPort),
      ("VNC", definition.network.vncPort),
    ] {
      if let port, !(1 ... 65535).contains(port) {
        throw PersistenceError.invalidData("VM \(definition.id) has invalid \(label) port \(port)")
      }
    }
    if let sshPort = definition.network.sshPort,
       let vncPort = definition.network.vncPort,
       sshPort == vncPort
    {
      throw PersistenceError.invalidData("VM \(definition.id) reuses port \(sshPort) for SSH and VNC")
    }

    if let lifetime = definition.lifetimeSeconds {
      guard (1 ... 604_800).contains(lifetime) else {
        throw PersistenceError.invalidData("VM \(definition.id) has invalid lifetimeSeconds \(lifetime)")
      }
      if definition.hasBooted, definition.expiresAt == nil {
        throw PersistenceError.invalidData(
          "VM \(definition.id) has booted with lifetimeSeconds but no durable expiresAt"
        )
      }
    } else if definition.expiresAt != nil {
      throw PersistenceError.invalidData("VM \(definition.id) has expiresAt without lifetimeSeconds")
    }
    if definition.expiresAt != nil, definition.hasBooted == false {
      throw PersistenceError.invalidData("VM \(definition.id) has expiresAt before its first boot")
    }
  }

  private func writeToDisk(_ candidate: VMDatabase) throws {
    let candidateData = try encodedDatabaseData(candidate)
    do {
      let backupPath = databasePath + ".bak"
      // Create a backup of the existing database before overwriting
      if Self.filesystemEntryExists(at: databasePath) {
        let currentData = try encodedDatabaseData(database)
        try DurableMarkerStore.writeDataAtomically(
          currentData,
          to: backupPath,
          maximumSize: Self.maxDatabaseSize,
          postPublishSync: postPublishSync
        )
      }

      try DurableMarkerStore.writeDataAtomically(
        candidateData,
        to: databasePath,
        maximumSize: Self.maxDatabaseSize,
        postPublishSync: postPublishSync
      )
    } catch let error as PersistenceError {
      throw error
    } catch {
      throw PersistenceError.writeFailed(path: databasePath, error: error)
    }
  }

  private func encodedDatabaseData(_ value: VMDatabase) throws -> Data {
    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw PersistenceError.encodingFailed(error)
    }
    guard data.count <= Self.maxDatabaseSize else {
      throw PersistenceError.invalidData(
        "Encoded VM database exceeds the \(Self.maxDatabaseSize)-byte limit"
      )
    }
    return data
  }

  private func restorePrimaryDatabase(from backupPath: String) throws {
    let data = try readBoundedData(at: backupPath)
    try DurableMarkerStore.writeDataAtomically(
      data,
      to: databasePath,
      maximumSize: Self.maxDatabaseSize,
      postPublishSync: postPublishSync
    )
  }

  private func readBoundedData(at path: String) throws -> Data {
    guard let data = try DurableMarkerStore.readDataIfPresent(from: path, maximumSize: Self.maxDatabaseSize) else {
      throw PersistenceError.fileNotFound(path)
    }
    return data
  }

  private static func filesystemEntryExists(at path: String) -> Bool {
    var status = stat()
    return path.withCString { Darwin.lstat($0, &status) } == 0
  }

  private func createStorageDirectoryIfNeeded() throws {
    let directory = (databasePath as NSString).deletingLastPathComponent
    var isDirectory: ObjCBool = false

    if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw PersistenceError.directoryCreationFailed(directory) }
    } else {
      do { try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true) } catch {
        throw PersistenceError.directoryCreationFailed(directory)
      }
    }
  }
}
