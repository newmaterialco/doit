import SwiftUI

/// Stacked white intent cards for the task detail header. This mirrors the
/// Live Activity widget's `IntentCard` treatment while staying backed by
/// the app's `AgentActivity` snapshot from `TodoStore`.
struct AgentActivityCard: View {
    let activity: AgentActivity
    let isTaskActive: Bool

    private static let maxVisibleCards = 3

    var body: some View {
        ZStack {
            ForEach(Array(stackItems.enumerated()), id: \.element.id) { index, item in
                let depth = stackItems.count - index - 1
                AgentIntentStackCard(item: item, depth: depth)
            }
        }
        .compositingGroup()
        .frame(height: cardStackHeight)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.28), value: activity.activityContentSignature)
        .animation(.smooth(duration: 0.28), value: isTaskActive)
        .animation(.smooth(duration: 0.28), value: activity.recentSteps.map(\.id))
    }

    private var stackItems: [AgentIntentCardModel] {
        // Mirror the widget: stacked cards are *previous* intents only;
        // the snapshot's top-level fields drive the front card.
        var items = activity.stackPreviousSteps.map(AgentIntentCardModel.init(step:))
        items.append(currentCard)
        return Array(items.suffix(Self.maxVisibleCards))
    }

    private var currentCard: AgentIntentCardModel {
        if activity.isTerminal {
            return AgentIntentCardModel(activity: activity)
        }
        if isTaskActive, !activity.isRunning, activity.resolvedState != .paused {
            if !activity.primaryStatusText.isEmpty {
                return AgentIntentCardModel(activity: activity)
            }
            return AgentIntentCardModel(
                id: "rerun-\(activity.todo_id.uuidString)",
                title: "Getting started…",
                symbolName: AgentToolCategory.thinking.symbolName,
                isCompleted: false
            )
        }
        return AgentIntentCardModel(activity: activity)
    }

    private var cardStackHeight: CGFloat {
        60 + CGFloat(max(0, stackItems.count - 1)) * 10
    }
}

private struct AgentIntentCardModel: Identifiable, Hashable {
    let id: String
    let title: String
    let symbolName: String
    let isCompleted: Bool

    init(id: String, title: String, symbolName: String, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isCompleted = isCompleted
    }

    init(activity: AgentActivity) {
        id = "current-\(activity.todo_id.uuidString)-\(activity.activityContentSignature)"
        title = activity.primaryStatusText
        symbolName = activity.resolvedCategory.symbolName
        switch activity.resolvedState {
        case .completed:
            isCompleted = true
        case .failed:
            isCompleted = false
        case .paused, .running:
            isCompleted = false
        }
    }

    init(step: AgentActivityStep) {
        id = step.id
        title = step.primaryStatusText
        symbolName = step.tool_category.symbolName
        isCompleted = step.isCompleted
    }
}

private struct AgentIntentStackCard: View {
    let item: AgentIntentCardModel
    let depth: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isCompleted ? "checkmark" : item.symbolName)
                .font(.system(size: 12, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.secondary)
                .frame(width: 21, height: 21)
                .background(Circle().foregroundStyle(AppSemanticColors.neutralFill))

            Text(item.title)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(height: 60)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 60)
        .background(
            AppSemanticColors.elevatedSurface,
            in: .rect(cornerRadius: depth == 0 ? 16 : 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: depth == 0 ? 16 : 10, style: .continuous)
                .strokeBorder(AppSemanticColors.separator.opacity(depth == 0 ? 1 : 0.6), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(depth == 0 ? 0.08 : 0.03), radius: depth == 0 ? 12 : 4, x: 0, y: 3)
        .scaleEffect(scale)
        .offset(y: yOffset)
        .opacity(opacity)
        .zIndex(zIndex)
        .transition(.asymmetric(
            insertion: .offset(y: 18).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private var scale: CGFloat {
        max(0.82, 1 - CGFloat(depth) * 0.10)
    }

    private var yOffset: CGFloat {
        CGFloat(depth) * 10
    }

    private var opacity: Double {
        depth == 0 ? 1 : max(0.5, 0.72 - Double(depth - 1) * 0.12)
    }

    private var zIndex: Double {
        Double(10 - depth)
    }
}
