import Tauri
import UIKit
import WebKit

class HelloPlugin: Plugin {
  @objc public func ping(_ invoke: Invoke) {
    invoke.resolve(["value": "pong"])
  }
}

@_cdecl("init_plugin_hello")
func initPlugin() -> Plugin {
  return HelloPlugin()
}
