import Foundation

struct VMInstallationSuccessMarker: Codable, Equatable, Sendable {
  let formatVersion: Int
  let vmId: UUID
  let completedAt: Date
}

enum VMInstallationSuccessMarkerError: Error, LocalizedError {
  case unsupportedVersion(found: Int, expected: Int)
  case mismatchedVM(found: UUID, expected: UUID)

  var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let found, let expected):
      "Unsupported installation success marker version \(found), expected \(expected)"
    case .mismatchedVM(let found, let expected):
      "Installation success marker belongs to VM \(found), expected \(expected)"
    }
  }
}

enum VMInstallationSuccessMarkerStore {
  static let currentFormatVersion = 1
  static let maximumSize = 4 * 1024
  private static let suffix = ".installation-succeeded"

  static func markerPath(for definition: VMDefinition) -> String {
    let storagePath = URL(fileURLWithPath: definition.paths.bundlePath).deletingLastPathComponent().path
    return (storagePath as NSString).appendingPathComponent(
      ".\(definition.id.uuidString)\(suffix)"
    )
  }

  static func recordSuccess(for definition: VMDefinition, at completedAt: Date = Date()) throws {
    let marker = VMInstallationSuccessMarker(
      formatVersion: currentFormatVersion,
      vmId: definition.id,
      completedAt: completedAt
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(marker)
    try DurableMarkerStore.writeDataAtomically(
      data,
      to: markerPath(for: definition),
      maximumSize: maximumSize
    )
  }

  static func readIfPresent(for definition: VMDefinition) throws -> VMInstallationSuccessMarker? {
    guard let data = try DurableMarkerStore.readDataIfPresent(
      from: markerPath(for: definition),
      maximumSize: maximumSize
    ) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let marker = try decoder.decode(VMInstallationSuccessMarker.self, from: data)
    guard marker.formatVersion == currentFormatVersion else {
      throw VMInstallationSuccessMarkerError.unsupportedVersion(
        found: marker.formatVersion,
        expected: currentFormatVersion
      )
    }
    guard marker.vmId == definition.id else {
      throw VMInstallationSuccessMarkerError.mismatchedVM(found: marker.vmId, expected: definition.id)
    }
    return marker
  }

  static func removeIfPresent(for definition: VMDefinition) throws {
    try DurableMarkerStore.removeIfPresent(at: markerPath(for: definition))
  }
}
