//
//  ObservableAUParameter.swift
//  OngakuEffects
//
//  Created by John Forde on 24/10/2026.
//

import SwiftUI
import AudioToolbox

/// Base-class for SwiftUI-capable AUParameterNodes
///
/// This implementation provides a central point AUParameterGroup nodes to build a set of
/// observable children, and also enables us to traverse the parameter tree using dynamicMemberLookup
/// and subscript notation (i.e. parameterTree.paramGroup.parameter)
///
/// This does *not* provide any of Swift's usual type-safety benefits, and may result in fatal errors if the
/// implementation attempts to access the subscript of an ObservableAUParameter (which has no children, as it's not a group).
@MainActor
@dynamicMemberLookup
class ObservableAUParameterNode {
    /// Told when the window changes a parameter (its address and value before), for undo.
    typealias UserChangeHandler = @MainActor (AUParameterAddress, AUValue) -> Void

    /// Create an ObservableAUParameterNode
    ///
    /// This creates the appropriate subclass, depending on the type of the passed in AUParameterNode.
    /// `defaults` are the parameters' defaults by address, for resetting them.
    class func create(
        _ parameterNode: AUParameterNode, onUserChange: UserChangeHandler? = nil, defaults: [AUParameterAddress: AUValue] = [:]
    ) -> ObservableAUParameterNode {
        switch parameterNode {
        case let parameter as AUParameter:
            return ObservableAUParameter(parameter, onUserChange: onUserChange, defaultValue: defaults[parameter.address])
        case let group as AUParameterGroup:
            return ObservableAUParameterGroup(group, onUserChange: onUserChange, defaults: defaults)
        default:
            fatalError("Unexpected AUParameterNode subclass")
        }
    }

    subscript<T>(dynamicMember identifier: String) -> T {
        guard let groupSelf = self as? ObservableAUParameterGroup else {
            fatalError("Calling subscript is only supported on ObservableAUParameterGroups, you called it on \(self)")
        }

        guard let node = groupSelf.children[identifier] else {
            if groupSelf.children.isEmpty {
                fatalError("This group has no children")
            }

            let availableChildren = groupSelf.children.keys.joined(separator: "\n")

            print("Parameter Group \(groupSelf) doesn't have a child node named \(identifier), did you mean one of: \n \(availableChildren)")
            fatalError()
        }

        guard let subNode = node as? T else {
            fatalError("Parameter node named \(identifier) cannot be converted to the requested type")
        }

        return subNode
    }

    subscript(dynamicMember identifier: String) -> ObservableAUParameterNode {
        guard let groupSelf = self as? ObservableAUParameterGroup else {
            fatalError("Calling subscript is only supported on ObservableAUParameterGroups, you called it on \(self)")
        }

        guard let parameter = groupSelf.children[identifier] else {
            if groupSelf.children.isEmpty {
                fatalError("This group has no children")
            }

            let availableChildren = groupSelf.children.keys.joined(separator: "\n")

            print("Parameter Group \(groupSelf) doesn't have a child node named \(identifier), did you mean one of: \n \(availableChildren)")
            fatalError()
        }

        return parameter
    }

    private func asParameter() -> ObservableAUParameter {
        guard let parameter = self as? ObservableAUParameter else {
            fatalError("Node is not a parameter")
        }
        return parameter
    }

    subscript(dynamicMember keyPath: ReferenceWritableKeyPath<ObservableAUParameter, Float>) -> Float {
        get { self.asParameter()[keyPath: keyPath] }
        set { self.asParameter()[keyPath: keyPath] = newValue }
    }
}

/// An Observable version of AUParameterGroup
///
/// The primary purpose here is to expose observable versions of the group's child parameters.
///
final class ObservableAUParameterGroup: ObservableAUParameterNode {

    private(set) var children: [String: ObservableAUParameterNode]

    init(_ parameterGroup: AUParameterGroup, onUserChange: UserChangeHandler? = nil, defaults: [AUParameterAddress: AUValue] = [:]) {
        children = parameterGroup.children.reduce(
            into: [String: ObservableAUParameterNode]()
        ) { dict, node in
            let observableNode = ObservableAUParameterNode.create(node, onUserChange: onUserChange, defaults: defaults)
            dict[node.identifier] = observableNode
        }
    }
}

/// An Observable version of AUParameter
///
/// ObservableAUParameter is intended to be used directly in SwiftUI views as an ObservedObject,
/// allowing us to expose a binding to the parameter's value, as well as associated parameter data,
/// like the minimum, maximum, and default values for the parameter.
///
/// The ObservableAUParameter can also manage automation event types by calling
/// `onEditingChanged()` whenever a UI element will change its editing state.
@Observable
final class ObservableAUParameter: ObservableAUParameterNode {

