import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct DiskImageInspectorTests {
  @Test
  func parsesDiskutilImageInfoPlist() throws {
    let data = try imageInfoPlist(format: "ASIF", capacity: NSNumber(value: UInt64(64 * 1024 * 1024 * 1024)))

    let details = try DiskImageInspector.parseImageInfo(data)

    #expect(details.format == "ASIF")
    #expect(details.capacity == 64 * 1024 * 1024 * 1024)
  }

  @Test
  func validatesFormatAndExactCapacity() throws {
    let expected = UInt64(20 * 1024 * 1024 * 1024)
    let valid = try imageInfoPlist(format: "ASIF", capacity: NSNumber(value: expected))
    let wrongFormat = try imageInfoPlist(format: "UDSP", capacity: NSNumber(value: expected))
    let wrongCapacity = try imageInfoPlist(format: "ASIF", capacity: NSNumber(value: expected + 1))

    try DiskImageInspector.validateImageInfo(valid, expectedCapacity: expected)
    #expect(throws: DiskImageInspectionError.self) {
      try DiskImageInspector.validateImageInfo(wrongFormat, expectedCapacity: expected)
    }
    #expect(throws: DiskImageInspectionError.self) {
      try DiskImageInspector.validateImageInfo(wrongCapacity, expectedCapacity: expected)
    }
  }

  @Test(arguments: [
    NSNumber(value: -1),
    NSNumber(value: 1.5),
    NSNumber(value: true),
  ])
  func rejectsInvalidCapacityValues(_ capacity: NSNumber) throws {
    let data = try imageInfoPlist(format: "ASIF", capacity: capacity)

    #expect(throws: DiskImageInspectionError.self) {
      _ = try DiskImageInspector.parseImageInfo(data)
    }
  }

  @Test
  func rejectsMalformedOrIncompletePlist() throws {
    let malformed = Data("not a plist".utf8)
    let incomplete = try PropertyListSerialization.data(
      fromPropertyList: ["Image Format": "ASIF"],
      format: .xml,
      options: 0
    )

    #expect(throws: DiskImageInspectionError.self) {
      _ = try DiskImageInspector.parseImageInfo(malformed)
    }
    #expect(throws: DiskImageInspectionError.self) {
      _ = try DiskImageInspector.parseImageInfo(incomplete)
    }
  }
}

private func imageInfoPlist(format: String, capacity: NSNumber) throws -> Data {
  try PropertyListSerialization.data(
    fromPropertyList: [
      "Image Format": format,
      "Size Info": ["Total Bytes": capacity],
    ],
    format: .xml,
    options: 0
  )
}
