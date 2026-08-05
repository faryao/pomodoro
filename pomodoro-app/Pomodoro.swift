import SwiftUI
import AppKit
import AVFoundation
import UserNotifications

// MARK: - Palette

enum Palette {
    static let aqua = Color(red: 0.04, green: 0.73, blue: 0.71)
    static let aquaDark = Color(red: 0.03, green: 0.54, blue: 0.52)
    static let ink = Color(red: 0.03, green: 0.23, blue: 0.23)
    static let muted = Color(red: 0.36, green: 0.47, blue: 0.46)
}

// MARK: - Model

@MainActor
final class TimerModel: ObservableObject {
    static let shared = TimerModel()

    enum Mode: String, CaseIterable, Hashable {
        case focus, short, long

        var label: String {
            switch self {
            case .focus: return "Focus"
            case .short: return "Short break"
            case .long: return "Long break"
            }
        }

        var shortLabel: String {
            switch self {
            case .focus: return "Focus"
            case .short: return "Short"
            case .long: return "Long"
            }
        }

        var readyStatus: String {
            switch self {
            case .focus: return "Ready to focus"
            case .short: return "Time for a short break"
            case .long: return "Take a longer reset"
            }
        }

        var maxMinutes: Int {
            switch self {
            case .focus: return 120
            case .short: return 60
            case .long: return 90
            }
        }
    }

    @Published var minutesByMode: [Mode: Int] = [.focus: 25, .short: 5, .long: 15]
    @Published private(set) var currentMode: Mode = .focus
    @Published private(set) var remainingSeconds = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var status: String = "Ready to focus"
    /// Focus sessions completed since the last long break — long breaks land on multiples of 4.
    @Published private(set) var focusCycleCount = 0

    private var endAt: Date?
    private var timer: Timer?

    private init() {}

    var totalSeconds: Int { (minutesByMode[currentMode] ?? 1) * 60 }

    /// Fraction of the session still remaining — drives the shrinking ring arc.
    var progress: Double {
        let total = Double(totalSeconds)
        guard total > 0 else { return 0 }
        return Double(remainingSeconds) / total
    }

    var timeString: String {
        let s = max(0, remainingSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        if remainingSeconds <= 0 { remainingSeconds = totalSeconds }
        isRunning = true
        status = currentMode == .focus ? "Focus in progress" : "Break in progress"
        endAt = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        status = "Paused"
    }

    func reset() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        remainingSeconds = totalSeconds
        status = currentMode.readyStatus
    }

    func select(_ mode: Mode) {
        guard mode != currentMode || isRunning else { return }
        currentMode = mode
        reset()
    }

    func setMinutes(_ minutes: Int, for mode: Mode) {
        minutesByMode[mode] = min(max(minutes, 1), mode.maxMinutes)
        if mode == currentMode { reset() }
    }

    private func tick() {
        guard let endAt else { return }
        remainingSeconds = max(0, Int(endAt.timeIntervalSinceNow.rounded()))
        if remainingSeconds <= 0 { finish() }
    }

    private func finish() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        let finishedLabel = currentMode.label
        Chime.play()

        // Auto-select the next session without starting it.
        switch currentMode {
        case .focus:
            focusCycleCount += 1
            select(focusCycleCount.isMultiple(of: 4) ? .long : .short)
        case .short, .long:
            select(.focus)
        }

        notifyDone(finished: finishedLabel, nextMode: currentMode)
    }

    private func notifyDone(finished label: String, nextMode: Mode) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Pomodoro"
            content.body = "\(label) complete. \(nextMode.readyStatus)."
            content.sound = .default
            if let attachment = NotificationLogo.attachment() {
                content.attachments = [attachment]
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Chime

enum Chime {
    /// Two-tone sine blip (880 Hz -> 1175 Hz), mirroring the web app's alert sound.
    static func play() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()

        var samples: [Float] = []

        func appendTone(frequency: Double, duration: Double, gain: Float) {
            let count = Int(44_100 * duration)
            for i in 0..<count {
                let t = Double(i) / 44_100.0
                let envelope = Float(min(1.0, t * 40.0)) * Float(exp(-t * 5.0))
                samples.append(Float(sin(2 * .pi * frequency * t)) * gain * envelope)
            }
        }

        appendTone(frequency: 880, duration: 0.4, gain: 0.18)
        appendTone(frequency: 1175, duration: 0.5, gain: 0.16)

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }

        player.scheduleBuffer(buffer) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { engine.stop() }
        }
        player.play()
    }
}

