import Flutter
import UIKit

// VyseTV: TorrServerKit.xcframework is fetched when the pod is installed and is
// not always there. Without it the plugin still builds and reports that there
// is no engine (VyseTV does not start torrents on iOS: Torrents.supported).
#if canImport(TorrServerKit)
  import TorrServerKit
#endif

public class TorrserverFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "torrserver_flutter", binaryMessenger: registrar.messenger())
    let instance = TorrserverFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  #if !canImport(TorrServerKit)
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      switch call.method {
      case "hasEngine":
        result(false)
      case "isRunning":
        result(false)
      case "startServer", "stopServer":
        result(
          FlutterError(code: "UNAVAILABLE", message: "The torrent engine is not part of this build", details: nil))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  #else
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startServer":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "Arguments must be a dictionary", details: nil))
        return
      }
      let port = args["port"] as? Int ?? 8090
      let dataDir = args["dataDir"] as? String ?? ""

      DispatchQueue.global(qos: .userInitiated).async {
        let errStr = TorrserverkitStartServer(port, dataDir)
        DispatchQueue.main.async {
          if !errStr.isEmpty {
            result(FlutterError(code: "START_FAILED", message: errStr, details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "stopServer":
      DispatchQueue.global(qos: .userInitiated).async {
        let errStr = TorrserverkitStopServer()
        DispatchQueue.main.async {
          if !errStr.isEmpty {
            result(FlutterError(code: "STOP_FAILED", message: errStr, details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "hasEngine":
      // VyseTV: this build carries the engine (the other branch of this file answers false)
      result(true)
    case "isRunning":
      let running = TorrserverkitIsRunning()
      result(running)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  #endif
}
