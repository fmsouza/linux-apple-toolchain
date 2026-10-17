// Local config plugin: adds the `HelloExtension` Action extension target to the generated iOS project.
//
// It uses the same `xcode` project API (`addTarget(…, 'app_extension', …)`) that community extension plugins use, so
// the generated project has the shape xless meets in real apps: the app embeds the .appex through a "Copy Files"
// phase (PlugIns) and there is no PBXTargetDependency (Xcode finds the dependency implicitly from the product).
const fs = require('fs');
const path = require('path');
const { withDangerousMod, withXcodeProject } = require('expo/config-plugins');

const NAME = 'HelloExtension';
const SOURCES = ['ActionViewController.swift'];
const FILES = [...SOURCES, 'Info.plist', `${NAME}.entitlements`];

// Copies plugins/HelloExtension/* into ios/HelloExtension/.
const withExtensionFiles = (config) =>
  withDangerousMod(config, [
    'ios',
    (config) => {
      const from = path.join(config.modRequest.projectRoot, 'plugins', NAME);
      const to = path.join(config.modRequest.platformProjectRoot, NAME);
      fs.mkdirSync(to, { recursive: true });
      for (const file of FILES) fs.copyFileSync(path.join(from, file), path.join(to, file));
      return config;
    },
  ]);

const findTarget = (project) => {
  const targets = project.pbxNativeTargetSection();
  return Object.keys(targets).find(
    (key) => !key.endsWith('_comment') && [NAME, `"${NAME}"`].includes(targets[key].name),
  );
};

const withExtensionTarget = (config) =>
  withXcodeProject(config, (config) => {
    const project = config.modResults;
    if (findTarget(project)) return config;

    const bundleIdentifier = `${config.ios.bundleIdentifier}.${NAME}`;
    const target = project.addTarget(NAME, 'app_extension', NAME, bundleIdentifier);

    // Group ios/HelloExtension under the project's main group.
    const group = project.addPbxGroup(FILES, NAME, NAME);
    const mainGroup = project.getFirstProject().firstProject.mainGroup;
    project.addToPbxGroup(group.uuid, mainGroup);

    project.addBuildPhase(SOURCES, 'PBXSourcesBuildPhase', 'Sources', target.uuid);
    project.addBuildPhase([], 'PBXFrameworksBuildPhase', 'Frameworks', target.uuid);
    project.addBuildPhase([], 'PBXResourcesBuildPhase', 'Resources', target.uuid);

    const settings = {
      APPLICATION_EXTENSION_API_ONLY: 'YES',
      CLANG_ENABLE_MODULES: 'YES',
      CODE_SIGN_ENTITLEMENTS: `"${NAME}/${NAME}.entitlements"`,
      CURRENT_PROJECT_VERSION: `"${config.ios.buildNumber || '1'}"`,
      DEVELOPMENT_TEAM: `"${config.ios.appleTeamId}"`,
      INFOPLIST_FILE: `"${NAME}/Info.plist"`,
      IPHONEOS_DEPLOYMENT_TARGET: '17.0',
      MARKETING_VERSION: `"${config.version}"`,
      SWIFT_VERSION: '5.9',
      TARGETED_DEVICE_FAMILY: '"1,2"',
    };
    const configurations = project.pbxXCBuildConfigurationSection();
    const listId = project.pbxNativeTargetSection()[target.uuid].buildConfigurationList;
    for (const { value } of project.pbxXCConfigurationList()[listId].buildConfigurations) {
      Object.assign(configurations[value].buildSettings, settings);
    }
    return config;
  });

module.exports = (config) => withExtensionTarget(withExtensionFiles(config));