// MARK: - Notification logo

enum NotificationLogo {
    /// Attaches the app icon to a notification so the logo is visible in the banner.
    /// macOS derives the banner icon from the app bundle, which can be stale or generic;
    /// attaching the image guarantees the tomato logo always shows.
    static func attachment() -> UNNotificationAttachment? {
        guard let source = Bundle.main.url(forResource: "NotificationIcon", withExtension: "png") else {
            return nil
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationIcon-\(UUID().uuidString).png")
        do {
            try FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: source, to: copy)
            return try UNNotificationAttachment(identifier: "app-logo", url: copy, options: nil)
        } catch {
            return nil
        }
    }
}

// MARK: - Main window

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: ContentView(model: TimerModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pomodoro"
        window.contentMinSize = NSSize(width: 420, height: 560)
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()

        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

// MARK: - Main window UI

struct ContentView: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.93, green: 1.0, blue: 0.99), Palette.aqua],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 12) {
                Text("Focus gently")
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.aquaDark)

                Text("Pomodoro")
                    .font(.system(size: 36, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.ink)

                Text("A clean timer for focused sessions, short pauses, and long resets.")
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                modeTabs
                timerRing
                controls
                settings
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(minWidth: 420, minHeight: 560)
    }

    private var modeTabs: some View {
        HStack(spacing: 6) {
            ForEach(TimerModel.Mode.allCases, id: \.self) { mode in
                let active = model.currentMode == mode
                Button(action: { model.select(mode) }) {
                    Text(mode.label)
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(active ? Palette.aqua : .clear)
                        .foregroundStyle(active ? .white : Palette.muted)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Palette.aqua.opacity(0.12))
        .clipShape(Capsule())
    }

    private var timerRing: some View {
        ZStack {
            Circle()
                .stroke(Palette.aqua.opacity(0.15), lineWidth: 13)
            Circle()
                .trim(from: 0, to: max(0.001, model.progress))
                .stroke(Palette.aqua, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Palette.aqua.opacity(0.35), radius: 9)

            VStack(spacing: 4) {
                Text(model.timeString)
                    .font(.system(size: 40, weight: .regular, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                Text(model.status)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 190, height: 190)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: { model.toggle() }) {
                Text(model.isRunning ? "Pause" : "Start")
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(.white)
                    .frame(minWidth: 120, minHeight: 44)
                    .background(
                        LinearGradient(colors: [Palette.aqua, Palette.aquaDark], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(Capsule())
                    .shadow(color: Palette.aqua.opacity(0.4), radius: 12, y: 5)
            }
            .buttonStyle(.plain)

            Button(action: { model.reset() }) {
                Text("Reset")
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(Palette.aquaDark)
                    .frame(minWidth: 120, minHeight: 44)
                    .background(.white.opacity(0.8))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var settings: some View {
        HStack(spacing: 14) {
            ForEach(TimerModel.Mode.allCases, id: \.self) { mode in
                DurationControl(
                    label: mode.shortLabel,
                    value: model.minutesByMode[mode] ?? 1,
                    onDecrement: { model.setMinutes((model.minutesByMode[mode] ?? 1) - 1, for: mode) },
                    onIncrement: { model.setMinutes((model.minutesByMode[mode] ?? 1) + 1, for: mode) }
                )
            }
        }
    }
}

// MARK: - Duration control

struct DurationControl: View {
    let label: String
    let value: Int
    var onDecrement: () -> Void
    var onIncrement: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(Palette.muted)

            HStack(spacing: 2) {
                Button(action: onDecrement) {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.aquaDark)

                Text("\(value)")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 44)

                Button(action: onIncrement) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.aquaDark)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.white.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Palette.aqua.opacity(0.3), lineWidth: 1)
            )
        }
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        Text(model.timeString)
            .font(.system(.body, design: .monospaced))
            .monospacedDigit()
    }
}

struct MenuBarMenu: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        Text(model.status)
        Button("Open Pomodoro") { MainWindowController.shared.show() }
        Divider()
        Button(model.isRunning ? "Pause" : "Start") { model.toggle() }
        Button("Reset") { model.reset() }
        Divider()
        Button("Quit Pomodoro") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the system associates the tomato icon with this app,
        // which also keeps notification banners from falling back to a generic icon.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: iconURL)
        }
        MainWindowController.shared.show()
    }
}

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: TimerModel.shared)
        } label: {
            MenuBarLabel(model: TimerModel.shared)
        }
    }
}
