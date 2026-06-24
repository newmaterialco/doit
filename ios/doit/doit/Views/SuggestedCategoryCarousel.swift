import SwiftUI

struct SuggestedCategory: Identifiable, Hashable {
    let id: String
    let title: String
    var imageName: String?
    var symbolName: String?
}

struct ScheduledPromptSuggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let cadence: String
    let cron: String
    let prompt: String

    var symbolName: String {
        switch id {
        case "inbox-morning-triage":
            return "tray.and.arrow.down.fill"
        case "inbox-draft-replies":
            return "pencil.and.outline"
        case "inbox-follow-up-hunter":
            return "arrowshape.turn.up.left.fill"
        case "inbox-unsubscribe-sweep":
            return "minus.circle.fill"
        case "inbox-vip-watch":
            return "star.fill"
        case "digests-niche-pulse":
            return "waveform.path.ecg"
        case "digests-competitor-radar":
            return "scope"
        case "digests-industry-brief":
            return "newspaper.fill"
        case "digests-topic-deep-dive":
            return "doc.text.magnifyingglass"
        case "digests-reading-roundup":
            return "bookmark.fill"
        case "pm-standup-prep":
            return "list.bullet.clipboard.fill"
        case "pm-reconciler":
            return "checklist.unchecked"
        case "pm-accountability":
            return "person.2.badge.gearshape.fill"
        case "pm-sprint-health":
            return "chart.line.uptrend.xyaxis"
        case "pm-stale-tickets":
            return "clock.badge.exclamationmark.fill"
        case "coding-dependency-watch":
            return "shippingbox.fill"
        case "coding-pr-review":
            return "arrow.triangle.pull"
        case "coding-tech-debt":
            return "wrench.and.screwdriver.fill"
        case "coding-ci-triage":
            return "exclamationmark.triangle.fill"
        case "coding-issue-groomer":
            return "tag.fill"
        case "cos-day-architect":
            return "calendar.day.timeline.left"
        case "cos-week-ahead":
            return "calendar"
        case "cos-meeting-prep":
            return "person.2.wave.2.fill"
        case "cos-buffer-guardian":
            return "rectangle.inset.filled.and.person.filled"
        case "cos-commitment-tracker":
            return "checkmark.seal.fill"
        case "finance-spend-pulse":
            return "creditcard.fill"
        case "finance-subscription-audit":
            return "repeat.circle.fill"
        case "finance-burn-runway":
            return "chart.bar.fill"
        case "finance-bill-watch":
            return "calendar.badge.exclamationmark"
        case "finance-anomaly-flag":
            return "flag.fill"
        case "ops-errand-stacker":
            return "map.fill"
        case "ops-habit-pulse":
            return "figure.walk"
        case "ops-home-planner":
            return "house.fill"
        case "ops-meal-prep":
            return "fork.knife"
        case "ops-renewal-radar":
            return "bell.badge.fill"
        case "growth-content-queue":
            return "square.and.pencil"
        case "growth-engagement-digest":
            return "bubble.left.and.bubble.right.fill"
        case "growth-audience-listening":
            return "ear.fill"
        case "growth-lead-sweep":
            return "person.crop.circle.badge.plus"
        case "growth-idea-bank":
            return "lightbulb.fill"
        default:
            return "sparkles"
        }
    }

    var composerPrompt: String {
        "\(recurrencePhrase), run this recurring task:\n\n\(prompt)"
    }

    private var recurrencePhrase: String {
        let fallback = fallbackRecurrencePhrase
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5,
              let minute = Int(parts[0]),
              let hour = Int(parts[1])
        else { return fallback }

        let time = formattedTime(hour: hour, minute: minute)
        switch cadence {
        case "daily":
            return "Every day at \(time)"
        case "weekdays":
            return "Every weekday at \(time)"
        case "weekly":
            return "Every week on \(weekdayName(from: parts[4]) ?? "the scheduled day") at \(time)"
        case "monthly":
            return "Every month on day \(parts[2]) at \(time)"
        default:
            return fallback
        }
    }

    private var fallbackRecurrencePhrase: String {
        switch cadence {
        case "daily":
            return "Every day"
        case "weekdays":
            return "Every weekday"
        case "weekly":
            return "Every week"
        case "monthly":
            return "Every month"
        default:
            return "On a recurring schedule"
        }
    }

    private func formattedTime(hour: Int, minute: Int) -> String {
        let isPM = hour >= 12
        let displayHour = {
            let hour = hour % 12
            return hour == 0 ? 12 : hour
        }()
        let suffix = isPM ? "PM" : "AM"
        if minute == 0 {
            return "\(displayHour):00 \(suffix)"
        }
        return "\(displayHour):\(String(format: "%02d", minute)) \(suffix)"
    }

    private func weekdayName(from cronWeekday: String) -> String? {
        switch cronWeekday {
        case "0", "7":
            return "Sunday"
        case "1":
            return "Monday"
        case "2":
            return "Tuesday"
        case "3":
            return "Wednesday"
        case "4":
            return "Thursday"
        case "5":
            return "Friday"
        case "6":
            return "Saturday"
        default:
            return nil
        }
    }
}

