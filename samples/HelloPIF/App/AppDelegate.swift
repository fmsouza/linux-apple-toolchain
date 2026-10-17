import UIKit
import HelloKit

@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let label = UILabel()
        label.text = Greeter().shout(HelloCoreGreeting("PIF"))
        label.textAlignment = .center
        let root = UIViewController()
        root.view = label
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = root
        window?.makeKeyAndVisible()
        return true
    }
}
