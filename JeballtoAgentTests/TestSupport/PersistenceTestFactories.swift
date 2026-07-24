import Foundation
@testable import JeballtoAgent

/// Shared record factories for the persistence suites. Kept at file scope so the store suites and
/// their versioning counterparts build identical fixtures without duplicating them.
func makeDefinition(
  id: UUID = UUID(),
  name: String,
  basePath: String,
  createdAt: Date
) -> VMDefinition {
  VMDefinition(
    id: id,
    name: name,
    state: .created,
    resources: .default,
    network: VMNetwork(),
    paths: VMPaths.forVM(id: id, baseDir: basePath),
    createdAt: createdAt,
    updatedAt: createdAt
  )
}

func makeRecord(
  id: UUID = UUID(),
  reference: String,
  localPath: String,
  pulledAt: Date? = nil,
  formatVersion: Int = VMImagePackager.currentFormatVersion
) -> ImageRecord {
  ImageRecord(
    id: id,
    reference: reference,
    localPath: "\(localPath)/\(id.uuidString).bundle",
    pulledAt: pulledAt,
    formatVersion: formatVersion
  )
}