struct ScheduledPromptCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let symbolName: String
    let prompts: [ScheduledPromptSuggestion]
}

extension SuggestedCategory {
    var topicIntroDescription: String {
        switch id {
        case "travel-bookings":
            return "Tasks here will send your agent to search flights, stays, and transport across the web — using saved preferences and connected accounts — and finish bookings only after you approve."
        case "coding-development":
            return "Tasks here will have your agent work in connected GitHub repos: triage issues, update PRs, investigate CI failures, and carry context forward from earlier dev work."
        case "admin":
            return "Tasks here will run life admin through connected email, calendar, and docs — plus browser workflows for portals and forms — pausing for your approval before anything irreversible."
        case "research":
            return "Tasks here will have your agent search the web, compare sources, and return clear summaries and next steps — remembering findings so follow-up tasks start with context."
        case "lead-generation":
            return "Tasks here will have your agent scout prospects, draft outreach in your voice, and stage LinkedIn or email follow-ups — nothing sends until you approve it."
        case "content-creation":
            return "Tasks here will have your agent draft and refine posts or copy for your channels, matched to your voice, with an approval step before anything goes live."
        case "home-automation":
            return "Tasks here will have your agent compare devices and routines, check smart-home dashboards in the browser, and reuse saved setup notes across follow-up tasks."
        default:
            return "Suggested tasks and workflows for this topic will appear here soon — each one your agent can pick up and run in the background."
        }
    }
}

enum SuggestedCategoryCatalog {
    static let taskCategories: [SuggestedCategory] = [
        SuggestedCategory(id: "travel-bookings", title: "Travel & Bookings", imageName: "TravelBookings"),
        SuggestedCategory(id: "coding-development", title: "Coding & Development", imageName: "CodingDevelopment"),
        SuggestedCategory(id: "admin", title: "Admin", imageName: "Admin"),
        SuggestedCategory(id: "research", title: "Research", imageName: "Research"),
        SuggestedCategory(id: "lead-generation", title: "Lead Generation", imageName: "LeadGeneration"),
        SuggestedCategory(id: "content-creation", title: "Content Creation", imageName: "ContentCreation"),
        SuggestedCategory(id: "home-automation", title: "Home Automation", imageName: "HomeAutomation"),
    ]

    static let scheduledCategories: [SuggestedCategory] = scheduledPromptCategories.map {
        SuggestedCategory(id: $0.id, title: $0.name, symbolName: $0.symbolName)
    }

