// Local config plugin: adopts the UIKit scene life cycle, which apps built with the iOS 27 SDK must use. Without it,
// UIKit stops the app at launch on iOS 27 ("Application failed to launch: UIScene life cycle is required for apps
// built with this SDK", an EXC_BREAKPOINT in _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption). Expo SDK
// 57's app delegate template creates its window in application(_:didFinishLaunchingWithOptions:) and declares no scene.
//
// The plugin:
// - adds a UIApplicationSceneManifest with one window scene configuration whose delegate is SceneDelegate;
// - moves the window out of the app delegate: SceneDelegate creates it for its UIWindowScene and starts React Native
//   in it with the app delegate's factory. The app delegate keeps the factory (and its subscribers, which Expo calls
//   from didFinishLaunching).
// It refuses (throws) when the generated AppDelegate.swift does not have the shape it rewrites.
const { withAppDelegate, withInfoPlist } = require('expo/config-plugins');

const WINDOW = `#if os(iOS) || os(tvOS)
    window = UIWindow(frame: UIScreen.main.bounds)
    factory.startReactNative(
      withModuleName: "main",
      in: window,
      launchOptions: launchOptions)
#endif
`;

const SCENE_DELEGATE = `
// Added by plugins/withSceneLifecycle.js: the UIKit scene life cycle (required by the iOS 27 SDK).
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene, let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    let window = UIWindow(windowScene: windowScene)
    self.window = window
    appDelegate.window = window
    appDelegate.reactNativeFactory?.startReactNative(withModuleName: "main", in: window, launchOptions: nil)
  }
}
`;

module.exports = (config) => {
  config = withInfoPlist(config, (config) => {
    config.modResults.UIApplicationSceneManifest = {
      UIApplicationSupportsMultipleScenes: false,
      UISceneConfigurations: {
        UIWindowSceneSessionRoleApplication: [
          {
            UISceneConfigurationName: 'Default Configuration',
            UISceneDelegateClassName: '$(PRODUCT_MODULE_NAME).SceneDelegate',
          },
        ],
      },
    };
    return config;
  });
  return withAppDelegate(config, (config) => {
    const delegate = config.modResults;
    if (delegate.language !== 'swift') throw new Error(`withSceneLifecycle: AppDelegate is ${delegate.language}, not Swift`);
    if (delegate.contents.includes('class SceneDelegate')) return config;
    if (!delegate.contents.includes(WINDOW)) {
      throw new Error('withSceneLifecycle: AppDelegate.swift does not create its window the way Expo SDK 57 does');
    }
    delegate.contents = delegate.contents.replace(WINDOW, '') + SCENE_DELEGATE;
    return config;
  });
};
