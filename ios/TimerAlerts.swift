import Foundation
import UserNotifications
import OrderCore

/// Milestones the user can switch on or off. Each one becomes a local
/// notification, so it also rings with the phone locked or the app in the background.
enum TimerMilestone: String, CaseIterable, Identifiable {
    case half, left10, left5, left2, left1, end
    var id: String { rawValue }

    var label: String {
        switch self {
        case .half: return "Hälfte der Zeit geschafft"
        case .left10: return "Noch 10 Minuten"
        case .left5: return "Noch 5 Minuten"
        case .left2: return "Noch 2 Minuten"
        case .left1: return "Noch 1 Minute (fast vorbei)"
        case .end: return "Zeit ist um"
        }
    }

    var defaultOn: Bool { self != .left2 && self != .left1 }
    var defaultsKey: String { "timerAlert." + rawValue }

    /// Seconds of the budget that must still be left when the hint fires.
    func secondsLeft(total: Double) -> Double {
        switch self {
        case .half: return total / 2
        case .left10: return 600
        case .left5: return 300
        case .left2: return 120
        case .left1: return 60
        case .end: return 0
        }
    }

    var message: String {
        switch self {
        case .half: return "Die Hälfte der Zeit ist geschafft. Du bist gut dabei!"
        case .left10: return "Noch 10 Minuten."
        case .left5: return "Noch 5 Minuten. Bring zu Ende, was du angefangen hast."
        case .left2: return "Noch 2 Minuten – langsam abschließen."
        case .left1: return "Noch 1 Minute. Fast geschafft!"
        case .end: return "Die Zeit ist um. Öffne die App: Runde beenden oder 5 Minuten verlängern."
        }
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultOn
    }
}

@MainActor
final class TimerAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TimerAlerts()
    static let soundKey = "timerAlertSound"
    nonisolated private static let prefix = "ordnungsplaner-timer-"

    private var lastSession: WorkSession?
    private var lastSignature = ""

    static var soundEnabled: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }

    /// Show banner and play the sound even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Re-plan the notifications to match the session. Cheap to call often.
    func sync(_ session: WorkSession?, force: Bool = false) {
        lastSession = session
        let milestones = TimerMilestone.allCases.filter(\.enabled).map(\.rawValue).joined(separator: ",")
        let signature = [session.map { "\($0.id)|\($0.status)|\($0.timeBudget)|\($0.runningSince?.timeIntervalSince1970 ?? 0)|\($0.elapsedSeconds ?? -1)" } ?? "none",
                         milestones, "\(Self.soundEnabled)"].joined(separator: "#")
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: TimerMilestone.allCases.map { Self.prefix + $0.rawValue })
        guard let session, session.status == .active else { return }
        let total = Double(session.timeBudget * 60)
        let remaining = session.remaining()
        var plan: [(TimerMilestone, TimeInterval)] = []
        for milestone in TimerMilestone.allCases where milestone.enabled {
            let left = milestone.secondsLeft(total: total)
            // Skip hints that would fire at the very start or have already passed.
            guard milestone == .end || left < total - 30 else { continue }
            let delay = remaining - left
            guard delay > 2 else { continue }
            // Two hints within half a minute of each other: keep only the first.
            if plan.contains(where: { abs($0.1 - delay) < 30 }) { continue }
            plan.append((milestone, delay))
        }
        guard !plan.isEmpty else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for (milestone, delay) in plan {
                let content = UNMutableNotificationContent()
                content.title = "Ordnungsplaner"
                content.body = milestone.message
                if Self.soundEnabledNonisolated { content.sound = .default }
                let request = UNNotificationRequest(identifier: Self.prefix + milestone.rawValue, content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
                center.add(request)
            }
        }
    }

    /// Settings changed: plan again with the latest session.
    func refresh() { sync(lastSession, force: true) }

    func scheduleTest() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Ordnungsplaner"
            content.body = "So klingt dein Zeit-Hinweis."
            if Self.soundEnabledNonisolated { content.sound = .default }
            center.add(UNNotificationRequest(identifier: Self.prefix + "test", content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private nonisolated static var soundEnabledNonisolated: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }
}