    static let scheduledPromptCategories: [ScheduledPromptCategory] = [
        ScheduledPromptCategory(
            id: "inbox",
            name: "Inbox",
            symbolName: "tray.full.fill",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "inbox-morning-triage",
                    title: "Inbox Triage",
                    description: "Daily priority sort of overnight mail",
                    cadence: "daily",
                    cron: "0 7 * * *",
                    prompt: "Scan my inbox for everything received since 6pm yesterday. Sort messages into Urgent (needs a reply today), FYI (no action needed), and Newsletters/Promos. For each Urgent item, give a one-line summary and the sender. Don't draft replies yet — just deliver the sorted list."
                ),
                ScheduledPromptSuggestion(
                    id: "inbox-draft-replies",
                    title: "Draft Replies",
                    description: "Pre-writes responses to routine mail",
                    cadence: "daily",
                    cron: "30 7 * * *",
                    prompt: "Find emails from the last 24 hours that clearly need a reply and are routine (scheduling, confirmations, simple questions). Draft a reply for each in my voice, save them as drafts, and give me a list of what you drafted with a one-line note on each. Do not send anything."
                ),
                ScheduledPromptSuggestion(
                    id: "inbox-follow-up-hunter",
                    title: "Follow-Ups",
                    description: "Surfaces threads you're waiting on",
                    cadence: "weekly",
                    cron: "0 8 * * 1",
                    prompt: "Look through my sent mail from the last 7 days and find messages where I asked a question or requested something and haven't gotten a reply. List each one with who I'm waiting on, what I asked, and how many days it's been. Flag anything older than 4 days as overdue."
                ),
                ScheduledPromptSuggestion(
                    id: "inbox-unsubscribe-sweep",
                    title: "Newsletter Review",
                    description: "Weekly inbox-noise reduction",
                    cadence: "weekly",
                    cron: "0 9 * * 6",
                    prompt: "Identify the newsletters and promotional senders that have emailed me several times in the last 7 days that I never open. List them with sender, frequency, and last-opened date so I can decide what to cut. Don't unsubscribe automatically — just give me the candidates."
                ),
                ScheduledPromptSuggestion(
                    id: "inbox-vip-watch",
                    title: "Important Contacts",
                    description: "Never miss mail from key people",
                    cadence: "daily",
                    cron: "0 7 * * *",
                    prompt: "Check my inbox for any new messages from my important contacts [list the people who matter — e.g. key clients, your boss, family]. If any arrived since the last check, summarize each in two sentences and surface them at the top. If nothing came in, just say so."
                )
            ]
        ),
        ScheduledPromptCategory(
            id: "digests",
            name: "Digests & Intelligence",
            symbolName: "newspaper.fill",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "digests-niche-pulse",
                    title: "Niche Brief",
                    description: "Daily aggregation of community signal",
                    cadence: "daily",
                    cron: "0 7 * * *",
                    prompt: "Using the Last 30 Days skill, scan X, Reddit, and YouTube for discussion in [your niche — e.g. real estate investing]. Surface the top recurring pain points, hot debates, and any competitor mentions. Group by theme, cite the top 2-3 source posts per theme, and keep it to a one-screen morning brief."
                ),
                ScheduledPromptSuggestion(
                    id: "digests-competitor-radar",
                    title: "Competitor Updates",
                    description: "Weekly tracking of named rivals",
                    cadence: "weekly",
                    cron: "0 8 * * 1",
                    prompt: "Check for any new public activity this week from my competitors [name the companies you watch]. Look at their sites, changelogs, social posts, and any press. Summarize launches, pricing changes, and notable hires. Flag anything that looks like a direct response to our positioning."
                ),
                ScheduledPromptSuggestion(
                    id: "digests-industry-brief",
                    title: "Industry News",
                    description: "Curated news on your domain",
                    cadence: "weekly",
                    cron: "0 8 * * 1",
                    prompt: "Find the 5-7 most significant developments in [your industry] from the past week. For each, give a headline, a two-sentence summary, and why it matters to me specifically given that I work on [a sentence about what you do]. Lead with anything time-sensitive."
                ),
                ScheduledPromptSuggestion(
                    id: "digests-topic-deep-dive",
                    title: "Topic Research",
                    description: "Scheduled research on a rotating subject",
                    cadence: "weekly",
                    cron: "0 6 * * 3",
                    prompt: "Research this topic for me: [the subject you want investigated]. Go across a good range of quality sources, then write a one-page brief covering the current state, key players, open questions, and 3 things I should know. Save it somewhere I can find it [your notes app / a doc]."
                ),
                ScheduledPromptSuggestion(
                    id: "digests-reading-roundup",
                    title: "Saved Reading",
                    description: "Weekly catch-up on saved content",
                    cadence: "weekly",
                    cron: "0 9 * * 0",
                    prompt: "Pull everything I saved or bookmarked this week from [where you save things — e.g. read-later app, browser bookmarks]. Cluster by theme, summarize each item in two sentences, and rank them by how relevant they are to what I'm working on right now so I read the best ones first."
                )
            ]
        ),
        ScheduledPromptCategory(
            id: "project-management",
            name: "Project Management",
            symbolName: "checklist.checked",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "pm-standup-prep",
                    title: "Standup Agenda",
                    description: "Sets tomorrow's agenda from today's activity",
                    cadence: "weekdays",
                    cron: "0 17 * * 1-5",
                    prompt: "Pull today's ticket activity from [your issue tracker — e.g. Linear, Jira] and today's messages from our team chat [e.g. Slack]. Build tomorrow's standup agenda: what moved, what's blocked, and what's at risk of slipping. Post the draft agenda to [the channel where it should go]."
                ),
                ScheduledPromptSuggestion(
                    id: "pm-reconciler",
                    title: "Tracker Gaps",
                    description: "Catches verbal commitments that never got logged",
                    cadence: "weekdays",
                    cron: "0 17 * * 1-5",
                    prompt: "Compare today's team chat discussion against [your issue tracker]. Flag anything that was agreed to, assigned, or de-scoped in chat but isn't reflected in a ticket. List each gap with a link to the message and who owns it."
                ),
                ScheduledPromptSuggestion(
                    id: "pm-accountability",
                    title: "Weekly Commitments",
                    description: "Holds the team to what they committed",
                    cadence: "weekly",
                    cron: "0 16 * * 5",
                    prompt: "Review what each person said they'd do in this week's standups against what actually changed in [your issue tracker]. List anyone whose committed tickets show no progress, with the ticket and days elapsed. Keep the tone factual, not accusatory, and post it to [the channel]."
                ),
                ScheduledPromptSuggestion(
                    id: "pm-sprint-health",
                    title: "Sprint Status",
                    description: "Weekly delivery-risk readout",
                    cadence: "weekly",
                    cron: "0 9 * * 3",
                    prompt: "Look at the current sprint in [your issue tracker]. Work out what share of committed work is done, in progress, and untouched with [however many] days left. Flag tickets with no movement in several days and anything blocked. Give me a one-paragraph 'will we make it?' assessment."
                ),
                ScheduledPromptSuggestion(
                    id: "pm-stale-tickets",
                    title: "Stale Tickets",
                    description: "Finds work that's quietly rotting",
                    cadence: "weekly",
                    cron: "0 9 * * 1",
                    prompt: "Find every open ticket in [your issue tracker] that's assigned but has had no update in two weeks or more. For each, note the owner, last activity, and status. Group by assignee so I can nudge people, and call out anything high-priority that's gone stale."
                )
            ]
        ),
        ScheduledPromptCategory(
            id: "coding",
            name: "Coding & Repo Maintenance",
            symbolName: "chevron.left.forwardslash.chevron.right",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "coding-dependency-watch",
                    title: "Dependency Updates",
                    description: "Weekly upgrade scout",
                    cadence: "weekly",
                    cron: "0 6 * * 1",
                    prompt: "Check the dependencies in [your repo] for new releases and security advisories. List outdated packages with current vs. latest version, flag any with known vulnerabilities as urgent, and note which upgrades are major (breaking) vs. minor. Don't change anything — just give me the upgrade plan."
                ),
                ScheduledPromptSuggestion(
                    id: "coding-pr-review",
                    title: "PR Review",
                    description: "First-pass reviewer on open PRs",
                    cadence: "daily",
                    cron: "0 6 * * *",
                    prompt: "Review every open pull request in [your repo] that's awaiting review. For each, write a summary of what it changes and flag risky patterns, missing tests, or style issues. Leave first-pass comments, but make clear a human still needs to approve and merge."
                ),
                ScheduledPromptSuggestion(
                    id: "coding-tech-debt",
                    title: "Tech Debt Review",
                    description: "Surfaces low-risk cleanup candidates",
                    cadence: "weekly",
                    cron: "0 3 * * 0",
                    prompt: "Scan [your repo] for dead code, unused exports, commented-out blocks, and obvious duplication. Produce a prioritized list of safe, low-risk cleanups with file locations and a rough effort estimate for each. Don't open PRs — just give me the backlog."
                ),
                ScheduledPromptSuggestion(
                    id: "coding-ci-triage",
                    title: "CI Failures",
                    description: "Diagnoses what broke overnight",
                    cadence: "daily",
                    cron: "0 6 * * *",
                    prompt: "Check the CI runs from the last 24 hours in [your repo]. For each failure, identify the failing test or step, correlate it with recent merges or changed files, and propose a likely cause. Separate genuine regressions from flaky tests."
                ),
                ScheduledPromptSuggestion(
                    id: "coding-issue-groomer",
                    title: "Issue Review",
                    description: "Keeps the issue tracker sane",
                    cadence: "weekly",
                    cron: "0 7 * * 2",
                    prompt: "Review open issues in [your repo]. Flag duplicates, issues missing repro steps, and anything stale (no activity in a month or more). Suggest labels and a priority for untriaged issues. Output a cleanup list — don't close or edit anything yourself."
                )
            ]
        ),
        ScheduledPromptCategory(
            id: "chief-of-staff",
            name: "Calendar & Chief of Staff",
            symbolName: "calendar.badge.clock",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "cos-day-architect",
                    title: "Daily Plan",
                    description: "Squares calendar against to-dos and weather",
                    cadence: "daily",
                    cron: "0 6 * * *",
                    prompt: "Read my calendar [across all my accounts if I have more than one], find the open slots, and match them against my to-do list by priority. Add today's weather. If rain is forecast, move outdoor or physical tasks to clear windows and protect rainy or away time for deep work like writing, coding, and design. Deliver the proposed day plan."
                ),
                ScheduledPromptSuggestion(
                    id: "cos-week-ahead",
                    title: "Weekly Calendar",
                    description: "Sunday-night look at the coming week",
                    cadence: "weekly",
                    cron: "0 18 * * 0",
                    prompt: "Review my calendar for the next 7 days across all accounts. Flag double-bookings, back-to-back stretches with no breaks, and any days that look overloaded. Note what I need to prep for each major meeting, and suggest where to add focus blocks."
                ),
                ScheduledPromptSuggestion(
                    id: "cos-meeting-prep",
                    title: "Meeting Prep",
                    description: "Briefs you before each meeting",
                    cadence: "daily",
                    cron: "0 18 * * *",
                    prompt: "For each meeting on my calendar tomorrow, put together a short prep card: who's attending, our last interaction with them, any relevant docs or email threads, and a suggested objective for the meeting."
                ),
                ScheduledPromptSuggestion(
                    id: "cos-buffer-guardian",
                    title: "Calendar Buffers",
                    description: "Protects against an overpacked schedule",
                    cadence: "daily",
                    cron: "0 18 * * *",
                    prompt: "Scan tomorrow's calendar. If I have a lot of meeting hours or any long stretch with no break, flag it and propose specific 15-30 minute buffers to add. Don't modify the calendar — just recommend."
                ),
                ScheduledPromptSuggestion(
                    id: "cos-commitment-tracker",
                    title: "Meeting Commitments",
                    description: "Catches promises made in meetings",
                    cadence: "daily",
                    cron: "0 19 * * *",
                    prompt: "Review my calendar and any notes from meetings in the last few days. Pull out any action items or commitments I made, check whether they're on my to-do list, and flag the ones that aren't captured anywhere."
                )
            ]
        ),
        ScheduledPromptCategory(
            id: "finance",
            name: "Personal Finance",
            symbolName: "creditcard.fill",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "finance-spend-pulse",
                    title: "Weekly Spending",
                    description: "Weekly money check-in",
                    cadence: "weekly",
                    cron: "0 9 * * 0",
                    prompt: "Pull my transactions from the last 7 days [across the accounts you want me to watch]. Total spend by category, compare to my weekly average, and call out the 3 largest outflows. Flag anything unusual or that looks like a duplicate charge. Keep it short."
                ),
                ScheduledPromptSuggestion(
                    id: "finance-subscription-audit",
                    title: "Subscription Audit",
                    description: "Monthly recurring-charge sweep",
                    cadence: "monthly",
                    cron: "0 9 1 * *",
                    prompt: "Scan my statements for recurring subscriptions and memberships. List each with amount, billing cadence, and a last-used signal if you can find one. Flag anything I appear to be paying for twice or haven't used recently. Don't cancel anything — just give me the review list."
                ),
                ScheduledPromptSuggestion(
                    id: "finance-burn-runway",
                    title: "Cash Flow and Runway",
                    description: "Founder cash-flow snapshot",
                    cadence: "monthly",
                    cron: "0 9 1 * *",
                    prompt: "Using my business accounts [name them], calculate this month's net cash movement, the largest outflows by category, and how it compares to last month. Give me current runway at this burn rate and a one-paragraph narrative on what changed."
                ),
                ScheduledPromptSuggestion(
                    id: "finance-bill-watch",
                    title: "Upcoming Bills",
                    description: "Heads-up on upcoming payments",
                    cadence: "weekly",
                    cron: "0 8 * * 1",
                    prompt: "Look at my recurring bills and known due dates. List what's due in the next 10 days with amount and date. Flag anything where the amount jumped versus the prior period so I can check it before it hits."
                ),
                ScheduledPromptSuggestion(
                    id: "finance-anomaly-flag",
                    title: "Transaction Review",
                    description: "Daily fraud / error catch",
                    cadence: "daily",
                    cron: "0 8 * * *",
                    prompt: "Review yesterday's transactions [across my accounts]. Flag anything that looks off: charges far above my normal range, unfamiliar merchants, or duplicate amounts. List each with the detail I'd need to decide if it's legit. Don't take any action — just alert me."
                )
            ]
        ),
        ScheduledPromptCategory(
            id: "personal-ops",
            name: "Health & Personal Ops",
            symbolName: "heart.fill",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "ops-errand-stacker",
                    title: "Errand Planning",
                    description: "Batches life-admin by efficiency",
                    cadence: "weekly",
                    cron: "0 9 * * 6",
                    prompt: "Review my open personal to-dos and errands. Group them by location and type so I can knock out clusters in one trip. Cross-check against my calendar to suggest the best open window this week for each batch."
                ),
                ScheduledPromptSuggestion(
                    id: "ops-habit-pulse",
                    title: "Habit Review",
                    description: "Weekly check on personal goals",
                    cadence: "weekly",
                    cron: "0 18 * * 0",
                    prompt: "Based on my tracked habits or goals [wherever I keep them], summarize how I did this past week against my targets. Note streaks, misses, and any trend over the last few weeks. Keep it encouraging and factual, and suggest one small adjustment."
                ),
                ScheduledPromptSuggestion(
                    id: "ops-home-planner",
                    title: "Home Chores",
                    description: "Slots chores around weather and travel",
                    cadence: "weekly",
                    cron: "0 7 * * 1",
                    prompt: "Check this week's forecast and my calendar. Schedule weather-dependent chores like mowing, trimming, and outdoor maintenance into weekday afternoons when it's dry and I'm home. If I'm away or rain is forecast on the weekend, reallocate that time to indoor or deep-work tasks. Deliver the chore plan."
                ),
                ScheduledPromptSuggestion(
                    id: "ops-meal-prep",
                    title: "Meal Planning",
                    description: "Weekly food logistics",
                    cadence: "weekly",
                    cron: "0 10 * * 0",
                    prompt: "Based on my food preferences [a line about what I like / avoid] and what's on my calendar (busy nights vs. free), suggest a simple meal plan for the week and build a grocery list grouped by store section. Note which nights should be quick or leftover meals."
                ),
                ScheduledPromptSuggestion(
                    id: "ops-renewal-radar",
                    title: "Renewals",
                    description: "Never miss a deadline",
                    cadence: "weekly",
                    cron: "0 9 * * 1",
                    prompt: "Scan for any personal renewals or expirations coming up in the next 30 days — documents, licenses, memberships, warranties, insurance [anything you want me to track]. List each with the date and what action it needs. Flag anything inside 7 days as urgent."
                )
            ]
        ),
        ScheduledPromptCategory(
            id: "growth-content",
            name: "Growth & Content",
            symbolName: "megaphone.fill",
            prompts: [
                ScheduledPromptSuggestion(
                    id: "growth-content-queue",
                    title: "Content Drafts",
                    description: "Drafts posts from approved material",
                    cadence: "daily",
                    cron: "0 8 * * 1-5",
                    prompt: "Take the next item from my approved content or ideas list [wherever I keep it]. Draft a few social posts in my voice and style [a line on your tone], staying within my usual topics. Save them as drafts and show me each one. Don't publish — I'll review and post."
                ),
                ScheduledPromptSuggestion(
                    id: "growth-engagement-digest",
                    title: "Engagement Review",
                    description: "Daily readout of what landed",
                    cadence: "daily",
                    cron: "0 9 * * *",
                    prompt: "Review how my posts from the last day or two performed [on the platforms I use]. Show top and bottom performers by engagement, note what the winners had in common, and surface any comments or DMs that need a personal reply."
                ),
                ScheduledPromptSuggestion(
                    id: "growth-audience-listening",
                    title: "Audience Questions",
                    description: "Finds questions you should answer",
                    cadence: "daily",
                    cron: "0 10 * * *",
                    prompt: "Search [the platforms I use] for people asking questions in my area [your topic] that I'm well-positioned to answer. List the best 5-10 opportunities with a link, the question, and a one-line angle for how I'd respond. Don't reply automatically."
                ),
                ScheduledPromptSuggestion(
                    id: "growth-lead-sweep",
                    title: "Inbound Leads",
                    description: "Surfaces inbound interest",
                    cadence: "weekly",
                    cron: "0 9 * * 1",
                    prompt: "Scan my mentions, DMs, and inbound email from the last week for anything that looks like a potential customer, partner, or collaborator. List each with who they are, what they signaled, and a suggested next step. Flag the warmest ones."
                ),
                ScheduledPromptSuggestion(
                    id: "growth-idea-bank",
                    title: "Content Ideas",
                    description: "Keeps a steady supply of content angles",
                    cadence: "weekly",
                    cron: "0 8 * * 1",
                    prompt: "Based on this week's trending discussion in [your topic] and the questions my audience is asking, generate 10 fresh content ideas, each with a hook and the format that'd suit it. Add them to my idea list [wherever I keep it] without repeating ideas already there."
                )
            ]
        )
    ]
}

