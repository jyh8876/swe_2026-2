import Flutter
import UIKit
import VinyloLlmCore

/// "vinylo/llama" on iOS: the same calls as Android's MainActivity, over the shared C++ core.
/// The model runs on Metal; all calls run on one serial queue.
public class VinyloLlamaPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "vinylo.llama", qos: .userInitiated)
  private var loadedPath: String?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "vinylo/llama", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VinyloLlamaPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "available":
      result(true)
    case "excludeFromBackup":
      guard let path = args["path"] as? String else { result(nil); return }
      var url = URL(fileURLWithPath: path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
      }
    case "cancel":
      vl_cancel()
      result(nil)
    case "unload":
      queue.async {
        vl_unload()
        self.loadedPath = nil
        DispatchQueue.main.async { result(nil) }
      }
    case "complete":
      guard let path = args["path"] as? String, let prompt = args["prompt"] as? String else {
        result(FlutterError(code: "failed", message: "missing arguments", details: nil))
        return
      }
      let maxTokens = args["maxTokens"] as? Int ?? 1024
      let nCtx = args["nCtx"] as? Int ?? 4096
      let closeDepth = args["closeDepth"] as? Int ?? 0
      queue.async {
        if self.loadedPath != path {
          guard vl_load(path, Int32(nCtx), 99, nil) != 0 else {
            DispatchQueue.main.async {
              result(FlutterError(code: "failed", message: "model load failed (not enough free memory?)", details: nil))
            }
            return
          }
          self.loadedPath = path
        }
        let out = Output()
        let rc = withExtendedLifetime(out) {
          vl_generate(prompt, Int32(maxTokens), Int32(closeDepth), { bytes, len, user in
            guard let bytes, let user else { return }
            Unmanaged<Output>.fromOpaque(user).takeUnretainedValue()
              .data.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: Int(len))
          }, Unmanaged.passUnretained(out).toOpaque())
        }
        let text = String(decoding: out.data, as: UTF8.self)
        DispatchQueue.main.async {
          switch rc {
          case -2: result(FlutterError(code: "too_long", message: "prompt too long", details: nil))
          case ..<0: result(FlutterError(code: "failed", message: "generation failed", details: nil))
          default: result(text)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private final class Output { var data = Data() }
}
