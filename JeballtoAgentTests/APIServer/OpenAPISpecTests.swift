import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes))
struct OpenAPISpecTests {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var spec: String {
    get throws {
      try String(
        contentsOf: repositoryRoot.appendingPathComponent("openapi/jeballto-api.yaml"),
        encoding: .utf8
      )
    }
  }

  @Test
  func everyLocalComponentReferenceResolves() throws {
    let spec = try spec
    let componentNames = Self.componentNames(in: spec)

    let expression = try NSRegularExpression(
      pattern: #"#/components/([A-Za-z0-9_-]+)/([A-Za-z0-9_.-]+)"#
    )
    let range = NSRange(spec.startIndex ..< spec.endIndex, in: spec)
    var missing: [String] = []

    for match in expression.matches(in: spec, range: range) {
      guard let sectionRange = Range(match.range(at: 1), in: spec),
            let nameRange = Range(match.range(at: 2), in: spec) else { continue }
      let section = String(spec[sectionRange])
      let name = String(spec[nameRange])
      if componentNames[section]?.contains(name) != true {
        missing.append("#/components/\(section)/\(name)")
      }
    }

    #expect(missing.isEmpty, "Unresolved local OpenAPI references: \(Set(missing).sorted())")
  }

  @Test
  func documentedOperationsExactlyMatchRegisteredRoutes() throws {
    let root = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("openapi-route-test-\(UUID().uuidString)")
    let server = makeTestAPIServer(root: root)
    let implemented = server.registeredRouteSignatures
    let documented = try Self.documentedRouteSignatures(in: spec)

    #expect(documented == implemented)
  }

  @Test
  func vmStateSchemasUseRuntimeWireValues() throws {
    let spec = try spec
    let expected = Set(VMState.allCases.map(\.rawValue))

    for schemaName in ["VMResponse", "VMStateResponse"] {
      let values = try Self.enumValues(
        in: spec,
        schemaName: schemaName,
        propertyName: "state"
      )
      #expect(values == expected, "\(schemaName).state differs from VMState raw values")
    }
  }

  @Test
  func imageOperationErrorCodesMatchRuntimeWireValues() throws {
    let values = try Self.enumValues(
      in: spec,
      schemaName: "ImageOperationStatusResponse",
      propertyName: "errorCode"
    )
    let expected = Set(ImageOperationErrorCode.allCases.map(\.rawValue))

    #expect(values == expected)
  }

  @Test
  func imageNotFoundResponsesUseRuntimeErrorCodes() throws {
    let spec = try spec
    let expectedReferences = [
      (path: "/images/{id}", method: "get", component: "ImageNotFound"),
      (path: "/images/{id}", method: "delete", component: "ImageNotFound"),
      (path: "/images/pull/operations/{operationId}", method: "get", component: "ImageOperationNotFound"),
      (path: "/images/pull/operations/{operationId}", method: "delete", component: "ImageOperationNotFound"),
      (path: "/images/push", method: "post", component: "ImagePushSourceNotFound"),
      (path: "/images/push/operations/{operationId}", method: "get", component: "ImageOperationNotFound"),
      (path: "/images/push/operations/{operationId}", method: "delete", component: "ImageOperationNotFound"),
    ]

    for expected in expectedReferences {
      let block = try Self.operationBlock(in: spec, path: expected.path, method: expected.method)
      #expect(block.contains("'404':\n          $ref: '#/components/responses/\(expected.component)'"))
    }

    let imageNotFound = try Self.responseComponentBlock(in: spec, named: "ImageNotFound")
    let operationNotFound = try Self.responseComponentBlock(in: spec, named: "ImageOperationNotFound")
    let sourceNotFound = try Self.responseComponentBlock(in: spec, named: "ImagePushSourceNotFound")
    #expect(imageNotFound.contains("code: IMAGE_NOT_FOUND"))
    #expect(operationNotFound.contains("code: IMAGE_OPERATION_NOT_FOUND"))
    #expect(sourceNotFound.contains("code: NOT_FOUND"))
    #expect(sourceNotFound.contains("code: IMAGE_NOT_FOUND"))
  }

  @Test
  func everyOperationDocumentsInfrastructureResponses() throws {
    let expected = Set(["405", "413", "429", "431"])
    let responseCodes = try Self.documentedResponseCodes(in: spec)

    for (route, codes) in responseCodes {
      #expect(expected.isSubset(of: codes), "\(route.method) \(route.path) omits an infrastructure response")
    }
    #expect(try Set(responseCodes.keys) == Self.documentedRouteSignatures(in: spec))
  }

  @Test
  func everyMaintenanceBlockedMutationDocumentsServiceUnavailable() throws {
    let exclusiveMaintenanceRoutes: Set<HTTPRouteSignature> = [
      HTTPRouteSignature(method: "DELETE", path: "/v1/vms"),
      HTTPRouteSignature(method: "DELETE", path: "/v1/images"),
      HTTPRouteSignature(method: "POST", path: "/v1/system/reset"),
    ]
    let mutatingMethods = Set(["POST", "PATCH", "DELETE"])
    let responseCodes = try Self.documentedResponseCodes(in: spec)

    for (route, codes) in responseCodes
      where mutatingMethods.contains(route.method) && exclusiveMaintenanceRoutes.contains(route) == false
    {
      #expect(codes.contains("503"), "\(route.method) \(route.path) omits maintenance blocking")
    }
  }

