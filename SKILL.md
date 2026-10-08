---
name: worktree-cleanup
description: Find and safely clean up stale git worktrees and related disk bloat left behind by AI coding agents (Cursor, Claude Code, Codex, Conductor, Superset, VS Code, and similar). Use when the user is low on disk space, says their drive is mysteriously full, asks what is eating their disk, mentions lots of git worktrees, or after heavy parallel agent use. Scans read-only, reports size and a SAFE/REVIEW verdict for every worktree, and removes worktrees with `git worktree remove` only after the user explicitly confirms.
license: MIT
compatibility: macOS or Linux with git and bash (3.2+). No network access needed.
metadata:
  author: Greg Kopyltsov
  version: "1.0.0"
---

# Worktree Cleanup

AI coding agents create a git worktree for every parallel task and often leave it on disk. Each one is a full checkout, often with its own `node_modules` or build output, so they can quietly add up to hundreds of GB. Your job is to find them, measure them, sort the ones that are safe to delete from the ones that hold real work, and remove only what the user approves.

## Ground rules (follow every time)

1. **Start with a dry run.** Discovery and measurement are read-only. Change nothing until the user has seen the report.
2. **Get explicit confirmation before removing anything.** The user has to approve the specific list, such as "remove 1-6" or "all SAFE". A general "clean up my disk" is not approval for any one deletion.
3. **Never run `rm -rf` on a worktree.** Use `git worktree remove <path>` without `--force`. Git then refuses to delete a worktree that has modified or untracked files. If git refuses, stop and report it. Do not escalate on your own.
4. **No `--force`, no `git worktree unlock`, no branch deletion** unless the user asks for that action on that exact item, after you have shown what would be lost.
5. **Do not touch remotes without asking.** No push. `git fetch --prune` updates refs and makes "merged/gone" detection more accurate, so offer it, but only run it if the user agrees.
6. **Leave active worktrees alone.** Skip the worktree you are running in, anything locked, and anything touched recently. Ask the user to close agent sessions or IDE windows that use a worktree before you remove it.

## Step 1: Get a baseline

```bash
df -h ~          # free space now, for a before/after comparison
```

## Step 2: Scan (read-only)

Run the bundled scanner from this skill's directory (the folder that contains this SKILL.md; in Claude Code that is `${CLAUDE_SKILL_DIR}`):

```bash
bash <skill-dir>/scripts/scan_worktrees.sh            # searches $HOME + known agent folders
bash <skill-dir>/scripts/scan_worktrees.sh ~/code ~/src --stale-days 14
bash <skill-dir>/scripts/scan_worktrees.sh --json      # machine-readable
bash <skill-dir>/scripts/scan_worktrees.sh --plan      # prints (never runs) removal commands for SAFE rows
```

How the scanner works:
- It finds repos under each ROOT (default `$HOME`, depth 6). It skips `node_modules`, `~/Library`, most dot-folders, and build or dependency dirs.
- It also scans the known agent worktree folders listed below, and any folder you pass with `--agent-dir PATH`.
- For every repo with linked worktrees it reads `git worktree list --porcelain`. For each worktree it reports: path, parent repo, branch, size, idle days, dirty file count, unpushed commits, merged/squash-merged/gone status, locked, prunable, a regenerable-bloat size (`node_modules`, `.venv`, `target`, `build`, ...), and a verdict.
- Use `--no-size` for a fast first pass on very large disks. Sizes come from `du` and are the slowest part.

If the script can't run, do the same checks by hand with the per-repo commands in "Manual fallback" below.

## Where agents put worktrees

| Tool | Default location | Notes |
|---|---|---|
| Cursor (Agents Window, `/worktree`, `agent --worktree`) | `~/.cursor/worktrees/<repo>/<name>` | Fixed path. Cursor 3.5+ auto-trims to `cursor.worktreeMaxCount` (default 25). |
| Claude Code (`claude --worktree`, subagent isolation) | `<repo>/.claude/worktrees/<name>`, branch `worktree-<name>` | Inside the repo. Non-interactive `-p` runs leave theirs behind, locked. |
| Codex app | `$CODEX_HOME/worktrees` (default `~/.codex/worktrees/<id>/<repo>`) | Detached HEAD. Newer builds let you change the root in Settings → Worktrees. |
| Conductor | `~/conductor/workspaces/<repo>/<name>` | Older repos: `<repo>/.conductor/<name>`. |
| Superset | `~/.superset/worktrees/<project>/<branch>` | The base dir can be configured per project or globally. |
| VS Code (Copilot background agents / Git: Create Worktree) | `<parent>/<repo>.worktrees/<name>` | Sibling of the repo, unless a worktree root is configured. |
| Gemini CLI (experimental `--worktree`) | `<repo>/.gemini/worktrees/<name>` | Inside the repo. |
| claude-squad | `~/.claude-squad/worktrees/<name>_<hex>` | Legacy default. Newer configs may use a custom pattern. |
| Vibe Kanban | macOS `$TMPDIR/vibe-kanban/worktrees`, Linux `/var/tmp/vibe-kanban/worktrees` | Custom: `<dir>/.vibe-kanban-workspaces`. |

Locations inside a repo are found through that repo's `git worktree list`. Custom locations: pass `--agent-dir`. Sources, and the tools that were left out, are listed in [references/agent-locations.md](references/agent-locations.md).

## Step 3: Classify

The scanner assigns verdicts as follows. Use the same rules if you are classifying by hand:

