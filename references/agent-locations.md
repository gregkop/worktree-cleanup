# Agent worktree locations: sources

Checked October 2026 against vendor docs or source code. Defaults change; if a tool lets you configure the location, pass your custom folder to the scanner with `--agent-dir PATH`.

| Tool | Default path | Scanned how | Source |
|---|---|---|---|
| Cursor (Agents Window, `/worktree`, `/best-of-n`, CLI `agent --worktree`) | `~/.cursor/worktrees/<repo>/<name>` (fixed, not configurable) | built-in agent dir | https://cursor.com/docs/cli/using#cli-worktrees · https://forum.cursor.com/t/configure-worktree-location/149222 · cleanup settings: https://cursor.com/docs/configuration/worktrees |
| Claude Code (`claude --worktree`, `EnterWorktree`, subagent isolation) | `<repo>/.claude/worktrees/<name>`, branch `worktree-<name>` | via the repo's `git worktree list` | https://code.claude.com/docs/en/worktrees |
| Codex app | `$CODEX_HOME/worktrees` (`CODEX_HOME` defaults to `~/.codex`), e.g. `~/.codex/worktrees/<id>/<repo>`; detached HEAD | built-in agent dir (respects `$CODEX_HOME`) | https://developers.openai.com/codex/app/worktrees · https://learn.chatgpt.com/docs/environments/git-worktrees.md · https://github.com/openai/codex/issues/10599 |
| Conductor | `~/conductor/workspaces/<repo>/<name>` (since 0.25.0, Dec 2025); older repos: `<repo>/.conductor/<name>` | built-in agent dir + repo worktree list | https://www.conductor.build/docs/concepts/git-worktrees · https://www.conductor.build/changelog/0.25.0-workspace-storage-improvements-ai-response-metadata-and-slash-commands |
| Superset | `~/.superset/worktrees/<project>/<branch>` (override per project or globally) | built-in agent dir | source: `apps/desktop/src/lib/trpc/routers/workspaces/utils/resolve-worktree-path.ts` in https://github.com/superset-sh/superset · https://docs.superset.sh/workspaces |
| VS Code (Copilot background agents, Git: Create Worktree) | `<parent>/<repo>.worktrees/<name>` unless a worktree root is configured | via repo worktree list (labelled `vscode?` because it is a naming heuristic) | source: `extensions/git/src/repository.ts` in https://github.com/microsoft/vscode |
| Gemini CLI (experimental, `experimental.worktrees: true`, `gemini --worktree`) | `<repo>/.gemini/worktrees/<name>` | via repo worktree list | https://geminicli.com/docs/cli/git-worktrees/ |
| claude-squad | `~/.claude-squad/worktrees/<branch>_<hex>` (legacy default; newer configs may set a `worktree_pattern`) | built-in agent dir | source: `session/git/worktree.go`, `config/config.go` in https://github.com/smtg-ai/claude-squad |
| Vibe Kanban | macOS `$TMPDIR/vibe-kanban/worktrees`; Linux `/var/tmp/vibe-kanban/worktrees`; custom: `<dir>/.vibe-kanban-workspaces` | built-in agent dir (both temp paths) | https://vibekanban.com/docs/workspaces/managing-workspaces |
| Crystal (deprecated, replaced by Nimbalyst) | `<repo>/worktrees/<name>` by default (configurable) | via repo worktree list | source: `main/src/services/worktreeManager.ts` in https://github.com/stravu/crystal |

## Left out on purpose

- **Vibe Kanban `~/Library/Caches/vibe-kanban/worktrees` (macOS).** Proposed in BloopAI/vibe-kanban PR #3155, which was still open when checked. Not added.
- **Crystal `~/.crystal/worktrees`.** Only mentioned in a third-party summary (DeepWiki). The source code uses `<repo>/worktrees`.
- **Cloud agents** (Cursor Cloud Agents, Codex cloud, GitHub Copilot coding agent, Jules, Devin). They run in remote sandboxes and leave nothing on the local disk.
- **Windsurf, Amp, OpenCode, Aider, Sculptor, Nimbalyst, and others.** No documented default local worktree folder was found. Their worktrees, if any, still show up through the parent repo's `git worktree list` as long as the repo sits under a scanned root.

## Related disk use

Xcode DerivedData, iOS simulators, and Cargo `target/` directories are not worktrees. The same scan reports them separately. See [xcode-caches.md](xcode-caches.md) and [cargo-targets.md](cargo-targets.md).
