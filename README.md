# worktree-cleanup

**AI coding agents love spinning up git worktrees and never cleaning them up.**

This is an [Agent Skill](https://agentskills.io) that lets your coding agent (Claude Code, Cursor, Codex, and other tools that support `SKILL.md`) find every stale worktree on your machine, measure it, and tell you which ones are safe to delete. It removes them only after you say yes. On a Mac it also reports Xcode DerivedData and unavailable iOS simulators. In any repo it scans, it reports Cargo `target/` directories the same way.

Tell your agent *"I'm low on disk space"* and it will:

1. **Scan** your repos and the folders where agents keep worktrees (Cursor, Claude Code, Codex, Conductor, Superset, VS Code, Gemini CLI, claude-squad, Vibe Kanban). This step is read-only.
2. **Classify** every worktree:
   - **SAFE**: clean, merged (including squash merges), not locked, and idle for a while.
   - **REVIEW**: has uncommitted changes, unpushed commits, a lock, or recent activity.
3. **Show you a table** with sizes and wait for your answer.
4. **Remove** only what you approved, with `git worktree remove` and then `git worktree prune`. It never runs `rm -rf` on your work.

## Real run

A real run on my Mac mini: 52 agent worktrees taking 51.3 GB went down to 29 worktrees taking 5.6 GB, and free space went from 162 GB to 180 GB. Repo names are anonymized.

![Before](assets/before.png)

![After](assets/after.png)

## Install

The skill folder must be named `worktree-cleanup` so it matches the skill's `name`.

**Claude Code** (personal skills live in `~/.claude/skills/`):

```bash
git clone https://github.com/gregkop/worktree-cleanup ~/.claude/skills/worktree-cleanup
```

**Cursor** (loads `~/.cursor/skills/` and `~/.agents/skills/`, and also reads `~/.claude/skills/`):

```bash
git clone https://github.com/gregkop/worktree-cleanup ~/.cursor/skills/worktree-cleanup
```

**Codex** (user skills live in `~/.agents/skills/`):

```bash
git clone https://github.com/gregkop/worktree-cleanup ~/.agents/skills/worktree-cleanup
```

**All three with one copy.** Cursor and Codex both read `~/.agents/skills`, and Claude Code follows symlinked skill folders:

```bash
git clone https://github.com/gregkop/worktree-cleanup ~/.agents/skills/worktree-cleanup
mkdir -p ~/.claude/skills && ln -s ~/.agents/skills/worktree-cleanup ~/.claude/skills/worktree-cleanup
```

To install it for one project instead, put it in `.claude/skills/`, `.cursor/skills/`, or `.agents/skills/` inside the repo.

## Use

- Just describe the problem: *"my disk is full"*, *"clean up old worktrees"*, *"what is eating my SSD?"*
- Or invoke it directly: `/worktree-cleanup` in Claude Code or Cursor, `$worktree-cleanup` in Codex.
- Or run the scanner yourself. It needs no agent:

```bash
bash ~/.agents/skills/worktree-cleanup/scripts/scan_worktrees.sh          # scan $HOME
bash .../scan_worktrees.sh ~/code --stale-days 14                         # narrower, stricter
bash .../scan_worktrees.sh --json                                         # for scripts and agents
bash .../scan_worktrees.sh --plan                                         # print (never run) removal commands
bash .../scan_worktrees.sh --xcode-stale-days 30                         # DerivedData stale threshold
```

## Example output

From the bundled sandbox test (`tests/sandbox_test.sh`). On a real machine the sizes are in GB.

```text
worktree-cleanup scan (read-only) - roots: ~ | stale after 7d

VERDICT    SIZE  IDLE  TOOL          REPO    BRANCH             STATUS                      PATH
SAFE       6.0M   30d  cursor        webapp  feat/merged        clean, merged               ~/.cursor/worktrees/webapp/abc1
SAFE        24K   30d  cursor        webapp  feat/squash        clean, squash-merged, gone  ~/.cursor/worktrees/webapp/sq9
SAFE        20K   30d  codex         webapp  (deca245)          clean, merged               ~/.codex/worktrees/1a2b/webapp
SAFE        16K   30d  vscode?       api     feat-x             clean, merged               ~/code/api.worktrees/feat-x
SAFE          0     -  superset      webapp  fix-typo           missing (prunable)          ~/.superset/worktrees/webapp/fix-typo
REVIEW      24K   30d  cursor        webapp  feat/open-pr       clean, pushed               ~/.cursor/worktrees/webapp/pr7
REVIEW      24K   30d  claude-code   webapp  worktree-refactor  dirty:2, merged             ~/code/webapp/.claude/worktrees/refactor
REVIEW      24K   30d  conductor     webapp  feat/unpushed      clean, unpushed:2           ~/conductor/workspaces/webapp/oslo
REVIEW      20K   30d  claude-squad  webapp  squad/task         clean, merged, locked       ~/.claude-squad/worktrees/task_17a
REVIEW      20K    0d  codex         webapp  (deca245)          clean, merged               ~/.codex/worktrees/9f8e/webapp
REVIEW      16K    0d  cursor        doomed  -                  orphaned                    ~/.cursor/worktrees/doomed/zz1

Summary: 11 worktree(s) across 2 repo(s) (incl. 1 orphaned dir(s))
  SAFE      5      6.1M reclaimable by removing stale worktrees
  REVIEW    6      128K needs a human decision (uncommitted/unpushed/locked/recent)
  Regenerable dirs (node_modules, .venv, target, build, ...) inside all worktrees: 6.0M

Agent worktree locations found:
  cursor        ~/.cursor/worktrees                             4 worktree(s)  6.1M
  codex         ~/.codex/worktrees                              2 worktree(s)  40K
  conductor     ~/conductor/workspaces                          1 worktree(s)  24K
  superset      ~/.superset/worktrees                           1 worktree(s)  0K
  claude-squad  ~/.claude-squad/worktrees                       1 worktree(s)  20K

Nothing was modified. Use --plan to print removal commands for SAFE worktrees, SAFE DerivedData, and Cargo targets. Use --json for machine output.
```

On Linux that run continues with two short sections: Xcode is skipped, and Cargo reports whatever `target/` directories (none, in this sandbox) sit next to a `Cargo.toml`.


## How verdicts are decided

| Verdict | Condition |
|---|---|
| **SAFE** | The directory is already gone (prunable metadata), **or** all of these hold: no modified or untracked files; HEAD is merged into the default branch (by ancestry, rebase, or squash patch-id match), or every commit is already on a remote and the upstream branch was deleted or HEAD is detached; not locked; idle at least `--stale-days` (default 7). |
| **REVIEW** | Anything else: dirty, unpushed or unmerged commits, pushed but not merged (open PR?), locked, recently active, it's your current directory, has submodules, orphaned (its repo was deleted), or couldn't be inspected. |

## Xcode and iOS caches (macOS)

Macs that build with Xcode, especially ones shared with coding agents, fill up with DerivedData and simulators that no project still uses. The scanner reports them only on macOS. On Linux it prints one skipped line and continues with the rest of the report.

| What | Verdict | Cleanup, after you say yes |
|---|---|---|
| DerivedData project folder, untouched for at least 14 days (`--xcode-stale-days`) | **SAFE**, if Xcode is not running | `rm -rf` of that folder only |
| DerivedData folder whose `info.plist` `WorkspacePath` points at a project that is gone | **SAFE**, even if it is newer, if Xcode is not running | same |
| DerivedData while `pgrep -x Xcode` finds Xcode, or a folder used recently | **REVIEW** | none until Xcode is quit and you re-scan |
| Unavailable simulators (`xcrun simctl list devices unavailable`) and their size under `~/Library/Developer/CoreSimulator/Devices` | **SAFE** | `xcrun simctl delete unavailable` |
| Unavailable simulator runtimes | report only | only if you name one (`xcrun simctl runtime delete`) |
| iOS DeviceSupport versions older than the stale threshold | report only | only if you name those folders |
| `~/Library/Developer/Xcode/Archives` | report only, one total | never |

DerivedData is regenerable. Archives are not treated that way: the plan never lists them. Simulator device directories are not removed with `rm`. If you moved DerivedData in Xcode's Locations settings, the scanner follows that path when `defaults` can read it, or you can set `XCODE_DERIVED_DATA`.

## Cargo build output

Agent worktrees of Rust projects keep a full `target/` tree each. The scanner looks in the repos and worktrees it already found. A `target` directory counts only when a `Cargo.toml` is in the same parent. It reports size and age, and marks that directory **SAFE** because `cargo` can rebuild it. If `cargo` or `rustc` is running, the rows are **REVIEW** and the plan is empty.

When `CARGO_TARGET_DIR` is set and the directory exists, that shared folder is reported instead of every project's `target/`, so the same files are not counted twice. One `cargo clean` clears it.

The plan prefers `cargo clean --manifest-path <Cargo.toml>` when `cargo` is on PATH. Otherwise it removes that target directory. `~/.cargo/registry/cache` and `~/.cargo/git/checkouts` (under `$CARGO_HOME` if you set it) are sizes only and are not in the plan.

## Safety

- **The scanner is read-only.** It never deletes, moves, fetches, or pushes. It sets `GIT_OPTIONAL_LOCKS=0` so even `git status` won't rewrite an index.
- **Nothing is removed without your explicit OK** on a specific list.
- **Removal uses `git worktree remove` without `--force`.** Git itself refuses to delete a worktree with modified or untracked files, or one that is locked.
- **Branches are kept.** Removing a worktree does not delete its branch.
- **Ignored files go with the worktree.** That includes `.env` copies, `node_modules`, and build output. The agent warns you when this matters.
- **Xcode DerivedData and Cargo targets are regenerable, and still need a yes.** The plan lists only SAFE DerivedData children (and only when Xcode is not running), one `xcrun simctl delete unavailable` when simulators are unavailable, and `cargo clean` or a matching `rm` of an adjacent `target/`. Archives, iOS DeviceSupport, unavailable runtimes, and the Cargo registry and git checkouts are report-only.
- **Other caches stay report-only.** npm/pnpm/uv caches and Docker are listed with sizes when you ask, and are not part of this plan.

## Requirements

macOS or Linux, `git` (2.31+ recommended), and bash 3.2+ (the stock macOS bash works). The Xcode and simulator section needs macOS; `xcrun` is used when it is installed and skipped when it is not. Cargo cleanup uses `cargo` when it is on PATH. No other dependencies and no network access.

## Development

```bash
tests/sandbox_test.sh            # builds a throwaway sandbox of repos and worktrees and checks every verdict
tests/xcode_test.sh              # DerivedData, simulators, archives; stubs xcrun so it runs on Linux
tests/cargo_test.sh              # adjacent target/ dirs, CARGO_TARGET_DIR, cargo clean vs rm
shellcheck scripts/*.sh tests/*.sh
```

Agent worktree paths and their sources are in [`references/agent-locations.md`](references/agent-locations.md). Xcode paths and Cargo target rules are in [`references/xcode-caches.md`](references/xcode-caches.md) and [`references/cargo-targets.md`](references/cargo-targets.md). PRs for more tools are welcome. Please include a link to docs or source.

## License

MIT © 2026 Greg Kopyltsov
