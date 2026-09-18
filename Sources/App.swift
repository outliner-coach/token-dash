import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1040, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear { state.reload() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("새로고침") { state.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var tab: Tab = .overview
    @Published var year: Int = 2026
    @Published var config = Config.load()
    @Published var limits = DerivedLimits()
    @Published var official: OfficialUsage?
    @Published var officialNote = "연결 시도 전"
    @Published var codex: CodexSnapshot?

    private var ticker: Timer?
    private var officialTicker: Timer?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "개요"
        case projects = "프로젝트"
        case models = "모델"
        case sessions = "세션"
        case daily = "일별"
        case codex = "Codex"
        var id: String { rawValue }
    }

    init() {
        // 라이브 데이터라 활성 블록 잔여시간/소모속도를 초 단위로 갱신한다.
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        refreshOfficial()
    }

    /// 공식 사용률 폴링. 엔드포인트 레이트리밋이 엄격해서(주말 내내 10분 주기로도 429 반복 실측)
    /// 기본 30분 간격 + 429 시 지수 백오프(최대 60분). 수동 새로고침(⌘R)은 즉시 시도한다.
    private var officialBackoff: TimeInterval = 1800

    private func scheduleNextOfficialPoll() {
        officialTicker?.invalidate()
        officialTicker = Timer.scheduledTimer(withTimeInterval: officialBackoff, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshOfficial() }
        }
    }

    func refreshOfficial() {
        Task.detached(priority: .utility) {
            let result = OfficialAPI.fetchSync()
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.official = usage
                    self.officialBackoff = 1800
                    self.officialNote = "공식 연결됨 · \(usage.sourceNote)"
                case .failure(let err):
                    // 실패해도 기존 값은 유지. 레이트리밋이면 물러났다가 다시 온다.
                    if err.message.contains("rate_limit") {
                        self.officialBackoff = min(3600, self.officialBackoff * 2)
                    } else {
                        self.officialBackoff = 1800
                    }
                    let next = Int(self.officialBackoff / 60)
                    self.officialNote = (self.official == nil ? "미연결" : "갱신 실패")
                        + ": \(err.message) — \(next)분 후 재시도"
                }
                self.scheduleNextOfficialPoll()
            }
        }
    }

    func reload() {
        guard !loading else { return }
        loading = true
        progress = 0
        refreshOfficial()   // 수동 새로고침(⌘R)엔 공식 %도 즉시 갱신
        let y = year
        var roots = [Scanner.defaultRoot()]
        for path in config.extraRoots ?? [] {
            let expanded = NSString(string: path).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                roots.append(URL(fileURLWithPath: expanded))
            }
        }
        // Codex 로그는 별도 소스라 병렬로 훑는다 (없으면 조용히 건너뜀).
        if CodexScanner.isAvailable {
            Task.detached(priority: .utility) {
                let c = CodexScanner.scan(year: nil)
                await MainActor.run { [weak self] in self?.codex = c }
            }
        }
        Task.detached(priority: .userInitiated) {
            let snap = Scanner.scan(roots: roots, year: y) { p in
                Task { @MainActor [weak self] in
                    self?.progress = p.total == 0 ? 1 : Double(p.done) / Double(p.total)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshot = snap
                self.limits = snap.derivedLimits(self.config)
                self.loading = false
                self.progress = 1
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TabBar()
                Divider().overlay(Theme.border)
                if let snap = state.snapshot, !snap.isEmpty {
                    ScrollView {
                        Group {
                            switch state.tab {
                            case .overview: OverviewView(snap: snap, limits: state.limits, config: state.config,
                                                          official: state.official, officialNote: state.officialNote)
                            case .projects: RankView(snap: snap, kind: .project)
                            case .models: RankView(snap: snap, kind: .model)
                            case .sessions: RankView(snap: snap, kind: .session)
                            case .daily: DailyView(snap: snap)
                            case .codex: CodexTabView(snap: state.codex)
                            }
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.visible)
                } else {
                    LoadingView()
                }
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch state.tab {
        case .overview: return "Claude 사용량 · \(state.year)년"
        case .projects: return "프로젝트 (토큰 많은 순)"
        case .models: return "모델 (토큰 많은 순)"
        case .sessions: return "세션 (토큰 많은 순)"
        case .daily: return "일별 토큰 사용량"
        case .codex: return "Codex 사용량"
        }
    }
}

private struct TabBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                ForEach(AppState.Tab.allCases) { tab in
                    let active = state.tab == tab
                    Button { state.tab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Color.white : Theme.dim)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(active ? Theme.blue : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.cardAlt))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border, lineWidth: 1))

            HStack {
                Spacer()
                Button { state.reload() } label: {
                    Image(systemName: state.loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(state.loading ? Theme.faint : Theme.dim)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.cardAlt))
                        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(state.loading)
                .help("세션 로그 다시 스캔 (⌘R)")
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

private struct LoadingView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .tint(Theme.green)
                .frame(width: 280)
            Text(state.loading
                 ? "세션 로그 스캔 중… \(Int(state.progress * 100))%"
                 : "~/.claude/projects 에서 \(state.year)년 데이터를 찾지 못했습니다.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
