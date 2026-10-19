# System (macOS)

System is a menu-bar app that will show where a Mac's CPU, memory, and disk space go, grouped by **origin** rather than as a flat process list: the app a helper belongs to, what launched it, the project a dev server runs in, and the containers inside a Docker-compatible VM. It is a Subset capability in the `planned` state.

This folder holds the app shell ([SET-39](https://linear.app/21n/issue/SET-39)) of the System outcome ([SET-38](https://linear.app/21n/issue/SET-38)) and its process sampling ([SET-40](https://linear.app/21n/issue/SET-40)): a menu-bar app that shows total CPU and memory pressure, a temporary process table in the main window, an empty Settings window, a testable `SystemCore` package, a generated Xcode project, and macOS CI. It does not attribute processes to an origin, scan disks, run cleanups, call AI providers, or ship the agent helper; those are SET-41 through SET-52.

## Capability boundary

**User outcome:** understand which app, tool, project, or container is using CPU, memory, and disk space, and reclaim space safely.

**Sources of truth:**

| Data | Source | Issue |
| --- | --- | --- |
| Processes, CPU, memory | Darwin process APIs on this Mac, sampled in memory (implemented) | SET-40 |
| Origin (app, launcher, project) | Bundle, code-signing, launchd, and process-tree signals | SET-41, SET-42 |
| Containers | The local Docker-compatible CLI | SET-43 |
| Disk usage | The file system, under the user's Full Disk Access choice | SET-45, SET-46 |

Samples and scan results stay in memory; there is no persisted history. All measurement and attribution are deterministic. Optional AI explanations (on-device Apple Intelligence or the user's own OpenRouter key, SET-49 to SET-51) never measure, group authoritatively, or trigger a cleanup.

**Explicit operations**

| Operation | Kind | State |
| --- | --- | --- |
| Open System, Settings…, About Subset System, Quit | App shell | Implemented (SET-39) |
| View total CPU and memory pressure in the menu bar; view a plain process table | Read | Implemented (SET-40); the table is temporary |
| View CPU and memory by origin | Read | Planned (SET-44) |
| View disk usage by origin and reclaimable space | Read | Planned (SET-46, SET-47) |
| Move to Trash or run an allowlisted tool command, after confirmation | Mutation | Planned (SET-48) |
| Explain or ask with AI | Read; sends data only to the provider the user enables | Planned (SET-49 to SET-51) |
| `subset-system` JSON output for agents | Read | Planned (SET-52) |

| Owner | Responsibility |
| --- | --- |
| `Core/` (`SystemCore`) | Domain logic, pure Swift plus Darwin; no AppKit or SwiftUI. It holds the app identity, the status menu's command list, the `ProcessFacts` contract and its sources, the `Sampler`, `SystemMemory`, and the menu-bar summary. |
| `MacApp/` | The menu-bar host: the status item, the sampling loop (`SystemMonitor`), the main and Settings windows, and the About panel. |

No other app, package, or product imports this code.

## Process sampling

`ProcessSource.sample()` reads every visible process once. `LibprocProcessSource` lists PIDs with `proc_listallpids` and reads, per process, `PROC_PIDTBSDINFO` (parent, effective user, start time, name), `proc_pidpath`, and `proc_pid_rusage(RUSAGE_INFO_V6)` (`ri_phys_footprint`, user and system CPU time, `ri_billed_energy`). For another user's process, whose `PROC_PIDTBSDINFO` macOS denies, the start time, parent, owner and name come from `kinfo_proc`. The kernel holds a name in a fixed-width buffer (31 bytes in `pbi_name`, 16 in `p_comm`), so the executable's file name is shown instead when the kernel name is empty or a strict prefix of it; any other kernel name is kept. `FixtureProcessSource` replays recorded samples for tests. Command-line arguments are never read, since they can hold secrets; only the executable path is.

- **Identity** is `(pid, startTime)`, so a PID the kernel reuses is a new process. macOS refuses `PROC_PIDTBSDINFO` for another user's process; the identity, parent and owner then come from the process table (`sysctl` `KERN_PROC_PID`), which is readable for every process.
- **Restricted processes.** Without root, `proc_pid_rusage` fails with `EPERM` for other users' processes (about a quarter of them on the development Mac). They stay in the snapshot with `restricted = true` and `nil` usage values, never zero. Any other read failure also leaves the values `nil`, without `restricted`. A process that exits mid-read is left out. The reads are keyed by PID alone, so the start time is read again after them; if the PID changed hands meanwhile, the process is read once more, and left for the next sample if it changes hands again.
- **Units.** CPU times arrive in Mach absolute time units and are converted with `mach_timebase_info` (125/3 ns per tick on Apple silicon). Memory is the physical footprint, the figure Activity Monitor shows as Memory; energy is nanojoules billed since the process started.
- **CPU %** is the CPU time delta of one identity over the uptime delta between two samples, with 100% meaning one fully used logical core (Activity Monitor's convention). A process's first sample, including a process that reused a PID, has no CPU value; a process that exited is dropped.
- **Machine CPU**, the figure the menu bar shows, is the busy share of all cores between two samples from `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas, which any user may read, so it includes restricted processes that the per-process figures miss. It is unavailable on the first sample, after a failed tick read, and for the one interval in which a 32-bit counter wraps or resets. While sampling fails, the menu bar shows CPU as unavailable rather than the last figure.
- **System memory** (`SystemMemory`): pressure level from `kern.memorystatus_vm_pressure_level` (normal, warning, critical), swap used and total from `vm.swapusage`, physical memory from `hw.memsize`, and app (anonymous minus purgeable), wired, and compressed memory from `host_statistics64(HOST_VM_INFO64)`. A missing or malformed value is `nil`.
- **Cadence.** Every 2 seconds while the main window is visible on screen, every 10 seconds otherwise. A change applies at once, but a sample never starts while another runs or sooner than the new interval after the previous one started. Samples stay in memory; there is no history.

The `ProcessFacts` origin fields (`responsiblePID`, `coalitionID`, `teamID`, `signingID`, `isPlatformBinary`, `launchdLabel`, `workingDirectory`, `tty`) are `nil` until SET-41 fills them. Agreement with Activity Monitor on a real workload is checked in SET-53, not here.

## Surfaces

| Surface | State |
| --- | --- |
| macOS app (`Subset System.app`) | Proposed. Builds unsigned, and the status menu was checked on the development Mac. The SET-40 menu-bar figures and process table have not been checked on screen yet (SET-53). No signed build or download. |
| Agent CLI (`subset-system`, read-only JSON) | Proposed (SET-52). Not built. |

The catalog lists `system` as `planned` with no available surface. Not yet verified: a signed or notarized build, a fresh-Mac launch (SET-59), VoiceOver and keyboard use (SET-58).

## Build and test

Requires macOS 14 or later. The package builds and tests with Command Line Tools or Xcode 26:

```sh
swift test --package-path native/system
swift run --package-path native/system SubsetSystem   # unbundled executable, for quick local runs
```

`System.xcodeproj` is generated by `ProjectGenerator.rb` (xcodeproj 1.27) from the same sources: a static `SystemCore` library, the `Subset System` app (scheme `SubsetSystem`), and the `SystemCoreTests` bundle. Regenerate it after adding or removing a source file; generation is reproducible, and CI fails if the committed project differs. Regenerating replaces only `project.pbxproj` and the shared `SubsetSystem` scheme, so breakpoints, personal schemes and workspace state in `xcuserdata` stay; `Tests/project-generator.sh` checks that. The generator needs exactly xcodeproj 1.27.0:

```sh
gem install --user-install xcodeproj -v 1.27.0
cd native/system
ruby ProjectGenerator.rb
xcodebuild -project System.xcodeproj -scheme SubsetSystem -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build test
```

The app is `LSUIElement` (menu bar only, no Dock icon), runs with the hardened runtime, and has no App Sandbox. `MacApp/SubsetSystem.entitlements` is intentionally empty. There is no network access, privileged helper, or telemetry. `MARKETING_VERSION` is 0.1.0; there is no app icon yet.

`.github/workflows/system.yml` runs on macOS 26 for changes here: package tests, the generated-project check, and an unsigned `xcodebuild build test`. Both test runs include live checks that sample the test process itself and this Mac's memory. `macos-release.json` describes the app for `scripts/release-macos.mjs` (see [docs/macos-release.md](../../docs/macos-release.md)), but System is kept out of beta builds until its signed build is accepted in [SET-59](https://linear.app/21n/issue/SET-59): `scripts/beta-builds.mjs` lists `macos/system` in `betaOptOuts`, so the **Beta builds** workflow never tags or builds it, even when it is named in `only`. SET-59 removes that entry.

## Superfunctions evaluated

Inspected `/Users/ar/dev/superfunctions` (this host's copy of `superfunctions-dev`; branch `next`, commit `9cf3812`) and the npm registry on 2026-10-17. System v0 has no accounts, billing, sync, upload, MCP server, third-party connection, web UI, or telemetry.

| Family | Version checked | Applies | Gap |
| --- | --- | --- | --- |
| authfn | `@authfn/core` 0.1.1, `authfn/swift` | No | No accounts or sessions. The OpenRouter key (SET-50) is the user's own provider key, not an authfn account or session. |
| billfn | `@billfn/core` 0.0.1 on npm; only planning files under `billfn/` on `next` | No | Nothing is sold or licensed. |
| datafn | `@datafn/core` 0.0.3, `datafn/swift` | No | Results stay in memory; nothing is synced or persisted. |
| filefn | `@filefn/server` 0.1.1, `filefn/swift` | No | Local disk scans and Trash moves, no upload or storage adapter. |
| mcpfn | `@mcpfn/core` 0.0.5 on npm; no source on `next` | No | MCP is excluded from SET-38; agents use the read-only `subset-system` helper (SET-52). |
| plugfn | `plugfn` 0.1.0 | No | OpenRouter (SET-50) is a single user-keyed HTTPS call, not a managed third-party connection; SET-50 repeats this check. |
| apifn | `@apifn/core` 0.0.2 | No | No HTTP API is served. |
| uifn | `@uifn/core` 0.0.1 (web components) | No | The UI is AppKit and SwiftUI. |
| observability | `@superfunctions/observability` 0.0.1 on npm; not on `next` | No | No telemetry by owner decision. |

**Package/version used: none.** No Superfunctions code was copied or linked.
