import Foundation

/// Shared cache locations for disposable Jeballto data.
enum JeballtoCachePaths {
  static var root: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Jeballto", isDirectory: true)
  }

  static var ipswCache: URL {
    root.appendingPathComponent("IPSWCache", isDirectory: true)
  }

  static var imageWork: URL {
    root.appendingPathComponent("ImageWork", isDirectory: true)
  }
}
