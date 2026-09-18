# token_dashboard — Claude 사용량 대시보드

개인용 macOS 네이티브 앱(SwiftUI + Swift Charts). 두 데이터원을 결합한다:
**공식 OAuth 사용량 API**(한도 게이지의 정본 %) + **로컬 세션 로그 파싱**(어디에 얼마나 썼나).
외부 의존성 0, Xcode 불필요.

```bash
./build.sh && open build/ClaudeUsage.app     # CLT 의 swiftc 만으로 .app 번들 생성
```

앱 안에서 ⌘R = 로그 재스캔 + 공식 % 즉시 갱신. 설정: `~/.config/claude-usage/config.json`.

## 문서 지도

| 파일 | 용도 |
|---|---|
| `CLAUDE.md` (이 파일) | 에이전트용 작업 규칙·아키텍처·함정 |
| `PROGRESS.md` | 작업 이력·현재 상태·열린 항목 (작업 후 갱신할 것) |
| `README.md` | 사용자용 상세 문서 — 계량 원리·검증 과정·설정 스키마의 정본 |

## 아키텍처 (Sources/)

| 파일 | 역할 |
|---|---|
| `CodexScanner.swift` | `~/.codex/sessions/**/*.jsonl` 스캔 (Codex 탭 전용, 별도 타입 체계) |
| `CodexView.swift` | Codex 탭 UI (한도 게이지·모델·프로젝트·일별) |
| `Scanner.swift` | `~/.claude/projects/**/*.jsonl` 바이트 스캔 (mmap + concurrentPerform, JSON 역직렬화 없음, 2.2GB/3초) |
| `Model.swift` | 집계(Snapshot)·가격표·5시간 블록·주간 창·한도 역산 |
| `Official.swift` | 공식 사용량 API 조회 (토큰 확보 → fetch → limits[] 파싱) |
| `Config.swift` | 한도 설정·보정·extraRoots (JSON) |
| `TimeUtil.swift` | DateFormatter 없는 고정 포맷 시간 처리 (성능 때문) |
| `App.swift` | AppState (스캔 + 공식 폴링 오케스트레이션) |
| `OverviewView.swift` | 개요 탭: KPI·한도 게이지 3종·차트 |
| `RankView.swift` / `DailyView.swift` | 프로젝트·모델·세션 / 일별 탭 |
| `Format.swift` / `Theme.swift` | 억/만 축약, 다크 테마 |

## Codex 집계 (별도 탭 · Claude 와 절대 섞지 말 것)

`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 을 읽는다. **필드 의미가 Claude 와 달라서**
같은 코드/타입을 재사용하면 안 된다 (그래서 `CodexTotals`/`CodexRec` 를 따로 뒀다):

1. **`total_token_usage` 는 세션 누계** → 그냥 더하면 폭증. **증가분만 합산**한다.
   부수 효과로 중복 이벤트가 증가분 0 이 되어 자동 배제된다 (실측 254개 중 4개가 중복).
   누계가 줄면(리셋) 그 시점 값 자체를 증가분으로 잡는다.
2. **필드가 포함관계**: `total = input + output`, `cached ⊂ input`, `reasoning ⊂ output`.
   Claude 처럼 캐시를 따로 더하면 **캐시 이중 계상**이 된다. 실측 검증: input 6,876,582,899
   + output 24,708,440 = total 6,901,291,339 (정확히 일치).
3. **파일명 날짜 ≠ 내용 날짜** — resume 로 5월 파일에 8월 이벤트가 들어있다. 귀속은 반드시
   각 이벤트의 `timestamp`(→ KST 로컬 일자)로 한다.
4. **파일 1개에 세션 최대 4개**, 45개 세션이 파일을 걸친다. `cwd`(프로젝트)·`model` 은
   줄을 읽어가며 갱신한다.

**한도는 로그에 이미 있다** — `token_count` 이벤트의 `rate_limits` 에 계정 공식 사용률이
박혀 있어 OAuth/API 호출이 필요 없다. `primary`/`secondary` 위치는 파일마다 뒤바뀌므로
**`window_minutes` 로 분류**할 것 (300=5시간, 10080=7일). `plan_type` 은 prolite→team→plus
로 바뀐 이력이 있다.

**계정 구분은 `plan_type` 이 유일한 단서다.** 세션 로그에는 계정 식별자(email/account_id/org)가
**전혀 없다** — `session_meta` 키를 전수 확인했고, 로그에 보이는 `account_email` 문자열은 명령
출력 등 본문 텍스트지 구조 필드가 아니다. `limit_id` 도 거의 전부 `codex` 라 구분에 못 쓴다.
따라서:

- 토큰은 `token_count.rate_limits.plan_type` 으로 계정에 귀속한다. rate_limits 가 없는
  이벤트는 **같은 파일에서 마지막에 관측된 plan 을 이어 쓰고**, 첫 관측 이전 구간은 소급 적용한다
  (그래도 남는 미귀속은 "미상"으로 표시 — 실측 17%).
- 한도 게이지는 **선택된 계정의 plan** 관측만 쓴다. 전역 최신값을 쓰면 남의 계정 한도가 뜬다.
- 현재 로그인 계정은 `~/.codex/auth.json` 의 `id_token`(JWT) 클레임에서 읽는다
  (`email`, `https://api.openai.com/auth.chatgpt_plan_type`, `chatgpt_account_id`). 이 파일은
  **현재 계정 하나만** 알려주므로, 나머지 계정은 로그의 plan 으로만 식별된다.
