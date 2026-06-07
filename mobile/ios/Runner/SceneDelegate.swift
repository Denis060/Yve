import UIKit

// Placeholder retained for forward-compatibility with newer Flutter
// releases that adopt the UIScene lifecycle. This toolchain (Flutter
// 3.35.7) uses the classic FlutterAppDelegate window lifecycle, so the
// Info.plist intentionally omits a scene manifest and iOS never
// instantiates this class.
//
// When the project is built with a Flutter version that provides
// `FlutterSceneDelegate`, restore:
//   class SceneDelegate: FlutterSceneDelegate {}
// and re-add the UIApplicationSceneManifest entry in Info.plist.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
}