**SAFE** (nothing would be lost) when one of these is true:
- **Prunable**: the directory is already gone and only metadata is left (`git worktree prune` clears it).
- **All of these hold**: no modified or untracked files; HEAD merged into the default branch (by ancestry, rebase, or squash patch-id), or every commit already on a remote with the branch deleted upstream or HEAD detached; not locked; idle at least `--stale-days` (default 7).

**REVIEW** (a human decides) for any of these: uncommitted or untracked changes, commits not on any remote and not merged, branch pushed but not merged (open PR?), locked, recently active, it's the current directory, initialized submodules, orphaned (its repo was deleted or moved, so the files may be the only copy), or the scanner couldn't inspect it.

To look closer at a REVIEW item before talking to the user:

```bash
git -C <wt> status --short                       # what's uncommitted
git -C <wt> diff --stat                          # how big the changes are
git -C <wt> log --oneline HEAD --not --remotes   # commits that exist only here
git -C <repo> worktree list                      # what the repo thinks it has
```

## Step 4: Show the user a table and ask

Show both groups with sizes, largest first, and number every row so the user can pick:

```
SAFE (nothing will be lost): 5 worktrees, 41.2 GB
 #  Size     Idle  Tool         Repo     Branch          Why
 1  18.4 GB  31d   cursor       webapp   feat/login      clean, merged
 2  12.0 GB  45d   codex        webapp   (detached)      clean, merged
 ...
REVIEW (has work in it, or still in use): 3 worktrees, 9.8 GB
 7   6.1 GB   2d   claude-code  webapp   worktree-auth   3 uncommitted files, recently active
 8   2.2 GB  60d   conductor    api      feat/billing    4 commits not on any remote
```

Then ask one clear question, for example: *"Remove the 5 SAFE worktrees (41.2 GB)? Reply 'yes', list the numbers to remove, or 'none'. I won't touch REVIEW items unless you tell me what to do with each."* For each REVIEW item, offer options instead of acting: commit and push, keep it, or (if the user explicitly says so) discard it.

## Step 5: Remove, only what was approved

For each approved worktree, run this from its parent repo:

```bash
git -C <repo> worktree remove <worktree-path>    # no --force: refuses if anything is uncommitted
```

Then, once per affected repo:

```bash
git -C <repo> worktree prune                     # drops metadata for deleted dirs
```

- If `git worktree remove` refuses (modified/untracked files, locked, submodules), **stop** and show the user git's message. Do not retry with `--force`.
- `--plan` prints exactly these commands for the SAFE rows. Show them to the user before you run them.
- Removing a worktree does not delete its branch. Delete branches only if the user asks, with `git branch -d <branch>` (lowercase `-d` refuses unmerged branches).
- Ignored files inside a removed worktree are deleted with it: `.env` copies, `node_modules`, build output. Mention this if any `.env` files exist there.
- App-managed workspaces (Conductor, Superset, Vibe Kanban, Cursor's Agents Window) can also be archived or deleted from inside the app, which keeps the app's own list in sync. Vibe Kanban recreates a worktree you deleted by hand the next time that workspace is opened.

Explicit user overrides, one item at a time:
- **Discard a dirty worktree**: first show `git status --short` and any unpushed commits, then `git -C <repo> worktree remove --force <path>`.
- **Locked**: tell the user which tool probably holds the lock (from the path and the lock reason). Unlock only if they confirm that session is gone: `git -C <repo> worktree unlock <path>`.
- **Orphaned dir** (no git metadata): if the repo only moved, `git -C <repo> worktree repair <path>` reconnects it. Otherwise git can't protect it. Show its size and top-level contents, and on explicit approval prefer moving it to the Trash over permanent deletion.

Finally, re-run the scanner and `df -h ~`, and report how much space was freed.

## Step 6: Other agent disk hogs (report only)

Mention these with sizes, but do not delete them unless asked:
- **Regenerable dirs inside kept worktrees** (the scanner's "Regenerable" total): `node_modules`, `.venv`, `target`, `.next`, `build`. Deleting just these frees space and keeps the work.
- **Package manager and build caches** (measure with `du -sh`). If the user wants them gone, suggest the tool's own cleanup command: `~/.npm` (`npm cache clean --force`), pnpm store (`pnpm store prune`), `~/.cache/uv` (`uv cache clean`), `~/.cache/pip` (`pip cache purge`), `~/.cargo/registry`, `~/.gradle/caches`, Xcode `~/Library/Developer/Xcode/DerivedData`, Docker (`docker system df` to inspect; `docker system prune` is destructive).
- **Agent state folders** such as `~/.claude` and `~/.codex` can grow from session transcripts. Report their size only; they hold the user's history.

To prevent a repeat, suggest the tools' own retention settings: Cursor `cursor.worktreeMaxCount` and `cursor.worktreeCleanupIntervalHours`, Claude Code `cleanupPeriodDays`, and archiving finished workspaces in Conductor, Superset, and Vibe Kanban.

## Manual fallback (no script)

```bash
# find repos (skip heavy dirs)
find ~ -maxdepth 6 \( -name node_modules -o -name Library \) -prune -o -name .git -print 2>/dev/null
# per repo
git -C <repo> worktree list --porcelain          # look for "prunable" / "locked"
# per worktree
du -sh <wt>
git -C <wt> status --porcelain                   # empty means clean
git -C <wt> rev-list --count HEAD --not --remotes   # 0 means nothing unpushed
git -C <repo> merge-base --is-ancestor <wt-HEAD> origin/main && echo merged
git -C <repo> for-each-ref --format='%(upstream:track)' refs/heads/<branch>   # [gone] = deleted upstream
```