- 한계: 같은 플랜을 쓰는 계정이 둘 이상이면 합쳐져 보인다. 화면 캡션에 이 한계를 명시할 것.

비용은 표시하지 않는다 (gpt-5.x 공식 요율 미확인). 요율이 확인되면 `CodexTotals` 에 붙인다.

## 절대 규칙

1. **파싱 3함정을 깨뜨리지 말 것** (셋 다 실측으로 확인, 위반 시 수치가 크게 틀어짐):
   - 한 API 응답이 여러 줄로 중복 기록 → `(message.id + requestId)` 로 중복 제거 (55%가 중복)
   - `output_tokens` 만은 마지막 줄에 최종값 → 그룹 내 **최대값** 채택 (첫줄 채택 시 18% 누락)
   - `<프로젝트>/<세션>/subagents/*.jsonl` 은 부모 프로젝트·세션으로 귀속
2. **두 단위 체계를 섞지 말 것**: 한도 = 공식 % (+ 출력 토큰 근사) / 사용 분석 = 총 처리 토큰(캐시 포함).
   화면의 색 배너가 그 경계다.
3. **공식 API 예절**: 폴링 10분 + 429 시 지수 백오프(최대 60분) 유지 — 레이트리밋이 길고
   계정 내 다른 클라이언트(집 기기의 Claude Tuner)와 한도를 공유한다. 토큰은 로그·화면·디스크에
   절대 출력 금지, config 평문 저장 금지(Keychain 만).
4. **Anthropic 내부 계량은 미공개**: 출력 토큰은 "작동하는 근사"일 뿐이고 Fable 은 ~2-3배로
   소모된다(비용 가중 추정). 토큰 한도값을 사실처럼 단정하는 문구를 넣지 말 것 — 공식 %가 정본.

## 공식 사용량 API 치트시트 (실측 2026-07-23)

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <토큰>          # 아래 토큰 소스 순
anthropic-beta: oauth-2025-04-20
```

- 토큰은 **후보 체인**으로 시도 (Official.swift): ① 직전 성공 토큰(캐시) ② Keychain
  `ClaudeUsageDashboard-token` (사용자가 `claude setup-token` 으로 등록, 세션 독립) ③ 실행 중
  claude 프로세스들의 env `CLAUDE_CODE_OAUTH_TOKEN` — **프로세스 젊은 순 최대 4종** ④ Keychain
  `Claude Code-credentials`. 401/403 이면 다음 후보, 429·네트워크 오류면 즉시 중단(호출 절약).
  주의: env 토큰은 **세션 단위**로 보이며(scope `user:sessions:claude_code`) 창을 닫으면
  프로세스가 남아도 토큰이 죽는다 — "최신 프로세스 = 유효"가 아니므로 체인을 절대 단일
  선택으로 되돌리지 말 것 (2026-07-27 미연결 장애의 원인이 pgrep 첫 매치 = 만료 토큰이었음)
- **정본은 `limits[]` 배열**: `{kind: session|weekly_all|weekly_scoped, percent, resets_at,
  severity, scope.model.display_name}` — Fable 전용 %는 `weekly_scoped` + display_name "Fable"
- 톱레벨 `five_hour`/`seven_day` 는 보충용. `spend`/`extra_usage` 는 크레딧 지표(파싱 제외)
- `resets_at` 은 마이크로초 6자리 → ISO8601DateFormatter 가 못 읽으므로 소수부 제거 후 파싱
- 미분류 버킷 키는 UI 캡션에 노출됨 → 스키마가 바뀌면 화면에서 바로 보인다

## 검증 방법 (UI 없이)

데이터 레이어만 컴파일해 headless 로 돌린다 — **App.swift 등 UI 파일 포함 금지** (@main 충돌 + 빌드 급증):

```bash
S=<스크래치>; cat > $S/main.swift <<'EOF'
import Foundation
let snap = Scanner.scan(year: 2026)   // 또는 OfficialAPI.parse(저장해둔 응답)
...
EOF
swiftc -O Sources/Model.swift Sources/TimeUtil.swift Sources/Scanner.swift \
  Sources/Format.swift Sources/Config.swift Sources/Official.swift $S/main.swift -o $S/verify && $S/verify
```

공식 응답 샘플 캡처본이 필요하면 새로 1회만 curl (레이트리밋 소모 주의).

## 관련 외부 사항

- **Claude Tuner** (claudetuner.com): 공식 %의 스냅샷 기록기 (`est_tokens = Δ% × 130,000`, 주간
  13M 가정). 일별 숫자는 스냅샷 귀속이라 부정확 — 이 앱의 로그 기준 일별이 더 정확하다.
- **azit** (`~/ai/azit`): 팀 단위 Tuner leaderboard 를 매일 DB 수집. Tuner API 가
  opus/sonnet 필드를 없애서(→`by_provider`) 수집기가 0을 적재 중 — 별도 수리 태스크 발행됨
  (이 프로젝트 범위 아님).
