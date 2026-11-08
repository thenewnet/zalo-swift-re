import Testing
import Foundation
@testable import Olaz

// Temporary CI diagnostic: where resource lookup goes under `swift test`.
@Test func zzResourceDiag() {
    print("DIAG main.resourceURL=\(Bundle.main.resourceURL?.path ?? "nil")")
    print("DIAG main.bundleURL=\(Bundle.main.bundleURL.path)")
    print("DIAG JSModules=\(ResourceLocator.url(forSubdirectory: "JSModules")?.path ?? "nil")")
    print("DIAG Resources=\(ResourceLocator.url(forSubdirectory: "Resources")?.path ?? "nil")")
}
