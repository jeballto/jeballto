import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiModels))
struct ByteSizeAndFlexibleByteSizeTests {
  private struct SizeWrapper: Codable {
    let size: FlexibleByteSize
  }

  @Test(arguments: [
    ("1MB", UInt64(1_048_576)),
    ("2GB", UInt64(2_147_483_648)),
    ("1TB", UInt64(1_099_511_627_776)),
    ("1.5GB", UInt64(1_610_612_736)),
    (" 512mb ", UInt64(536_870_912)),
  ])
  func byteSizeParserAcceptsValidValues(_ input: (value: String, expected: UInt64)) throws {
    let parsed = try ByteSize.parse(input.value)
    #expect(parsed == input.expected)
  }

  @Test(arguments: [
    "", "500", "5PB", "GB", "-1GB", "0GB", "abcMB", "1e1GB", "+1GB", ".5GB", "1.GB",
    "0.0000001MB",
  ])
  func byteSizeParserRejectsInvalidValues(_ value: String) {
    #expect(throws: ByteSizeParseError.self) {
      _ = try ByteSize.parse(value)
    }
  }

  @Test
  func byteSizeParserDoesNotRoundFractionalBytes() throws {
    #expect(try ByteSize.parse("0.5MB") == 524_288)
    #expect(throws: ByteSizeParseError.self) {
      _ = try ByteSize.parse("0.1MB")
    }
  }

  @Test
  func flexibleByteSizeDecodesFromInteger() throws {
    let json = "{\"size\": 4096}".data(using: .utf8)
    let wrapper = try JSONDecoder().decode(SizeWrapper.self, from: #require(json))
    #expect(wrapper.size.bytes == 4096)
  }

  @Test
  func flexibleByteSizeDecodesFromString() throws {
    let json = "{\"size\": \"4GB\"}".data(using: .utf8)
    let wrapper = try JSONDecoder().decode(SizeWrapper.self, from: #require(json))
    #expect(wrapper.size.bytes == 4 * 1024 * 1024 * 1024)
  }

  @Test
  func flexibleByteSizeRejectsWrongType() {
    let json = "{\"size\": true}".data(using: .utf8)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(SizeWrapper.self, from: #require(json))
    }
  }

  @Test
  func byteSizeParserRejectsOverflowValues() {
    for value in ["16777216TB", "1e308TB", "1e309TB", "18446744073709551616TB"] {
      #expect(throws: ByteSizeParseError.self) {
        _ = try ByteSize.parse(value)
      }
    }
  }

  @Test
  func flexibleByteSizeEncodesAsRawBytes() throws {
    let json = "{\"size\": \"2GB\"}".data(using: .utf8)
    let wrapper = try JSONDecoder().decode(SizeWrapper.self, from: #require(json))

    let encoded = try JSONEncoder().encode(wrapper)
    let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

    #expect((decoded?["size"] as? UInt64) == 2 * 1024 * 1024 * 1024)
  }
}
