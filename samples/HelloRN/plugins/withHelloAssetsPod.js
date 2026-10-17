// Local config plugin: adds the local pod plugins/HelloAssets to the generated Podfile's app target.
//
// The pod ships an asset catalog through `s.resources`, the shape that CocoaPods compiles in the app's
// "[CP] Copy Pods Resources" phase (`xcrun --find actool`, then `xcrun actool … --compile <app>`), so the sample
// exercises that path: the pod's image must end up in the app's Assets.car.
//
// It also turns off CocoaPods' script-phase input/output file lists (`:disable_input_output_paths`), the usual setting
// for such pods: with the lists, the resources phase declares `Assets.car` as an output, which the app's own asset
// catalog also produces, and Xcode refuses the build ("Multiple commands produce …/Assets.car").
const fs = require('fs');
const path = require('path');
const { withDangerousMod } = require('expo/config-plugins');

const POD = "  pod 'HelloAssets', :path => '../plugins/HelloAssets'\n";
const INSTALL = "install! 'cocoapods', :disable_input_output_paths => true\n";

const insert = (text, anchor, line, podfile) => {
  if (text.includes(line)) return text;
  if (!text.includes(anchor)) throw new Error(`withHelloAssetsPod: no "${anchor.trim()}" line in ${podfile}`);
  return text.replace(anchor, `${anchor}${line}`);
};

module.exports = (config) =>
  withDangerousMod(config, [
    'ios',
    (config) => {
      const podfile = path.join(config.modRequest.platformProjectRoot, 'Podfile');
      let text = fs.readFileSync(podfile, 'utf8');
      text = insert(text, 'prepare_react_native_project!\n', INSTALL, podfile);
      text = insert(text, '  use_expo_modules!\n', POD, podfile);
      fs.writeFileSync(podfile, text);
      return config;
    },
  ]);