  private static func componentNames(in spec: String) -> [String: Set<String>] {
    let supportedSections = Set(["parameters", "responses", "schemas", "securitySchemes"])
    var result: [String: Set<String>] = [:]
    var insideComponents = false
    var currentSection: String?

    for line in spec.components(separatedBy: .newlines) {
      if line == "components:" {
        insideComponents = true
        continue
      }
      guard insideComponents else { continue }

      if line.hasPrefix("  "), line.hasPrefix("    ") == false, line.hasSuffix(":") {
        let section = String(line.dropFirst(2).dropLast())
        currentSection = supportedSections.contains(section) ? section : nil
        continue
      }

      guard let currentSection,
            line.hasPrefix("    "),
            line.hasPrefix("      ") == false,
            line.hasSuffix(":") else { continue }
      let name = String(line.dropFirst(4).dropLast())
      result[currentSection, default: []].insert(name)
    }

    return result
  }

  private static func operationBlock(in spec: String, path: String, method: String) throws -> String {
    let lines = spec.components(separatedBy: .newlines)
    guard let pathIndex = lines.firstIndex(of: "  \(path):") else {
      throw OpenAPISpecTestError.missingPath(path)
    }
    guard let methodIndex = lines[pathIndex...].firstIndex(of: "    \(method):") else {
      throw OpenAPISpecTestError.missingMethod(path: path, method: method)
    }
    let endIndex = lines[(methodIndex + 1)...].firstIndex { line in
      (line.hasPrefix("    ") && line.hasPrefix("      ") == false && line.hasSuffix(":"))
        || (line.hasPrefix("  /") && line.hasSuffix(":"))
    } ?? lines.endIndex
    return lines[methodIndex ..< endIndex].joined(separator: "\n")
  }

  private static func responseComponentBlock(in spec: String, named name: String) throws -> String {
    let lines = spec.components(separatedBy: .newlines)
    guard let componentIndex = lines.firstIndex(of: "    \(name):") else {
      throw OpenAPISpecTestError.missingResponse(name)
    }
    let endIndex = lines[(componentIndex + 1)...].firstIndex { line in
      line.hasPrefix("    ") && line.hasPrefix("      ") == false && line.hasSuffix(":")
    } ?? lines.endIndex
    return lines[componentIndex ..< endIndex].joined(separator: "\n")
  }

  private static func documentedRouteSignatures(in spec: String) -> Set<HTTPRouteSignature> {
    let methods = Set(["get", "post", "put", "patch", "delete", "head", "options", "trace"])
    var result: Set<HTTPRouteSignature> = []
    var currentPath: String?
    var insidePaths = false

    for line in spec.components(separatedBy: .newlines) {
      if line == "paths:" {
        insidePaths = true
        continue
      }
      if line == "components:" { break }
      guard insidePaths else { continue }

      if line.hasPrefix("  /"), line.hasSuffix(":") {
        currentPath = String(line.dropFirst(2).dropLast())
        continue
      }
      guard let currentPath,
            line.hasPrefix("    "),
            line.hasPrefix("      ") == false,
            line.hasSuffix(":") else { continue }
      let method = String(line.dropFirst(4).dropLast())
      guard methods.contains(method) else { continue }
      result.insert(HTTPRouteSignature(method: method.uppercased(), path: "/v1" + currentPath))
    }

    return result
  }

  private static func enumValues(
    in spec: String,
    schemaName: String,
    propertyName: String
  ) throws -> Set<String> {
    let lines = spec.components(separatedBy: .newlines)
    guard let schemaIndex = lines.firstIndex(of: "    \(schemaName):") else {
      throw OpenAPISpecTestError.missingSchema(schemaName)
    }
    guard let propertyIndex = lines[schemaIndex...].firstIndex(of: "        \(propertyName):") else {
      throw OpenAPISpecTestError.missingProperty(schemaName, propertyName)
    }
    guard let enumIndex = lines[propertyIndex...].firstIndex(of: "          enum:") else {
      throw OpenAPISpecTestError.missingEnum(schemaName, propertyName)
    }

    var values: Set<String> = []
    for line in lines[(enumIndex + 1)...] {
      guard line.hasPrefix("            - ") else { break }
      values.insert(String(line.dropFirst(14)))
    }
    return values
  }

  private static func documentedResponseCodes(in spec: String) -> [HTTPRouteSignature: Set<String>] {
    let methods = Set(["get", "post", "put", "patch", "delete", "head", "options", "trace"])
    var result: [HTTPRouteSignature: Set<String>] = [:]
    var currentPath: String?
    var currentRoute: HTTPRouteSignature?
    var insidePaths = false
    var insideResponses = false

    for line in spec.components(separatedBy: .newlines) {
      if line == "paths:" {
        insidePaths = true
        continue
      }
      if line == "components:" { break }
      guard insidePaths else { continue }

      if line.hasPrefix("  /"), line.hasSuffix(":") {
        currentPath = String(line.dropFirst(2).dropLast())
        currentRoute = nil
        insideResponses = false
        continue
      }
      if line.hasPrefix("    "), line.hasPrefix("      ") == false, line.hasSuffix(":"),
         let currentPath
      {
        let method = String(line.dropFirst(4).dropLast())
        if methods.contains(method) {
          let route = HTTPRouteSignature(method: method.uppercased(), path: "/v1" + currentPath)
          currentRoute = route
          result[route] = []
        } else {
          currentRoute = nil
        }
        insideResponses = false
        continue
      }
      if line == "      responses:" {
        insideResponses = currentRoute != nil
        continue
      }
      guard insideResponses, let currentRoute,
            line.hasPrefix("        '"), line.hasSuffix("':") else { continue }
      result[currentRoute, default: []].insert(String(line.dropFirst(9).dropLast(2)))
    }

    return result
  }
}

private enum OpenAPISpecTestError: Error {
  case missingSchema(String)
  case missingProperty(String, String)
  case missingEnum(String, String)
  case missingPath(String)
  case missingMethod(path: String, method: String)
  case missingResponse(String)
}
