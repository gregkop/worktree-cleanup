# Cargo target directories

Rust agent worktrees keep a `target/` tree per checkout. The scanner looks for those only inside repos and worktrees it already found. It does not walk the whole disk for a directory named `target`.

## What counts

A directory is reported when all of these hold:

- It is named `target`.
- Its parent contains a `Cargo.toml`.
- It was found under a scanned repo or worktree, at most `--depth` levels down (the worktree scan passes its own depth, default 6). `target/`, `node_modules`, and `.git` are not searched for further manifests.

Size and idle days (newest mtime of the directory and its immediate children) are reported. The directory is **SAFE**: it is regenerable build output. If `pgrep -x cargo` or `pgrep -x rustc` finds a running build, or `CARGO_BUILD_RUNNING=1` in tests, every row is **REVIEW** and the plan is empty.

A `target/` whose parent has no `Cargo.toml` is ignored. The plan will not `rm` it.

## `CARGO_TARGET_DIR`

If `CARGO_TARGET_DIR` is set and the directory exists, that shared directory is the only target reported. Per-project `target/` folders are left out of the totals so the same bytes are not counted twice. Cargo writes there for every project, and one `cargo clean` clears it.

If the variable is set but the directory does not exist, the scanner says so and goes back to per-project `target/` folders.

## Cleanup commands

Prefer cargo when it is on PATH:

```bash
cargo clean --manifest-path '/path/to/Cargo.toml'
```

If `cargo` is not on PATH, the plan removes the directory itself:

```bash
rm -rf '/path/to/target'
```

That `rm` is only for a real directory (not a symlink) named `target` next to a `Cargo.toml`, or for the resolved `CARGO_TARGET_DIR`. A symlink is left alone unless `cargo clean` can be used.

## Report only

These are measured and never put in the plan. `$CARGO_HOME` defaults to `~/.cargo`.

- `$CARGO_HOME/registry/cache`
- `$CARGO_HOME/git/checkouts`

Deleting them is a separate request. This skill does not run it on its own.
