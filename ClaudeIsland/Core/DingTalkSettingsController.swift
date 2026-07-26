import Combine
import Foundation

/// Publishes DingTalk settings expansion state for menu geometry updates.
@MainActor
final class DingTalkSettingsController: ObservableObject {
    static let shared = DingTalkSettingsController()

    @Published var isExpanded = false

    private init() {}

    /// Extra menu height required by the expanded DingTalk form.
    var expandedPickerHeight: CGFloat {
        isExpanded ? 250 : 0
    }
}
