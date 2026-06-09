//
//  Modifiers.swift
//  VerticalSplit
//
//  Created by Vedant Gurav on 28/02/2024.
//

import SwiftUI

public extension VerticalSplit {
    /// Accessory buttons shown to the left of the drag indicator in the VerticalSplit.
    /// - Parameter accessories: Accessories with their appearances and associated actions.
    func leadingAccessories(_ accessories: [SplitAccessory]) -> Self {
        var copy = self
        copy.leadingAccessories = accessories
        copy.leadingCount = accessories.count
        return copy
    }

    /// Accessory buttons shown to the left of the drag indicator in the VerticalSplit. An accessory is automatically added to open the menu if any MenuAccessories are provided.
    /// - Parameter accessories: Accessories with their appearances and associated actions.
    func trailingAccessories(_ accessories: [SplitAccessory]) -> Self {
        var copy = self
        copy.trailingAccessories = accessories
        copy.trailingCount = accessories.count + (menuAccessories.isEmpty ? 0 : 1)
        return copy
    }

    /// Larger accessory buttons shown in a pop-out menu in the VerticalSplit. A trailing accessory is automatically added to open the menu.
    /// - Parameters:
    ///   - buttonSystemName: SFSymbol for the label of the trailing accessory that opens the menu.
    ///   - buttonColor: Foreground color applied to the label of the button.
    ///   - accessories: Accessories with their appearances and associated actions
    func menuAccessories(
        systemName: String = "plus.circle.fill",
        _ accessories: [MenuAccessory]
    ) -> Self {
        var copy = self
        copy.menuSymbol = systemName
        copy.menuAccessories = accessories
        copy.trailingCount = copy.trailingAccessories.count + (accessories.isEmpty ? 0 : 1)
        return copy
    }

    /// Control whether or not logs are made for debugging.
    /// - Parameter isEnabled: Set whether logging is enabled.
    func debug(_ isEnabled: Bool) -> Self {
        var copy = self
        copy.shouldLog = true
        return copy
    }

    /// Sets the background color for the top and bottom view containers, as well as the menu buttons,
    /// - Parameter color: The preferred background color.
    func backgroundColor(_ color: Color) -> Self {
        var copy = self
        copy.bgColor = color
        copy.textColor = color.textColor
        return copy
    }

    /// Renders an extra label inside the drag pill, on the trailing side
    /// (immediately to the right of the centered drag indicator and ahead
    /// of any trailing accessory buttons). The label uses SF Mono and an
    /// animate-up `numericText` content transition, so it's a natural fit
    /// for live counters like token usage. Pass `nil` or an empty string
    /// to hide it.
    func handleTrailingText(_ text: String?) -> Self {
        var copy = self
        copy.handleTrailingText = text
        return copy
    }

    /// Detent when the user taps the bottom pane's pill (`.topFull`, e.g. "Chat").
    func collapsedTapDetent(_ detent: SplitDetent) -> Self {
        var copy = self
        copy.collapsedTapDetent = detent
        return copy
    }

    /// Detent when the user taps the top pane's pill (`.bottomFull`, truncated title).
    func collapsedTopTapDetent(_ detent: SplitDetent) -> Self {
        var copy = self
        copy.collapsedTopTapDetent = detent
        return copy
    }
}
