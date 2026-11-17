import Flutter
import UIKit

/// iOS side of the Dart `vynilo/links` channel (see lib/app/platform_services.dart, class Links):
/// - `open` {url}: opens an http(s) link in the browser (Spotify login, lyric search, Pinterest).
/// - `initialLink`: the URL the app was launched with (cold start), read once.
/// - `link` (native → Dart): a URL that arrives while running, e.g. vynilo://spotify-callback.
enum LinkBridge {
  private static var channel: FlutterMethodChannel?
  private static var initialLink: String?

  static func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "vynilo/links", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "open":
        guard let args = call.arguments as? [String: Any],
              let text = args["url"] as? String,
              let url = URL(string: text) else {
          result(FlutterError(code: "bad_url", message: "Missing or invalid url", details: nil))
          return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
          if ok {
            result(nil)
          } else {
            result(FlutterError(code: "open_failed", message: "Could not open the link", details: nil))
          }
        }
      case "initialLink":
        result(initialLink)
        initialLink = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  /// Called by SceneDelegate for every incoming URL.
  static func deliver(_ url: URL) {
    if let ch = channel {
      ch.invokeMethod("link", arguments: url.absoluteString)
    } else {
      initialLink = url.absoluteString
    }
  }
}
