import Foundation

/// The root object, proxies and outlet connections (docs/research/nib-encoding.md, sections 3 and 6
/// "UIProxyObject and outlet connections"). Proven by every golden, e.g. `core-safearea`, `core-minimal`.
extension ArchiveBuilder {
    /// A `UIProxyObject` for `IBFilesOwner`, `IBFirstResponder` or `UIStoryboardPlaceholder`; one per identifier.
    func proxy(_ identifier: String) -> ObjectRef {
        unique("UIProxyObject|" + identifier) {
            let p = object("UIProxyObject")
            set(p, "UIProxiedObjectIdentifier", string(identifier))
            return p
        }
    }

    /// A `UIRuntimeOutletConnection`: `UILabel`, `UISource`, `UIDestination`.
    func outlet(_ label: String, source: ObjectRef, destination: ObjectRef) -> ObjectRef {
        let c = object("UIRuntimeOutletConnection")
        set(c, "UILabel", string(label))
        set(c, "UISource", source)
        set(c, "UIDestination", destination)
        return c
    }

    /// The root `NSObject` (#0): the three lists, four keys sharing the empty `NSArray`, and `IBUINibLNEVersionKey` = 1
    /// (unless `lneVersionKey` is false: Xcode 26.2's view nibs other than plain views, `XcodeToolsProfile.NibEncoding`).
    /// With accessibility configurations, `UINibAccessibilityConfigurationsKey` is an `NSArray` of them instead
    /// (`acc-kinds-order`; the other three keys still share the empty array, first referenced by the visible windows).
    func nibRoot(topLevel: [ObjectRef], objects list: [ObjectRef], connections: [ObjectRef],
                 accessibilityConfigurations: [ObjectRef] = [], lneVersionKey: Bool = true) -> ObjectRef {
        let root = object("NSObject")
        set(root, "UINibTopLevelObjectsKey", array(topLevel))
        set(root, "UINibObjectsKey", array(list))
        set(root, "UINibConnectionsKey", array(connections))
        let empty = array([])
        for key in ["UINibVisibleWindowsKey", "UINibAccessibilityConfigurationsKey", "UINibTraitStorageListsKey", "UINibKeyValuePairsKey"] {
            if key == "UINibAccessibilityConfigurationsKey", !accessibilityConfigurations.isEmpty {
                set(root, key, array(accessibilityConfigurations))
            } else {
                set(root, key, empty)
            }
        }
        if lneVersionKey { set(root, "IBUINibLNEVersionKey", .int8(1)) }
        return root
    }
}
