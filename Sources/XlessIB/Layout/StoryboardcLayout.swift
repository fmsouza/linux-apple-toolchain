import Foundation

/// File names and `Info.plist` of a compiled `.storyboardc` (docs/research/nib-encoding.md, sections 1–2).
/// `xcode-template`, `id-long-ids`: three files, named from the view controller and root view IDs verbatim.
public enum StoryboardcLayout {
    public static let infoPlistName = "Info.plist"

    /// The view controller's nib name, also its identifier in `Info.plist`: its `storyboardIdentifier` verbatim when it
    /// has one (`vc-storyboard-identifier*`), else `UIViewController-<vcID>`.
    public static func viewControllerNibName(vcID: String, storyboardIdentifier: String? = nil) -> String {
        storyboardIdentifier ?? "UIViewController-\(vcID)"
    }

    /// `<vcID>-view-<viewID>`: the root view's nib name, also the class swapper's `UINibName`.
    public static func viewNibName(vcID: String, viewID: String) -> String { "\(vcID)-view-\(viewID)" }

    /// The binary `Info.plist`: keys in ibtool's order, three separate copies of the view controller's nib name; with a
    /// `storyboardIdentifier`, the entry point is the same object as the inner dictionary's key, and the value a second
    /// copy (eight objects, not nine: `vc-storyboard-identifier*`, `real-expo-splash-*`).
    public static func infoPlist(vcID: String, storyboardIdentifier: String? = nil) -> Data {
        let name = viewControllerNibName(vcID: vcID, storyboardIdentifier: storyboardIdentifier)
        let key: BinaryPlistWriter.Value = storyboardIdentifier == nil ? .string(name) : .tagged("identifier", .string(name))
        let entryPoint: BinaryPlistWriter.Value = storyboardIdentifier == nil ? .string(name) : .ref("identifier")
        return BinaryPlistWriter.write(.dict([
            .init(.string("UIViewControllerIdentifiersToNibNames"), .dict([.init(key, .string(name))])),
            .init(.string("UIStoryboardDesignatedEntryPointIdentifier"), entryPoint),
            .init(.string("UIStoryboardVersion"), .int(1)),
        ]))
    }
}
