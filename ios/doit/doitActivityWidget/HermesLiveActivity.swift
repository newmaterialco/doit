import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen + Dynamic Island layout for the Hermes agent run.
///
/// Visual structure is adapted from the open-source `chowder-iOS`
/// (`newmaterialco/chowder-iOS`) repo's `ChowderLiveActivity`, which
/// stacks recent intents behind the current one with a live timer at
/// the trailing edge. We rename the attributes to `HermesActivityAttributes`
/// and adapt the field set to Doit's data model (see
/// `ios/doit/Shared/HermesActivityAttributes.swift`). None of Chowder's
/// agent orchestration code is used.
struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            LockScreenLayout(context: context)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandLogo()
                        .frame(width: 28, height: 28)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandElapsedText(state: context.state)
                        .frame(maxWidth: 42, alignment: .trailing)
                        .padding(.top, 4)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.taskTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(context.state.currentIntent)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                        if let toolCall = context.state.toolCallTitle,
                           !toolCall.isEmpty,
                           toolCall != context.state.currentIntent {
                            HStack(spacing: 4) {
                                Image(systemName: context.state.currentSymbolName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(toolCall)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .opacity(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let previous = context.state.previousIntent {
                        HStack(spacing: 6) {
                            Image(systemName: previous.isCompleted ? "checkmark" : previous.symbolName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(previous.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(0.55)
                    }
                }
            } compactLeading: {
                IslandLogo()
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                IslandElapsedText(state: context.state)
            } minimal: {
                IslandLogo()
                    .frame(width: 24, height: 24)
            }
        }
    }
}

private struct IslandLogo: View {
    var body: some View {
        Image("doit_app_Small_logo")
            .resizable()
            .scaledToFill()
            .clipShape(Circle())
    }
}

private struct IslandElapsedText: View {
    let state: HermesActivityAttributes.ContentState

    var body: some View {
        if state.state == "running" {
            timerPill
        } else {
            pill(statusLabel)
        }
    }

    private var timerPill: some View {
        Text(timerInterval: state.intentStartDate ... Date.distantFuture, countsDown: false)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: 38, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .monospacedDigit()
    }

    private func pill(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: 38, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText(countsDown: false))
    }

    private var statusLabel: String {
        switch state.state {
        case "completed": return "Done"
        case "failed": return "Fail"
        case "paused": return "Wait"
        default: return "0:00"
        }
    }
}

// MARK: - Lock Screen layout

private struct LockScreenLayout: View {
    let context: ActivityViewContext<HermesActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let state = context.state
        let intents = previousIntents
        let isWaiting = intents.isEmpty && !state.isTerminal

        VStack(alignment: .leading, spacing: 4) {
            header
            intentStack(intents: intents, isWaiting: isWaiting)
            footer(isWaiting: isWaiting)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(height: 160)
        .background(Color.white.opacity(isWaiting || state.isTerminal ? 1 : 0.76))
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                agentAvatar
                    .frame(width: 21, height: 21)
                    .background(primaryForeground.opacity(0.10), in: Circle())
                    .overlay {
                        Circle().stroke(primaryForeground.opacity(0.12))
                    }

                Text(context.attributes.taskTitle)
                    .id(context.attributes.taskTitle)
                .font(.callout.bold())
                .opacity(0.72)
                .lineLimit(1)
                .transition(.blurReplace)
            }

            Spacer(minLength: 8)

            if let cost = context.state.costTotal {
                costBadge(cost)
            } else {
                HStack(spacing: 5) {
                    StatusDot(state: context.state.state, size: 5)
                    Text(context.attributes.agentName)
                        .opacity(0.48)
                }
                .transition(.blurReplace)
            }
        }
        .font(.subheadline.bold())
        .frame(height: 28)
        .padding(.horizontal, 6)
        .foregroundStyle(primaryForeground)
    }

    @ViewBuilder
    private func intentStack(
        intents: [HermesActivityAttributes.WidgetIntent],
        isWaiting: Bool
    ) -> some View {
        ZStack {
            if context.state.isTerminal, let endDate = context.state.intentEndDate {
                finishedCard(endDate: endDate)
            } else if context.state.state == "paused" {
                pausedCard
            } else {
                ZStack {
                    if intents.isEmpty {
                        Text(context.attributes.userTask)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.blue)
                            .padding(12)
                            .frame(minWidth: 52)
                            .background(
                                Color.blue.opacity(userTaskOpacity),
                                in: .rect(cornerRadius: 16, style: .continuous)
                            )
                            .padding(.leading, 48)
                            .padding(.trailing, 8)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.blurReplace)
                    }

                    ForEach(intents) { intent in
                        let isBehind = intent.id != context.state.previousIntent?.id
                        IntentCard(intent: intent, isBehind: isBehind)
                    }
                }
                .compositingGroup()
                .transition(.blurReplace)
            }
        }
        .frame(height: 80)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity)
        .zIndex(10)
        .animation(.smooth(duration: 0.28), value: context.state.currentIntent)
        .animation(.smooth(duration: 0.28), value: previousIntents.map(\.id))
    }

    private var pausedCard: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: context.state.currentSymbolName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.orange, in: Circle())
                .compositingGroup()
            VStack(spacing: 2) {
                Text(context.state.currentIntent)
                    .font(.subheadline.bold())
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                Text(context.state.subject ?? "Open the app to respond")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private func footer(isWaiting: Bool) -> some View {
        HStack(spacing: 6) {
            if context.state.isTerminal {
                Text("^[\(context.state.stepNumber) step](inflect: true)")
                    .transition(.blurReplace)
                    .padding(.leading, 8)
            } else {
                HStack(spacing: 2) {
                    Text(Image(systemName: context.state.currentSymbolName))
                        .frame(width: 24, height: 18)
                    Text(isWaiting ? "Thinking..." : footerLabel)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .id(footerLabel)
                .transition(.blurReplace)
            }

            Spacer(minLength: 0)

            timerText(isWaiting: isWaiting)
        }
        .foregroundStyle(primaryForeground)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .font(.footnote.bold())
        .opacity(isWaiting || context.state.isTerminal ? 0.36 : 1)
    }

    /// The small footer label shows the compact tool-call title (e.g.
    /// "Searching Gmail") so the user can see *which* tool the agent is
    /// running while the larger card above shows the human-facing
    /// detail. Falls back to `currentIntent` when no tool call label
    /// was emitted (older snapshots, thinking phase).
    private var footerLabel: String {
        if let toolCall = context.state.toolCallTitle,
           !toolCall.isEmpty {
            return toolCall
        }
        return context.state.currentIntent
    }

    @ViewBuilder
    private func finishedCard(endDate: Date) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: context.state.state == "failed" ? "xmark" : "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(context.state.state == "failed" ? Color.red : Color.green, in: Circle())
                .compositingGroup()
            VStack(spacing: 2) {
                Text(context.state.subject ?? context.attributes.taskTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                Text(context.state.state == "failed" ? "Something went wrong" : "See more details...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private func timerText(isWaiting: Bool) -> some View {
        Group {
            if context.state.isTerminal, let endDate = context.state.intentEndDate {
                let interval = Duration.seconds(endDate.timeIntervalSince(context.state.intentStartDate))
                Text("Finished in \(interval.formatted(.time(pattern: .minuteSecond)))")
            } else if !isWaiting && context.state.state == "running" {
                Text("00:00")
                    .opacity(0)
                    .overlay(alignment: .trailing) {
                        Text(context.state.intentStartDate, style: .timer)
                            .contentTransition(.numericText(countsDown: false))
                            .opacity(0.5)
                    }
            } else if context.state.state == "paused" {
                Text("Paused")
                    .opacity(0.5)
            }
        }
        .font(.footnote.bold())
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .layoutPriority(1)
    }

    private func costBadge(_ cost: String) -> some View {
        let alert = !cost.contains("$0")
        return Text(cost)
            .font(.subheadline)
            .fontWeight(.regular)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .overlay {
                Capsule().stroke(primaryForeground.opacity(alert ? 0.06 : 0.12))
            }
            .background(primaryForeground.opacity(alert ? 0.12 : 0), in: .capsule)
            .monospacedDigit()
    }

    private var agentAvatar: some View {
        Image("doit_app_Small_logo")
            .resizable()
            .scaledToFill()
            .clipShape(Circle())
    }

    private var previousIntents: [HermesActivityAttributes.WidgetIntent] {
        [context.state.secondPreviousIntent, context.state.previousIntent]
            .compactMap { $0 }
            .filter { !$0.title.isEmpty }
    }

    private var primaryForeground: Color {
        Color(red: 47 / 255, green: 59 / 255, blue: 84 / 255)
    }

    private var userTaskOpacity: CGFloat {
        colorScheme == .dark ? 0.24 : 0.12
    }
}

private struct IntentCard: View {
    let intent: HermesActivityAttributes.WidgetIntent
    let isBehind: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: intent.isCompleted ? "checkmark" : intent.symbolName)
                .font(.system(size: 12, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.black.opacity(0.5))
                .frame(width: 21, height: 21)
                .background(Circle().foregroundStyle(.black.opacity(0.12)))
            Text(intent.title)
                .font(.callout)
                .foregroundStyle(.black)
                .frame(height: 60)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 60)
        .background(Color.white, in: .rect(cornerRadius: isBehind ? 10 : 16, style: .continuous))
        .scaleEffect(isBehind ? 0.9 : 1)
        .offset(y: isBehind ? 10 : 0)
        .opacity(isBehind ? 0.72 : 1)
        .zIndex(isBehind ? 0 : 1)
        .transition(.asymmetric(insertion: .offset(y: 120), removal: .opacity))
    }
}

// MARK: - Shared chrome

private struct StatusDot: View {
    let state: String
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: 2)
                    .scaleEffect(isRunning ? 1.8 : 1.0)
                    .opacity(isRunning ? 0 : 0.6)
                    .animation(
                        isRunning
                            ? .easeOut(duration: 1.1).repeatForever(autoreverses: false)
                            : .default,
                        value: isRunning
                    )
            )
    }

    private var color: Color {
        switch state {
        case "completed": return .green
        case "failed": return .red
        case "paused": return .orange
        default: return .blue
        }
    }

    private var isRunning: Bool { state == "running" }
}

private struct StateBadge: View {
    let state: HermesActivityAttributes.ContentState
    let started: Date

    var body: some View {
        switch state.state {
        case "completed":
            badge(text: "Done", icon: "checkmark.seal.fill", color: .green)
        case "failed":
            badge(text: "Failed", icon: "exclamationmark.triangle.fill", color: .red)
        case "paused":
            badge(text: "Paused", icon: "pause.fill", color: .orange)
        default:
            Text(timerInterval: started ... Date.distantFuture, countsDown: false)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: 64)
        }
    }

    private func badge(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.18), in: Capsule())
    }
}
