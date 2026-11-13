import MossadCore
import SwiftUI

/// Setup: the step rail on the left in the sidebar's glass card, one topic per step on the right, and Back,
/// Skip, and Continue under it. Every step can be skipped except "You".
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let close: () -> Void
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let facts = model.facts(controller: controller, permissions: permissions)
        HStack(spacing: 0) {
            OnboardingRail(model: model, facts: facts)
                .frame(width: Onboard.railWidth)
            VStack(spacing: 0) {
                if Rehearsal.isOn {
                    RehearsalBar(model: model)
                } else {
                    WindowDragArea().frame(height: Onboard.topRow)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        page.padding(.top, Onboard.headerToBody)
                    }
                    .frame(maxWidth: Onboard.columnMax, alignment: .leading)
                    .padding(.horizontal, Onboard.gutter)
                    .padding(.top, Onboard.bodyTop)
                    .padding(.bottom, Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(model.stepToken)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                footer(facts)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) { Palette.hairline.frame(width: 1) }
        }
        .ignoresSafeArea()
        .background { WindowBackdrop() }
        .foregroundStyle(Palette.ink)
        .font(.system(size: Rhythm.bodySize))
        .onAppear { permissions.setInterval(1) }
        .onDisappear { permissions.setInterval(10) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Step \(model.step.number) of \(OnboardingStep.allCases.count)").textRole(.label).foregroundStyle(Palette.tertiary)
            Text(title)
                .font(.system(size: Onboard.titleSize, weight: .semibold)).tracking(-0.02 * Onboard.titleSize)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s)
                .accessibilityAddTraits(.isHeader)
            Text(lede)
                .font(.system(size: Rhythm.readingSize)).foregroundStyle(Palette.secondary)
                .cssLineHeight(1.5, size: 14)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Onboard.ledeMax, alignment: .leading)
                .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .you: YouStep()
        case .permissions: PermissionsStep()
        case .ai: AIStep(model: model)
        case .calendars: CalendarsStep()
        case .google: GoogleStep()
        case .check: CheckStep(model: model)
        case .sync: SyncStep()
        case .done: DoneStep()
        }
    }

    private var title: String {
        switch model.step {
        case .welcome: "Mossad takes your meeting notes"
        case .you: "Who are you?"
        case .permissions: "Let Mossad hear the call"
        case .ai: "The services that write your notes"
        case .calendars: "Your calendars"
        case .google: "Connect Google"
        case .check: "Check that recording works"
        case .sync: "Your iPhone and sync"
        case .done: "You're all set"
        }
    }

    private var lede: String {
        switch model.step {
        case .welcome: "A few calm minutes now, and then you never think about notes again."
        case .you: "Mossad puts your name on your lines in each note and finds you in meeting invites."
        case .permissions: "macOS asks you for each one. Microphone and System audio recording are required; the others make the notes better."
        case .ai: "Mossad uses your own accounts with these services. Each one bills you directly, and you can change them later in Settings."
        case .calendars: "Mossad reads the calendars you choose, to name each call from its invite and list who was there."
        case .google: "Optional. With your own Google app, Mossad reads each invite's answers and attached Gemini notes, and fills names and job titles from your directory."
        case .check: "A quick test of both sides of a call, so your first meeting is not the test."
        case .sync: "Optional. Read your meetings on your iPhone, or keep everything on this Mac."
        case .done: "Mossad now waits quietly for your next call."
        }
    }

    private func footer(_ facts: OnboardingFacts) -> some View {
        HStack(spacing: Space.s) {
            if model.step.isSkippable, model.step != .done, model.step != .welcome {
                Button("Skip this step") { model.skip() }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.secondary, weight: .medium))
                    .help("You can come back to it from the list on the left, or from Settings.")
            } else if model.step == .you, !OnboardingStep.you.isSatisfied(by: facts) {
                Text("Mossad needs your name to continue.").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
            }
            Spacer(minLength: Space.s)
            if model.step != .welcome {
                Button("Back") { model.back() }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
            }
            if model.step == .done {
                Button(Rehearsal.isOn ? "Finish rehearsal" : "Open Mossad") {
                    model.finish()
                    controller.finishOnboarding()
                }
                .buttonStyle(.sheetPrimary)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .welcome ? "Get started" : "Continue") { model.advance() }
                    .buttonStyle(.sheetPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.progress.canContinue(facts: facts))
            }
        }
        .padding(.horizontal, Onboard.gutter).frame(height: Onboard.footerHeight)
        .hairline(.top)
    }
}