struct SuggestedCategoryStrip: View {
    let categories: [SuggestedCategory]
    var onSelect: ((SuggestedCategory) -> Void)? = nil

    private let spacing: CGFloat = 8

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(categories) { category in
                    categoryContent(category)
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func categoryContent(_ category: SuggestedCategory) -> some View {
        if let onSelect {
            Button {
                onSelect(category)
            } label: {
                SuggestedCategoryTile(category: category)
            }
            .buttonStyle(SuggestedCategoryPillButtonStyle())
        } else {
            SuggestedCategoryTile(category: category)
        }
    }
}

struct TaskTopicIntroCard: View {
    let category: SuggestedCategory

    private let imageSize: CGFloat = 58
    private var imageCornerRadius: CGFloat { imageSize * 0.28 }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            categoryVisual
                .frame(width: imageSize, height: imageSize)
                .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                        .stroke(AppSemanticColors.separator, lineWidth: 1)
                }

            Text(category.topicIntroDescription)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.title). \(category.topicIntroDescription)")
    }

    @ViewBuilder
    private var categoryVisual: some View {
        if let imageName = category.imageName {
            Image(imageName)
                .resizable()
                .scaledToFill()
        } else if let symbolName = category.symbolName {
            ZStack {
                RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                    .fill(AppSemanticColors.neutralFill)
                Image(systemName: symbolName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SuggestedCategoryPillButtonStyle: ButtonStyle {
    private static let pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Self.pressedScale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct SuggestedCategoryTile: View {
    let category: SuggestedCategory

    private let imageSize: CGFloat = 34

    var body: some View {
        HStack(spacing: 8) {
            topVisual
                .frame(width: imageSize, height: imageSize)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(AppSemanticColors.separator, lineWidth: 1)
                }

            Text(category.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .background(AppSemanticColors.elevatedSurface, in: Capsule())
        .overlay {
            Capsule()
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
        .accessibilityLabel(category.title)
    }

    @ViewBuilder
    private var topVisual: some View {
        if let imageName = category.imageName {
            Image(imageName)
                .resizable()
                .scaledToFill()
        } else if let symbolName = category.symbolName {
            ZStack {
                Circle()
                    .fill(AppSemanticColors.neutralFill)
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
