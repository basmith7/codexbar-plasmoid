# claude-swap source for the Claude provider

Date: 2026-09-22. Status: approved.

## Goal

Show every Claude Code account managed by [claude-swap](https://github.com/realiti4/claude-swap)
in the panel widget, one card per account, and switch the active Claude Code login from the
popup. Optionally run claude-swap's auto-switch on each refresh.

Non-goals: adding accounts, tray icon, per-account chat history, reproducing cswap's
threshold/strategy settings.

## Enablement

- `claude-swap` is added to the Claude provider's source list in `configProviders.qml`
  (`sources: ["auto", "cli", "oauth", "api", "web", "claude-swap"]`). Nothing changes unless
  the user selects it. `auto` never resolves to `claude-swap`.
- New settings in `main.xml`:
  - `claudeSwapPath` (String, default `""` meaning `cswap` on PATH). Shown in the Claude row
    when source is `claude-swap`.
  - `claudeSwapAutoSwitch` (Bool, default `false`). Checkbox "Auto-switch accounts before each
    refresh" in the same row.
- Both settings are passed to the helper as `--claude-swap-path` and `--claude-swap-auto`.
  They are machine-local and excluded from Sync Write / Sync Read payloads.

## Adapter module: `plasmoid/contents/code/codexbar-claude-swap.mjs`

Pure module, no plasmoid imports, so it lifts out cleanly. Exports:

- `listAccounts({ executable, timeoutMs })` runs exactly `[executable, "list", "--json"]`
  with `execFileSync` (no shell). Rejects when `schemaVersion !== 1` or `accounts` is not an
  array. Returns `{ activeAccountNumber, accounts }` where each account is the parsed slot.
- `autoSwitchOnce({ executable, timeoutMs })` runs `[executable, "auto", "--once", "--json"]`.
  Returns `{ exitCode, switched: boolean, from, to, message }` parsed from the last JSON
  event line. Exit codes: 0 switched, 1 error, 2 nothing to do, 3 blocked. Codes 2 and 3 are
  not errors. Never throws on non-zero exit; returns the error in `message`.
- `switchTo({ executable, slot, timeoutMs })` runs `[executable, "switch", String(slot), "--json"]`.
  Only called from the QML switch DataSource via the helper's `--action switch --slot N`
  mode. Returns `{ ok, activeAccountNumber, message }`.
- `toEntries(list, { anonymize })` maps accounts to widget entries. Parses only: `number`,
  `email`, `organizationName`, `alias`, `active`, `disabled`, `usageStatus`, `message`,
  `usage.fiveHour`, `usage.sevenDay`, `usage.scoped[]`, `usageFetchedAt`. Unknown fields are
  ignored.

Entry shape produced by `toEntries` matches `normalizeProvider` output:

```
{
  provider: "claude",
  source: "claude-swap",
  account: <email or anonymized>,
  organization: <organizationName or anonymized>,
  plan: <alias or null>,
  updatedAt: <usageFetchedAt or now>,
  status: null,
  error: <message when usageStatus !== "ok", else null>,
  rows: [ { id: "primary", title: "Session", percentLeft: 100 - fiveHour.pct, resetsAt, windowMinutes: 300, pace },
          { id: "secondary", title: "Weekly", percentLeft: 100 - sevenDay.pct, resetsAt, windowMinutes: 10080, pace },
          ...one row per scoped window: { id: "scoped:<name>", title: <name>, ... windowMinutes: 10080 } ],
  creditsRemaining: null, limitResetCredits: null, tokenUsage: null, dailyUsage: [],
  claudeSwap: { slot: number, active: bool, disabled: bool, usageStatus: string, switchable: bool }
}
```

- `pace` is derived from cswap's `expectedPct`, `aheadOfPace`, `willLastToReset`,
  `projectedExhaustionAt` when present; otherwise `computePace` from the helper is applied by
  the caller.
- A window with no `pct` yields no row. An account with `usageStatus !== "ok"` yields an
  entry with `rows: []` and `error` set, so the card shows the problem text.
- `switchable` is `!active && usageStatus === "ok"`. Disabled slots stay switchable, matching
  cswap semantics (disabled only excludes auto-rotation).
- Stable entry id falls back to the existing `assignStableEntryIds` (`claude:<email>`).

## Helper integration (`codexbar-plasmoid-helper.mjs`)

- New args: `--claude-swap-path`, `--claude-swap-auto`, `--action switch --slot N`.
- When a Claude provider config has `source === "claude-swap"`:
  1. If `--claude-swap-auto` is set, call `autoSwitchOnce` first. A `switched` result is
     attached to the snapshot as `claudeSwapEvent: { switched: true, from, to }`. Errors
     attach `claudeSwapEvent: { error }` and do not abort the list.
  2. Call `listAccounts`, then `toEntries`, then push each entry. The CodexBar CLI is not
     invoked for Claude in this mode.
  3. Adapter failure yields one Claude entry with `source: "claude-swap"`, `rows: []` and
     `error` set, so the widget's retain-last-success logic keeps prior cards.
- `--action switch --slot N` bypasses the usage fetch, runs `switchTo`, and prints its
  result as JSON. This keeps the QML side to "run helper, parse JSON".
- Cost scanning (`includeCost`) is unchanged: Claude local cost still comes from the existing
  CLI/native path and attaches to the active account's entry only.

## QML

- `ProviderCard.qml`: when `entry.claudeSwap` exists, show a small "Active" badge on the
  active slot and a "Switch" button on switchable slots. While `card.switching` is true the
  button is disabled and reads "Switching…". Non-switchable inactive slots show no button.
- `main.qml`: new `Plasma5Support.DataSource { id: accountSwitcher }`. `switchClaudeAccount(entry)`
  builds `node <helper> --action switch --slot <n> --claude-swap-path <p>`, marks the entry id
  as switching, connects the source. On result: clear switching, set `root.lastError` on
  failure, and call `refreshNow(true)` on success. Switch requests are serialized: a second
  click while one is in flight is ignored.
- Snapshot `claudeSwapEvent.switched` shows a one-refresh notice line in the popup header
  ("Auto-switched to <account>"). Cleared on the next snapshot without the event.
- `configProviders.qml`: source option label "claude-swap"; the Claude row shows the path
  field and the auto-switch checkbox only when that source is selected.

## Error handling

- `cswap` missing: entry error "cswap not found (set the path in settings)".
- Schema mismatch: entry error "claude-swap returned schemaVersion N; expected 1".
- Timeout: uses the existing helper timeout; entry error "claude-swap timed out".
- Switch failure: `root.lastError` shows cswap's message; the card returns to its prior state.

## Testing

- `tests/claude-swap-adapter.test.mjs` (node:test): fixtures for the real two-account list,
  a quarantined slot (`usageStatus: "token_expired"`), a missing `pct`, a disabled slot,
  `schemaVersion: 2`, and `auto --once` outputs for exit codes 0/2/3. Asserts entry shape,
  `switchable`, rows, pace mapping, and anonymization.
- `scripts/setup-mock-cli.sh` gains a fake `cswap` that serves the fixture and records switch
  calls to a file, so `run-virtual-plasma.sh` exercises the cards and button.
- `./scripts/agent-check.sh` must pass; a `virt-shot` capture confirms two Claude cards with
  the badge and button.

## Files touched

- `plasmoid/contents/code/codexbar-claude-swap.mjs` (new)
- `plasmoid/contents/code/codexbar-plasmoid-helper.mjs`
- `plasmoid/contents/ui/configProviders.qml`, `ProviderCard.qml`, `main.qml`
- `plasmoid/contents/config/main.xml`
- `scripts/setup-mock-cli.sh`, `tests/claude-swap-adapter.test.mjs` (new)
- `README.md`, `CHANGELOG.md`