/// The steps with their state, in the sidebar's floating glass card with the traffic lights inside.
private struct OnboardingRail: View {
    @ObservedObject var model: OnboardingModel
    let facts: OnboardingFacts
    @State private var hovered: OnboardingStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea().frame(height: Chrome.lightsRow + Chrome.lightsToNav)
            Text(Rehearsal.isOn ? "Rehearsal" : "Set up Mossad").textRole(.label).foregroundStyle(Palette.tertiary)
                .padding(.horizontal, Chrome.navRowPadding).padding(.bottom, Space.s)
            VStack(alignment: .leading, spacing: Chrome.navRowGap) {
                ForEach(OnboardingStep.allCases) { row($0) }
            }
            Spacer(minLength: Space.m)
            Text("You can change all of this later in Settings.")
                .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Chrome.navRowPadding).padding(.bottom, 4)
        }
        .padding(Chrome.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .chromeGlass(in: RoundedRectangle(cornerRadius: Chrome.sidebarRadius, style: .continuous), fill: Palette.sidebar, shadow: .card)
        .padding(Chrome.sidebarInset)
    }

    private func row(_ step: OnboardingStep) -> some View {
        let state = model.progress.state(of: step, facts: facts)
        let on = model.step == step
        return Button { model.jump(to: step) } label: {
            HStack(spacing: Chrome.navIconGap) {
                StepMark(step: step, state: state)
                Text(step.title)
                    .font(.system(size: Rhythm.bodySize, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Palette.ink : state == .upcoming ? Palette.secondary : Palette.navText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                switch state {
                case .needsYou: Text("Needs you").font(.system(size: Rhythm.noteSize, weight: .medium)).foregroundStyle(Palette.accent)
                case .skipped: Text("Skipped").font(.system(size: Rhythm.noteSize)).foregroundStyle(Palette.tertiary)
                default: EmptyView()
                }
            }
            .padding(.horizontal, Chrome.navRowPadding)
            .frame(height: Onboard.railRow)
            .background(on ? Palette.selection : hovered == step ? Palette.fill : .clear,
                        in: RoundedRectangle(cornerRadius: Chrome.navRowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? step : hovered == step ? nil : hovered }
        .accessibilityLabel("Step \(step.number), \(step.title)")
        .accessibilityValue(state.spoken)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// A step's mark in the rail: its number ahead, a check when done, the accent when it needs the owner.
private struct StepMark: View {
    let step: OnboardingStep
    let state: OnboardingStepState

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Palette.ok.opacity(0.16))
                IconImage(.checkSmall, size: 11).foregroundStyle(Palette.okText)
            case .current:
                Circle().fill(Palette.accentFill)
                Text("\(step.number)").font(.system(size: Rhythm.noteSize, weight: .bold)).foregroundStyle(Palette.onAccent)
            case .needsYou:
                Circle().fill(Palette.accentTint)
                Text("!").font(.system(size: Rhythm.noteSize, weight: .bold)).foregroundStyle(Palette.accent)
            case .skipped:
                Circle().strokeBorder(Palette.ring, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                Text("\(step.number)").font(.system(size: Rhythm.noteSize, weight: .semibold)).foregroundStyle(Palette.tertiary)
            case .upcoming:
                Circle().strokeBorder(Palette.ring, lineWidth: 1.2)
                Text("\(step.number)").font(.system(size: Rhythm.noteSize, weight: .semibold)).foregroundStyle(Palette.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .monospacedDigit()
        .accessibilityHidden(true)
    }
}

extension OnboardingStepState {
    var spoken: String {
        switch self {
        case .upcoming: "Not started"
        case .current: "Current step"
        case .done: "Done"
        case .needsYou: "Needs you"
        case .skipped: "Skipped"
        }
    }
}

/// Setup's sizes, on the main window's grid.
enum Onboard {
    static let railWidth: CGFloat = 244
    static let railRow: CGFloat = 34
    static let topRow: CGFloat = 52
    static let gutter: CGFloat = 48
    static let bodyTop: CGFloat = 20
    static let columnMax: CGFloat = 680
    static let ledeMax: CGFloat = 560
    static let titleSize: CGFloat = 28
    static let headerToBody: CGFloat = 28
    static let footerHeight: CGFloat = 64
    /// The rows of a step: like Settings rows, a little taller.
    static let rowPadding: CGFloat = 12
}
