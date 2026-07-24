import Foundation

enum DiskImageInspectionError: Error, LocalizedError {
  case inspectionFailed(String)
  case unsupportedFormat(String)
  case capacityMismatch(expected: UInt64, actual: UInt64)

  var errorDescription: String? {
    switch self {
    case .inspectionFailed(let message): "Disk image inspection failed: \(message)"
    case .unsupportedFormat(let format): "Disk image must use ASIF format, found \(format)"
    case .capacityMismatch(let expected, let actual):
      "Disk image capacity mismatch: metadata declares \(expected) bytes, ASIF contains \(actual) bytes"
    }
  }
}

typealias DiskImageCapacityValidator = @Sendable (_ path: String, _ expectedCapacity: UInt64) async throws -> Void

enum DiskImageInspector {
  static func validateASIFCapacity(atPath path: String, expectedCapacity: UInt64) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["image", "info", "--plist", path]
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: 30,
        timeoutDescription: "inspect disk image at \(path)",
        maxOutputSize: 1024 * 1024
      )
    )
    guard result.stdoutTruncated == false, result.stderrTruncated == false else {
      throw DiskImageInspectionError.inspectionFailed("diskutil output exceeded the 1MB limit")
    }
    guard result.exitCode == 0 else {
      let detail = String(decoding: result.stderr + result.stdout, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw DiskImageInspectionError.inspectionFailed(
        "diskutil exited with status \(result.exitCode): \(detail)"
      )
    }

    try validateImageInfo(result.stdout, expectedCapacity: expectedCapacity)
  }

  static func validateImageInfo(_ data: Data, expectedCapacity: UInt64) throws {
    let details = try parseImageInfo(data)
    guard details.format == "ASIF" else {
      throw DiskImageInspectionError.unsupportedFormat(details.format)
    }
    guard details.capacity == expectedCapacity else {
      throw DiskImageInspectionError.capacityMismatch(expected: expectedCapacity, actual: details.capacity)
    }
  }

  static func parseImageInfo(_ data: Data) throws -> (format: String, capacity: UInt64) {
    let object: Any
    do {
      object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
      throw DiskImageInspectionError.inspectionFailed("invalid diskutil plist: \(error.localizedDescription)")
    }
    guard let dictionary = object as? [String: Any],
          let format = dictionary["Image Format"] as? String,
          let sizeInfo = dictionary["Size Info"] as? [String: Any],
          let capacityNumber = sizeInfo["Total Bytes"] as? NSNumber else
    {
      throw DiskImageInspectionError.inspectionFailed("diskutil plist is missing image format or total capacity")
    }
    guard CFGetTypeID(capacityNumber) != CFBooleanGetTypeID(),
          let capacity = UInt64(capacityNumber.stringValue) else
    {
      throw DiskImageInspectionError.inspectionFailed("diskutil plist contains an invalid total capacity")
    }
    return (format, capacity)
  }
}
