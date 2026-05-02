import Foundation

/// Single source of truth for application version information.
///
/// All version data originates from Xcode build settings:
///   - `MARKETING_VERSION`  →  `CFBundleShortVersionString`  →  `AppVersion.marketing`
///   - `CURRENT_PROJECT_VERSION`  →  `CFBundleVersion`  →  `AppVersion.build`
///
/// **To bump the version**, edit these two values in project.pbxproj
/// (or via Xcode → Target → General → Identity):
///   - `MARKETING_VERSION` (e.g. "0.2.0", "1.0.0-beta.1")
///   - `CURRENT_PROJECT_VERSION` (e.g. 1, 2, 3  - integer build number)
///
/// Everything else  - About window, /health API, OpenAPI spec  - reads from here.
enum AppVersion {
  /// Marketing version string, e.g. "0.1.0" or "1.0.0-beta.1"
  static let marketing: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

  /// Build number string, e.g. "1", "42"
  static let build: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

  /// Full display string, e.g. "0.1.0 (1)"
  static let full: String = "\(marketing) (\(build))"
}