    private weak var parameter: AUParameter?
    private var observerToken: AUParameterObserverToken!
    private var editingState: EditingState = .inactive
    @ObservationIgnored private let onUserChange: UserChangeHandler?

    let min: AUValue
    let max: AUValue
    let displayName: String
    /// Where Option-click (and an instrument knob's double-click) puts it back.
    let defaultValue: AUValue?
    let unit: AudioUnitParameterUnit
    let address: AUParameterAddress
    let valueStrings: [String]?
    /// What a custom unit is called ("LUFS").
    let unitName: String?
    /// Whether the value is best changed by ratios (frequencies, times) rather than steps.
    let isLogarithmic: Bool

    init(_ parameter: AUParameter, onUserChange: UserChangeHandler? = nil, defaultValue: AUValue? = nil) {
        self.parameter = parameter
        self.onUserChange = onUserChange
        self.defaultValue = defaultValue
        self.value = parameter.value
        self.min = parameter.minValue
        self.max = parameter.maxValue
        self.displayName = parameter.displayName
        self.unit = parameter.unit
        self.address = parameter.address
        self.valueStrings = parameter.valueStrings
        self.unitName = parameter.unitName
        self.isLogarithmic = parameter.flags.contains(.flag_DisplayLogarithmic)
        super.init()

        /// Use the parameter.token(byAddingParameterObserver:) function to monitor for parameter
        /// changes from the host. The only role of this callback is to update the UI if the value is changed by the host.
        self.observerToken = parameter.token { @Sendable (_ address: AUParameterAddress, _ auValue: AUValue) in

            DispatchQueue.main.async {
                guard address == self.parameter?.address else { return }
                
                // Don't update the UI if the user is currently interacting
                guard self.editingState == .inactive else { return }

                self.editingState = .hostUpdate
                self.value = auValue
                self.editingState = .inactive
            }
        }
    }

    var value: AUValue {
        didSet {
            /// If the editing state is .hostUpdate, don't propagate this back to the host
            guard editingState != .hostUpdate else { return }
            if oldValue != value { onUserChange?(address, oldValue) }

            let automationEventType = resolveEventType()
            parameter?.setValue(
                value,
                originator: observerToken,
                atHostTime: 0,
                eventType: automationEventType
            )
        }
    }

    var boolValue: Bool {
       get {
		   value >= 0.5
        }
        set {
            value = newValue ? 1.0 : 0.0
        }
    }

    /// A callback for UI elements to notify the Parameter when UI editing state changes
    ///
    /// This is the core mechanism for ensuring correct automation behavior. With native SwiftUI elements like `Slider`,
    /// this method should be passed directly into the `onEditingChanged:` argument.
    ///
    /// As long as the UI Element correctly sets the editing state, then the ObservableAUParameter's calls to
    /// AUParameter.setValue will contain the correct automation event type.
    ///
    /// `onEditingChanged` should be called with `true` before the first value is sent, so that it can be sent with a
    /// `.touch` event. It's expected that `onEditingChanged` is called with a value of `false` to mark the end
    /// of interaction *after* the last value has been sent, since this is how SwiftUI's `Slider` and `Stepper` views behave.
    func onEditingChanged(_ editing: Bool) {
        if editing {
            editingState = .began
        } else {
            editingState = .ended

            // We set the value here again to prompt its `didSet` implementation, so that we can send the appropriate `.release` event.
            value = value
        }
    }

    /// Puts the parameter back at its default, as one touch (so hosts record it as a move,
    /// and the window can undo it).
    func resetToDefault() {
        guard let defaultValue, defaultValue != value else { return }
        onEditingChanged(true)
        value = defaultValue
        onEditingChanged(false)
    }

    private func resolveEventType() -> AUParameterAutomationEventType {
        let eventType: AUParameterAutomationEventType
        switch editingState {
        case .began:
            eventType = .touch
            editingState = .active
        case .ended:
            eventType = .release
            editingState = .inactive
        default:
            eventType = .value
        }
        return eventType
    }

    private enum EditingState {
        case inactive
        case began
        case active
        case ended
        case hostUpdate
    }
}

extension AUAudioUnit {
    // Can we subclass the Parameter tree to set that on the AUAudioUnit?

    @MainActor var observableParameterTree: ObservableAUParameterGroup? {
        observableParameterTree(onUserChange: nil)
    }

    /// The parameter tree for a window, telling `onUserChange` about the window's changes.
    @MainActor func observableParameterTree(
        onUserChange: ObservableAUParameterNode.UserChangeHandler?
    ) -> ObservableAUParameterGroup? {
        guard let paramTree = self.parameterTree else { return nil }
        let defaults = (self as? OngakuEffectsAudioUnit)?.parameterDefaults ?? [:]
        return ObservableAUParameterGroup(paramTree, onUserChange: onUserChange, defaults: defaults)
    }
}
