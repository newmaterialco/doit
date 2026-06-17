import SwiftUI

// MARK: - Category chrome

enum OptionsCategoryStyle {
    static func systemImage(for category: String?) -> String {
        switch category?.lowercased() {
        case "flight", "flights": return "airplane"
        case "hotel", "hotels": return "bed.double.fill"
        case "event", "events": return "calendar.badge.clock"
        case "movie", "movies": return "ticket.fill"
        case "haircut", "haircuts", "salon": return "scissors"
        case "golf", "tee_time", "tee_times": return "figure.golf"
        case "rental_car", "rental_cars", "car", "cars": return "car.fill"
        case "restaurant", "restaurants", "dining": return "fork.knife"
        default: return "list.bullet.rectangle"
        }
    }
}

// MARK: - Shared row + list

struct OptionsRowView: View {
    let item: OptionsItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if let badge = item.badge {
                            Text(badge)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.primary)
                        }
                    }

                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }

            if !item.fields.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(field.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        )
    }
}

struct OptionsListContent: View {
    let payload: OptionsPayload
    let categoryIcon: String
    let headerTitle: String
    var maxVisibleItems: Int? = nil
    @Binding var isExpanded: Bool

    init(
        payload: OptionsPayload,
        categoryIcon: String,
        headerTitle: String,
        maxVisibleItems: Int? = nil,
        isExpanded: Binding<Bool> = .constant(true)
    ) {
        self.payload = payload
        self.categoryIcon = categoryIcon
        self.headerTitle = headerTitle
        self.maxVisibleItems = maxVisibleItems
        self._isExpanded = isExpanded
    }

    private var visibleItems: [OptionsItem] {
        guard let maxVisibleItems, !isExpanded else { return payload.items }
        return Array(payload.items.prefix(maxVisibleItems))
    }

    private var hasHiddenItems: Bool {
        guard let maxVisibleItems else { return false }
        return payload.items.count > maxVisibleItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: categoryIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(headerTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    if let summary = payload.summary {
                        Text(summary)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleItems) { item in
                    OptionsRowView(
                        item: item,
                        isSelected: payload.selectedID == item.id
                    )
                }
            }

            if hasHiddenItems {
                Button {
                    ArtifactCardLayout.playTapHaptic()
                    withAnimation(.smooth(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded ? "Show fewer" : "Show \(payload.items.count - (maxVisibleItems ?? 0)) more")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Chat preview

/// Structured options list inside a choice interaction (mid-task compare).
struct OptionsPreview: View {
    let payload: OptionsPayload

    @State private var isExpanded = false

    private let cornerRadius: CGFloat = 20

    var body: some View {
        OptionsListContent(
            payload: payload,
            categoryIcon: OptionsCategoryStyle.systemImage(for: payload.category),
            headerTitle: payload.categoryDisplayName,
            maxVisibleItems: 4,
            isExpanded: $isExpanded
        )
        .padding(20)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppSemanticColors.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 3)
    }
}

// MARK: - Header artifact card

struct OptionsArtifactCard: View {
    let artifact: TodoArtifact

    @State private var isExpanded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let payload = artifact.optionsPayload {
            VStack(alignment: .leading, spacing: 0) {
                OptionsListContent(
                    payload: payload,
                    categoryIcon: OptionsCategoryStyle.systemImage(for: payload.category),
                    headerTitle: artifact.title ?? payload.categoryDisplayName,
                    maxVisibleItems: 5,
                    isExpanded: $isExpanded
                )

                if let bookingURL = selectedItemURL(payload: payload) {
                    Button {
                        ArtifactCardLayout.playTapHaptic()
                        openURL(bookingURL)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Open booking")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color.blue)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(ArtifactCardLayout.contentPadding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppSemanticColors.elevatedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppSemanticColors.separator, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func selectedItemURL(payload: OptionsPayload) -> URL? {
        guard let selectedID = payload.selectedID else { return nil }
        return payload.items.first(where: { $0.id == selectedID })?.url
    }
}
