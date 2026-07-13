import Foundation

enum HTTPQueryParameterError: Error, LocalizedError {
  case invalidInteger(name: String, value: String)
  case integerOutOfRange(name: String, min: Int, max: Int)
  case invalidBoolean(name: String, value: String)

  var errorDescription: String? {
    switch self {
    case .invalidInteger(let name, let value):
      "\(name) must be an integer, got '\(value)'"
    case .integerOutOfRange(let name, let min, let max):
      "\(name) must be between \(min) and \(max)"
    case .invalidBoolean(let name, let value):
      "\(name) must be 'true' or 'false', got '\(value)'"
    }
  }
}

enum HTTPQueryParameters {
  static func pagination(
    from request: HTTPRequest,
    defaultLimit: Int = 100,
    maxLimit: Int = 1000
  ) throws -> (limit: Int, offset: Int) {
    let limit = try integer(
      named: "limit",
      in: request,
      defaultValue: defaultLimit,
      min: 1,
      max: maxLimit
    )
    let offset = try integer(named: "offset", in: request, defaultValue: 0, min: 0, max: Int.max)
    return (limit, offset)
  }

  static func integer(
    named name: String,
    in request: HTTPRequest,
    defaultValue: Int,
    min: Int,
    max: Int
  ) throws -> Int {
    guard let rawValue = request.queryParameters[name], rawValue.isEmpty == false else { return defaultValue }
    guard let value = Int(rawValue) else {
      throw HTTPQueryParameterError.invalidInteger(name: name, value: rawValue)
    }
    guard value >= min, value <= max else {
      throw HTTPQueryParameterError.integerOutOfRange(name: name, min: min, max: max)
    }
    return value
  }

  static func boolean(
    named name: String,
    in request: HTTPRequest,
    defaultValue: Bool? = nil
  ) throws -> Bool? {
    guard let rawValue = request.queryParameters[name], rawValue.isEmpty == false else { return defaultValue }
    switch rawValue.lowercased() {
    case "true": return true
    case "false": return false
    default:
      throw HTTPQueryParameterError.invalidBoolean(name: name, value: rawValue)
    }
  }

  static func requiredTrue(named name: String, in request: HTTPRequest) throws -> Bool {
    try boolean(named: name, in: request, defaultValue: nil) == true
  }
}
