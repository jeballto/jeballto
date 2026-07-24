import Darwin
import Foundation

@_silgen_name("flock")
func imageWorkFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Shared cache locations for disposable Jeballto data.
enum JeballtoCachePaths {
  private static let imageWorkSessionId = UUID().uuidString

  static var root: URL {
    if let override = ProcessInfo.processInfo.environment["JEBALLTO_CACHE_DIR"],
       let overrideURL = validatedOverrideURL(for: override)
    {
      return overrideURL
    }
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Jeballto", isDirectory: true)
  }

  static func validatedOverrideURL(for path: String) -> URL? {
    guard path.isEmpty == false, path.hasPrefix("/") else { return nil }

    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
    guard url.path != "/", url.path != homeDirectory else { return nil }
    return url
  }

  static var ipswCache: URL {
    root.appendingPathComponent("IPSWCache", isDirectory: true)
  }

  static var imageWork: URL {
    root.appendingPathComponent("ImageWork", isDirectory: true)
  }

  static var imageWorkSession: URL {
    imageWork
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(imageWorkSessionId, isDirectory: true)
  }
}
