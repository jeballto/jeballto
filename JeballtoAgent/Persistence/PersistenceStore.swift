import Foundation

/// Errors that can occur during persistence operations
enum PersistenceError: Error, LocalizedError {
  case fileNotFound(String)
  case invalidData(String)
  case encodingFailed(Error)
  case decodingFailed(Error)
  case vmNotFound(UUID)
  case vmAlreadyExists(UUID)
  case directoryCreationFailed(String)

  var errorDescription: String? {
    switch self {
    case .fileNotFound(let path): "File not found at path: \(path)"
    case .invalidData(let reason): "Invalid data: \(reason)"
    case .encodingFailed(let error): "Failed to encode data: \(error.localizedDescription)"
    case .decodingFailed(let error): "Failed to decode data: \(error.localizedDescription)"
    case .vmNotFound(let id): "VM not found with ID: \(id.uuidString)"
    case .vmAlreadyExists(let id): "VM already exists with ID: \(id.uuidString)"
    case .directoryCreationFailed(let path): "Failed to create directory: \(path)"
    }
  }
}

/// Manages persistence of VM definitions to disk using JSON format
actor PersistenceStore {
  private let databasePath: String
  private let fileManager = FileManager.default
  private var database: VMDatabase
  private var isLoaded = false
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(databasePath: String? = nil) {
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
      let loadedDB = try loadFromDisk()
      database = loadedDB
    } catch {
      logWarning(
        "Failed to load database from \(databasePath): \(error). Starting with empty database.",
        category: "PersistenceStore"
      )
    }

    // Ensure storage directory exists
    do {
      try createStorageDirectoryIfNeeded()
    } catch {
      logError("Failed to create storage directory: \(error)", category: "PersistenceStore")
    }
  }

  // MARK: - Public API

  /// Saves the current database to disk
  func save() throws {
    ensureLoaded()
    try saveToDisk()
  }

  /// Creates a new VM definition
  func createVM(_ definition: VMDefinition) throws {
    ensureLoaded()
    guard database.vms[definition.id] == nil else { throw PersistenceError.vmAlreadyExists(definition.id) }
    database.vms[definition.id] = definition
    try saveToDisk()
  }

  /// Updates an existing VM definition
  func updateVM(_ id: UUID, _ definition: VMDefinition) throws {
    ensureLoaded()
    guard definition.id == id else {
      throw PersistenceError.invalidData("Definition ID \(definition.id) does not match key \(id)")
    }
    guard database.vms[id] != nil else { throw PersistenceError.vmNotFound(id) }
    database.vms[id] = definition
    try saveToDisk()
  }

  /// Deletes a VM definition
  func deleteVM(_ id: UUID) throws {
    ensureLoaded()
    guard database.vms[id] != nil else { throw PersistenceError.vmNotFound(id) }
    database.vms.removeValue(forKey: id)
    try saveToDisk()
  }

  /// Retrieves a specific VM definition
  func getVM(_ id: UUID) throws -> VMDefinition {
    ensureLoaded()
    guard let vm = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    return vm
  }

  /// Lists all VM definitions
  func listVMs() -> [VMDefinition] {
    ensureLoaded()
    return Array(database.vms.values).sorted { $0.createdAt < $1.createdAt }
  }

  /// Checks if a VM exists
  func vmExists(_ id: UUID) -> Bool {
    ensureLoaded()
    return database.vms[id] != nil
  }

  /// Returns the total number of VMs
  func count() -> Int {
    ensureLoaded()
    return database.vms.count
  }

  /// Deletes all VM definitions from the database
  func deleteAllVMs() throws {
    ensureLoaded()
    let count = database.vms.count
    database.vms.removeAll()
    try saveToDisk()
    logInfo("Cleared all \(count) VMs from persistent store", category: "PersistenceStore")
  }

  /// Updates just the state of a VM (convenience method)
  func updateVMState(_ id: UUID, state: VMState) throws {
    ensureLoaded()
    guard var vm = database.vms[id] else { throw PersistenceError.vmNotFound(id) }
    vm.updateState(state)
    database.vms[id] = vm
    try saveToDisk()
  }

  // MARK: - Private Methods

  private func loadFromDisk() throws -> VMDatabase {
    guard fileManager.fileExists(atPath: databasePath) else {
      // Database doesn't exist yet, return empty
      return .empty
    }

    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: databasePath))
      let loadedDB = try decoder.decode(VMDatabase.self, from: data)
      return loadedDB
    } catch let error as DecodingError { throw PersistenceError.decodingFailed(error) } catch {
      throw PersistenceError.invalidData("Failed to read database at \(databasePath): \(error.localizedDescription)")
    }
  }

  private func saveToDisk() throws {
    do {
      // Create a backup of the existing database before overwriting
      if fileManager.fileExists(atPath: databasePath) {
        let backupPath = databasePath + ".bak"
        do {
          try? fileManager.removeItem(atPath: backupPath)
          try fileManager.copyItem(atPath: databasePath, toPath: backupPath)
        } catch {
          logWarning(
            "Failed to create backup at \(backupPath): \(error.localizedDescription)",
            category: "PersistenceStore"
          )
        }
      }

      let data = try encoder.encode(database)
      try data.write(to: URL(fileURLWithPath: databasePath), options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databasePath)
    } catch let error as EncodingError { throw PersistenceError.encodingFailed(error) } catch {
      throw PersistenceError.invalidData("Failed to write database to disk")
    }
  }

  private func createStorageDirectoryIfNeeded() throws {
    let directory = (databasePath as NSString).deletingLastPathComponent
    var isDirectory: ObjCBool = false

    if !fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) {
      do { try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true) } catch {
        throw PersistenceError.directoryCreationFailed(directory)
      }
    }
  }
}
