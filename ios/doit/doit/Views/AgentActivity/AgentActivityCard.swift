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
        .animation(.smooth(duration: 0.28), value: activity.title)
        .animation(.smooth(duration: 0.28), value: isTaskActive)
        .animation(.smooth(duration: 0.28), value: activity.recentSteps.map(\.id))
    }

    private var stackItems: [AgentIntentCardModel] {
        var items = activity.recentSteps.map(AgentIntentCardModel.init(step:))
        let current = currentCard

        if items.last?.title != current.title {
            items.append(current)
        } else if !items.isEmpty {
            items[items.count - 1] = current
        } else {
            items = [current]
        }
        return Array(items.suffix(Self.maxVisibleCards))
    }

    private var currentCard: AgentIntentCardModel {
        if isTaskActive, activity.isTerminal {
            return AgentIntentCardModel(
                id: "rerun-\(activity.todo_id.uuidString)-\(activity.updated_at.timeIntervalSince1970)",
                title: "Starting agent…",
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
        id = "current-\(activity.todo_id.uuidString)-\(activity.updated_at.timeIntervalSince1970)"
        title = activity.title
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
        title = step.title
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
                .foregroundStyle(Color.black.opacity(0.5))
                .frame(width: 21, height: 21)
                .background(Circle().foregroundStyle(Color.black.opacity(0.12)))

            Text(item.title)
                .font(.callout)
                .foregroundStyle(Color.black)
                .frame(height: 60)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 60)
        .background(
            Color.white,
            in: .rect(cornerRadius: depth == 0 ? 16 : 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: depth == 0 ? 16 : 10, style: .continuous)
                .strokeBorder(Color.black.opacity(depth == 0 ? 0.05 : 0.03), lineWidth: 1)
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
