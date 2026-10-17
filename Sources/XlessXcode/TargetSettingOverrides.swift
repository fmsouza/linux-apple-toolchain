import Foundation
import XlessCore

extension Workspace {
    /// A copy in which the targets named by their PIF GUID (`PIFWriter.targetGUID`) carry `settings` in every build
    /// configuration, replacing the target's own value for the same setting.
    ///
    /// This is how a setting reaches one target only: a build request's command-line overrides apply to every target in
    /// the build (pods included), while a target-level setting wins over the target's xcconfig and over the project
    /// level, as in Xcode (Swift Build's settings levels: project xcconfig < project < target xcconfig < target <
    /// command line). So a setting set here must not also be a command-line override, which would win over it.
    /// Refuses a GUID that names no target of the workspace.
    public func overridingTargetSettings(_ overrides: [String: [String: String]]) throws -> Workspace {
        var remaining = Set(overrides.keys)
        let projects = projects.map { project -> XcodeProject in
            let targets = project.targets.map { target -> Target in
                let guid = PIFWriter.targetGUID(target, in: project, workspace: self)
                guard let settings = overrides[guid] else { return target }
                remaining.remove(guid)
                return target.withConfigurations(target.configurations.map { $0.merging(settings) })
            }
            return project.withTargets(targets)
        }
        if let guid = remaining.sorted().first {
            throw XlessError(.build, "no target with PIF GUID \(guid) in \(path.lastPathComponent)", fix: "report this as an xless bug")
        }
        return Workspace(name: name, path: path, projects: projects, schemes: schemes)
    }
}

extension BuildConfiguration {
    func merging(_ settings: [String: String]) -> BuildConfiguration {
        BuildConfiguration(id: id, name: name, settings: self.settings.merging(settings) { _, new in new }, baseConfigurationID: baseConfigurationID)
    }
}

extension Target {
    func withConfigurations(_ configurations: [BuildConfiguration]) -> Target {
        Target(id: id, name: name, kind: kind, configurations: configurations, defaultConfigurationName: defaultConfigurationName,
               phases: phases, dependencies: dependencies, productReferenceID: productReferenceID, packageProducts: packageProducts)
    }
}

extension XcodeProject {
    func withTargets(_ targets: [Target]) -> XcodeProject {
        XcodeProject(name: name, path: path, directory: directory, rootID: rootID, mainGroup: mainGroup, configurations: configurations,
                     defaultConfigurationName: defaultConfigurationName, developmentRegion: developmentRegion, knownRegions: knownRegions,
                     targets: targets, packageReferences: packageReferences, fileReferences: fileReferences,
                     referenceProxies: referenceProxies, provisioningStyles: provisioningStyles,
                     projectReferenceIDs: projectReferenceIDs, recoveredReferenceIDs: recoveredReferenceIDs)
    }
}
