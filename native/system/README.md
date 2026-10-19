# System (macOS)

System is a menu-bar app that will show where a Mac's CPU, memory, and disk space go, grouped by **origin** rather than as a flat process list: the app a helper belongs to, what launched it, the project a dev server runs in, and the containers inside a Docker-compatible VM. It is a Subset capability in the `planned` state.

This folder holds the app shell ([SET-39](https://linear.app/21n/issue/SET-39)) of the System outcome ([SET-38](https://linear.app/21n/issue/SET-38)), its process sampling ([SET-40](https://linear.app/21n/issue/SET-40)), and the origin signals read for each process ([SET-41](https://linear.app/21n/issue/SET-41)): a menu-bar app that shows total CPU and memory pressure, a temporary process table in the main window with each process's raw origin signals, an empty Settings window, a testable `SystemCore` package, a generated Xcode project, and macOS CI. It does not group processes by origin, scan disks, run cleanups, call AI providers, or ship the agent helper; those are SET-42 through SET-52.

## Capability boundary

**User outcome:** understand which app, tool, project, or container is using CPU, memory, and disk space, and reclaim space safely.

**Sources of truth:**

| Data | Source | Issue |
| --- | --- | --- |
| Processes, CPU, memory | Darwin process APIs on this Mac, sampled in memory (implemented) | SET-40 |
| Origin signals per process | Responsibility, coalition, code signature, launchd plists, working directory, terminal (implemented) | SET-41 |
| Origin (app, launcher, project) | Grouping rules over those signals, the bundle path, and the parent chain | SET-42 |
| Containers | The local Docker-compatible CLI | SET-43 |
| Disk usage | The file system, under the user's Full Disk Access choice | SET-45, SET-46 |

Samples and scan results stay in memory; there is no persisted history. All measurement and attribution are deterministic. Optional AI explanations (on-device Apple Intelligence or the user's own OpenRouter key, SET-49 to SET-51) never measure, group authoritatively, or trigger a cleanup.

**Explicit operations**

| Operation | Kind | State |
| --- | --- | --- |
| Open System, Settings…, About Subset System, Quit | App shell | Implemented (SET-39) |
| View total CPU and memory pressure in the menu bar; view a plain process table | Read | Implemented (SET-40); the table is temporary |
| View a selected process's raw origin signals and their sources | Read | Implemented (SET-41), in the temporary table's detail pane |
| View CPU and memory by origin | Read | Planned (SET-44) |
| View disk usage by origin and reclaimable space | Read | Planned (SET-46, SET-47) |
| Move to Trash or run an allowlisted tool command, after confirmation | Mutation | Planned (SET-48) |
| Explain or ask with AI | Read; sends data only to the provider the user enables | Planned (SET-49 to SET-51) |
| `subset-system` JSON output for agents | Read | Planned (SET-52) |

| Owner | Responsibility |
| --- | --- |
| `Core/` (`SystemCore`) | Domain logic, pure Swift plus Darwin; no AppKit or SwiftUI. It holds the app identity, the status menu's command list, the `ProcessFacts` contract and its sources, the `Sampler`, `SystemMemory`, the menu-bar summary, and the origin signal readers in `Core/Signals/`. |
| `MacApp/` | The menu-bar host: the status item, the sampling loop (`SystemMonitor`), the main and Settings windows, and the About panel. |

No other app, package, or product imports this code.

## Process sampling

`ProcessSource.sample()` reads every visible process once. `LibprocProcessSource` lists PIDs with `proc_listallpids` and reads, per process, `PROC_PIDTBSDINFO` (parent, effective user, start time, name), `proc_pidpath`, and `proc_pid_rusage(RUSAGE_INFO_V6)` (`ri_phys_footprint`, user and system CPU time, `ri_energy_nj`, `ri_billed_energy`). For another user's process, whose `PROC_PIDTBSDINFO` macOS denies, the start time, parent, owner and name come from `kinfo_proc`. The kernel holds a name in a fixed-width buffer (31 bytes in `pbi_name`, 16 in `p_comm`), so the executable's file name is shown instead when the kernel name is empty or a strict prefix of it; any other kernel name is kept. `FixtureProcessSource` replays recorded samples for tests. Command-line arguments are never read, since they can hold secrets; only the executable path is.

- **Identity** is `(pid, startTime)`, so a PID the kernel reuses is a new process. macOS refuses `PROC_PIDTBSDINFO` for another user's process; the identity, parent and owner then come from the process table (`sysctl` `KERN_PROC_PID`), which is readable for every process.
- **Restricted processes.** Without root, `proc_pid_rusage` fails with `EPERM` for other users' processes (about a quarter of them on the development Mac). They stay in the snapshot with `restricted = true` and `nil` usage values, never zero. Any other read failure also leaves the values `nil`, without `restricted`. A process that exits mid-read is left out. The reads are keyed by PID alone, so the start time is read again after them; if the PID changed hands meanwhile, the process is read once more, and left for the next sample if it changes hands again.
- **Units.** CPU times arrive in Mach absolute time units and are converted with `mach_timebase_info` (125/3 ns per tick on Apple silicon). Memory is the physical footprint, the figure Activity Monitor shows as Memory. Energy (`energy`, from `ri_energy_nj`) is the nanojoules the process's own work has used since it started; the table shows it as Energy Used. `billedEnergy` (`ri_billed_energy`) is a different figure: nanojoules billed to the process for work other processes did on its behalf, usually far below its own energy, so nothing presents it as the process's energy use.
- **CPU %** is the CPU time delta of one identity over the uptime delta between two samples, with 100% meaning one fully used logical core (Activity Monitor's convention). A process's first sample, including a process that reused a PID, has no CPU value; a process that exited is dropped.
- **Machine CPU**, the figure the menu bar shows, is the busy share of all cores between two samples from `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas, which any user may read, so it includes restricted processes that the per-process figures miss. It is unavailable on the first sample, after a failed tick read, and for the one interval in which a 32-bit counter wraps or resets. The menu bar says CPU is not measured yet only before the second sample and unavailable for any later interval without a figure; while sampling fails, it says unavailable rather than showing the last figure.
- **System memory** (`SystemMemory`): pressure level from `kern.memorystatus_vm_pressure_level` (normal, warning, critical), swap used and total from `vm.swapusage`, physical memory from `hw.memsize`, and app (anonymous minus purgeable), wired, and compressed memory from `host_statistics64(HOST_VM_INFO64)`. A missing or malformed value is `nil`.
- **Cadence.** Every 2 seconds while the main window is visible on screen, every 10 seconds otherwise. A change applies at once, but a sample never starts while another runs or sooner than the new interval after the previous one started. Samples stay in memory; there is no history.

Agreement with Activity Monitor on a real workload is checked in SET-53, not here.

## Origin signals

`OriginSignalReader` (`Core/Signals/`) reads the signals macOS gives a non-root user about where a process came from, once per process identity, and stores them in `ProcessFacts.origin`. SET-42 groups processes from them. Each signal is a value or an `unavailable` reason, and names the interface (`SignalSource`) that supplied it either way. The convenience fields `responsiblePID`, `coalitionID`, `teamID`, `signingID`, `isPlatformBinary`, `launchdLabel`, `workingDirectory`, and `tty` are the bare values (`launchdLabel` only when `launchdMatch` identifies a job, below), `nil` when unavailable or not read yet.

| Signal | Reader and source | Without root |
| --- | --- | --- |
| Responsible process | The private `responsibility_get_pid_responsible_for_pid`, resolved with `dlsym` | Own processes only; others are `denied` |
| Coalition ID | The private `PROC_PIDCOALITIONINFO` flavor (20) of `proc_pidinfo`, resolved with `dlsym`; the resource coalition | Every process |
| Code signature: signing identifier, Team ID, Apple platform binary | `SecCodeCopyGuestWithAttributes` by PID, then `SecCodeCopySigningInformation`, published once `SecCodeCheckValidity` (without network access) finds the running code matches the file | Every process; one whose file was replaced since it started (an app updated while it runs) is `unavailable` |
| launchd jobs: label, plist, domain, `orphaned` | An index of `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, and `Contents/Library/LaunchAgents` in each app in `/Applications` and `~/Applications` | Every readable plist; an unreadable plist or an unchecked program is recorded and carried with the jobs found, and a process with no job found then reads `incompleteScan` |
| Working directory | `PROC_PIDVNODEPATHINFO` | Own processes only |
| Controlling terminal | `e_tdev` from `PROC_PIDTBSDINFO`, else from the process table (`sysctl` `KERN_PROC_PID`) | Every process |

- **Private interfaces.** The owner approved the two private interfaces. Each adapter reports `symbolMissing` when its symbol is absent and the call's `errno` (`denied`, `processExited`, or the code) when it fails, so grouping can fall back to the bundle path and parent chain. Neither is linked directly, so a macOS without them still launches.
- **Partial results.** Each reader is independent: a restricted process keeps the signals that succeed (on the development Mac, other users' processes kept their coalition, terminal, and, where the kernel reports an executable path, signature) and records a reason for each that does not.
- **Once per identity and executable.** Results are cached by `(pid, startTime)` and the executable path, and dropped when the process exits. `exec` keeps the PID and start time but replaces the executable (a shell wrapper that runs `exec node server.js`, say), so a process that reappears with another executable path is read again and its signature, launchd jobs, and match follow the new executable. The reads are keyed by PID, so the process is checked afterwards: if the PID changed hands meanwhile, the signals are discarded and recorded as `processExited`; if it now runs another executable, they are discarded and the process stays "not read yet" until the next sample reads its new executable. Reading all of a Mac's processes the first time takes seconds (about 6.7 s for 733 processes on the development Mac, mostly in the Security framework), so one sample reads new identities, oldest first, for at most one second; the rest stay `nil` ("not read yet") until a later sample.
- **Signature cache.** Signatures are cached by executable path, file size, and modification time, plus the status-change time, which the kernel always sets even when an installer preserves an older modification time. The many processes running one executable cost one read, and a rebuilt or updated file is read again. Signatures are read by PID, so a read fills the cache only when it must describe the file as stamped: the process started after the file last changed, the file did not change during the read, and afterwards the PID still belongs to the same process and that process still runs the file (a process that ran `exec` during the read would otherwise file its new executable's signature under the old path). A process started before its file changed may run the replaced version, and one that no longer runs the file when an entry would answer for it is checked first, so either is read directly and neither uses nor fills the entry. The signing information itself comes from the file on disk, so every read is checked against the running code first: a process whose file was replaced (on the development Mac, helpers of an app updated while they ran) reads `unavailable`, not the replacement's identifier and Team ID. Failures are not cached. The cache starts over past 4,096 paths.
- **launchd index.** A job's program is `Program`, which must be an absolute path, else `BundleProgram` (relative to its app bundle), else `ProgramArguments[0]`, which launchd resolves like `execvp` against `/usr/bin:/bin:/usr/sbin:/sbin`. Symlinks are resolved, because the kernel reports a process by its real path (Homebrew services name a symlink). A plist whose program does not exist (`ENOENT`, `ENOTDIR`, `ELOOP`, or not a regular file) is kept as `orphaned`. A program whose path cannot be checked for another reason, such as one under a root-only folder (`EACCES`), is `unchecked`, not orphaned, and is recorded in `scanFailures` with its location and `errno` like an unreadable plist below; for a bare name, only when no `PATH` entry has it and one could not be checked. A plist without a label or program, with a relative `Program`, that does not parse, or that is not a regular file (a folder, FIFO, or device named `.plist`, or a symlink to one; plists are opened without blocking, so a FIFO cannot stall sampling) is listed as unreadable, since launchd cannot load it either. A folder or plist that exists but cannot be read (no read permission, or a plist over 1 MiB, which is not read into memory and is recorded as `EFBIG`; a missing folder is fine) is recorded in `scanFailures` with its `errno`, because launchd, running as root, may still load a job from it: a process whose executable no readable plist names then gets `launchdJobs` `unavailable` with an `incompleteScan` reason naming each failure, not an empty list, and jobs that were found are still returned with the failures in `LaunchdJobs.scanFailures` (the detail view lists them under the jobs). Some Macs have such a plist (the development Mac has a mode 700 root-only one in `/Library/LaunchDaemons`), and there every process without a found job reads as an incomplete scan. Apps are looked for in `/Applications` and `~/Applications` and up to two folder levels below them (`/Applications/Utilities`, a vendor's folder), not inside other bundles and not through symlinked folders. On every sample (about 2.6 ms for 61 jobs on the development Mac), the plists are read again if any plist, plist folder, or application folder appeared, disappeared, changed size, modification time, or status-change time (so a permission fix counts), or could or could no longer be read, and every program is resolved again, so a program that is deleted, created, has its symlink retargeted (as `brew upgrade` does to `/opt/homebrew/opt`), or becomes checkable after a permission fix is followed without a plist change. When the index changes, every process already read looks its executable up again, so a plist added, edited, removed, or made unreadable reaches processes that are already running. Apple's `/System/Library` jobs are not indexed; their programs are platform binaries.
- **launchd match.** A plist names a program, not a process, so `origin.launchdJobs` lists every plist naming the executable and `launchdMatch` says whether they identify the process's own job. It is `job(label:)`, and `launchdLabel` is set, only when the executable is not an Apple platform binary, the parent is launchd (pid 1), every matching plist has the same label, and every plist was read. Otherwise it is `executableOnly` with the first reason that applies: `sharedExecutable` (a platform binary such as `/bin/sh`, `/usr/bin/env`, `/usr/bin/osascript`, or `/usr/bin/sandbox-exec`, which any job or user may run, or a signature that could not be read), `notStartedByLaunchd` (a terminal or app started this copy), `conflictingLabels`, or `incompleteScan` (a plist or program that could not be read may name the executable with another label). So on a Mac with an unreadable plist, such as the development Mac, `launchdLabel` is never set, and SET-42 groups processes from the bundle path and parent chain instead. A process whose parent exited is reparented to launchd too, so `job` is the plists' claim, not launchd's; root-only `launchctl procinfo` would confirm it and is out of scope.
- **Not read:** command-line arguments (they can hold secrets) and root-only sources such as `launchctl procinfo`.

The live tests read the test process's own working directory, terminal state, and code signature, launchd's (pid 1) signature and restricted reads, and record whatever the two private interfaces return. Whether the signals are right for real apps, agents, and dev servers is checked on a working Mac in SET-53.

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
