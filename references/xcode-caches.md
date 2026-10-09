# Xcode and iOS simulator caches

The scanner reports these only on macOS (`uname` is Darwin). On Linux, and on a Mac without the folders, it prints a skipped line and continues. Tests set `XCODE_SCAN_ENABLE=1` to exercise the same logic on Linux. Nothing in this section is deleted by the scan. `--plan` prints commands and does not run them.

## Paths

| What | Default | Notes |
|---|---|---|
| DerivedData | `~/Library/Developer/Xcode/DerivedData` | Override with `XCODE_DERIVED_DATA`. If that is unset and `defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation` returns a directory, that path is used. |
| Simulators | `~/Library/Developer/CoreSimulator/Devices/<UDID>` | Override the devices root with `XCODE_SIM_DEVICES`. Listed with `xcrun simctl list devices unavailable` when `xcrun` is on PATH. |
| Runtimes | `~/Library/Developer/CoreSimulator/Profiles/Runtimes` and `/Library/Developer/CoreSimulator/Profiles/Runtimes` | Unavailable lines from `xcrun simctl list runtimes`. A matching `.simruntime` bundle is measured when the name is obvious. Report only. |
| iOS DeviceSupport | `~/Library/Developer/Xcode/iOS DeviceSupport` | Override with `XCODE_DEVICE_SUPPORT`. Versions idle for at least `--xcode-stale-days` (default 14) are flagged old. Report only. |
| Archives | `~/Library/Developer/Xcode/Archives` | Override with `XCODE_ARCHIVES`. One total size. Never planned for deletion. |

`WorkspacePath` is read from each DerivedData project's `info.plist` (XML, `plutil` on a binary plist, or the key and path as plain strings). An absolute path that is not on disk means the source project is gone.

## Verdicts

DerivedData, and only DerivedData, depends on whether Xcode is running (`pgrep -x Xcode`, or `XCODE_RUNNING=1` in tests):

| Situation | Xcode quit | Xcode running |
|---|---|---|
| Source project missing | SAFE | REVIEW |
| Untouched for at least `--xcode-stale-days` | SAFE | REVIEW |
| Used more recently, source still present or unknown | REVIEW | REVIEW |

Unavailable simulators are SAFE regardless of Xcode, because removal is `xcrun simctl delete unavailable` and not `rm`. Device directories are never removed by hand.

## Commands the plan may print

```bash
rm -rf '/Users/me/Library/Developer/Xcode/DerivedData/MyApp-abcdef'
xcrun simctl delete unavailable
```

Each `rm` is a direct child of the DerivedData directory. The plan refuses a path that resolves outside that directory. It omits every `rm` while Xcode is running. Archives, DeviceSupport, and runtimes do not appear as commands.
