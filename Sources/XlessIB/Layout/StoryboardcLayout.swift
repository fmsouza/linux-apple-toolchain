import Foundation

/// File names and `Info.plist` of a compiled `.storyboardc` (docs/research/nib-encoding.md, sections 1–2).
/// `xcode-template`, `id-long-ids`: three files, named from the view controller and root view IDs verbatim.
public enum StoryboardcLayout {
    public static let infoPlistName = "Info.plist"

    /// `UIViewController-<vcID>`: the view controller's nib name, also its identifier in `Info.plist`.
    public static func viewControllerNibName(vcID: String) -> String { "UIViewController-\(vcID)" }

    /// `<vcID>-view-<viewID>`: the root view's nib name, also the class swapper's `UINibName`.
    public static func viewNibName(vcID: String, viewID: String) -> String { "\(vcID)-view-\(viewID)" }

    /// The binary `Info.plist`: keys in ibtool's order, three separate copies of the view controller's nib name.
    public static func infoPlist(vcID: String) -> Data {
        let name = viewControllerNibName(vcID: vcID)
        return BinaryPlistWriter.write(.dict([
            .init(.string("UIViewControllerIdentifiersToNibNames"), .dict([.init(.string(name), .string(name))])),
            .init(.string("UIStoryboardDesignatedEntryPointIdentifier"), .string(name)),
            .init(.string("UIStoryboardVersion"), .int(1)),
        ]))
    }
}
