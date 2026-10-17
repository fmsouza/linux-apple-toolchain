# A local pod that ships only an asset catalog through `resources` (no sources): CocoaPods' [CP] Copy Pods Resources
# phase compiles it into the app's Assets.car with `xcrun actool` (scripts/test-rn-linux.sh checks the image is there).
Pod::Spec.new do |s|
  s.name         = 'HelloAssets'
  s.version      = '1.0.0'
  s.summary      = 'An asset catalog delivered as a pod resource.'
  s.homepage     = 'https://example.com/hello-assets'
  s.license      = { :type => 'MIT' }
  s.author       = 'Example'
  s.source       = { :git => 'https://example.com/hello-assets.git', :tag => s.version.to_s }
  s.platforms    = { :ios => '16.4' }
  s.resources    = ['HelloAssets.xcassets']
end
