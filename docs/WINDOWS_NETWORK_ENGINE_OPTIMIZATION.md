# Windows network-mode optimization — Bettbox original UX + Smart V11

## Goal & architecture rule

Keep the original Bettbox Windows UI. No new performance-mode switch, driver replacement, or background polling daemon by default. Optimize two explicitly chosen modes **independently**, and keep their operating-system side effects transactional.

- **System proxy**: proxy-aware applications -> Windows WinINet per-user proxy -> local mixed-port listener -> Smart V11 outbound groups. No TUN or route takeover required.
- **TUN**: traffic accepted by Windows virtual network adapter -> compatible sing-tun engine -> Mihomo Smart -> outbound routing. Windows HelperService manages privileged operations. An app's proxy awareness is not a prerequisite.
- A user who explicitly needs both can retain that combination; first ensure the TUN route correctly exempts the local proxy listener and outgoing socket path, and verify it does not recapture itself. Never silently switch TUN to system proxy on error: this may reduce coverage and violate user expectations.

## Audited issues, ordered by risk

### P0 — reliability and idle power (start here)

1. **Serial proxy state operations:** `lib/manager/proxy_manager.dart` previously fired unawaited `startProxy/stopProxy` on every state change. This branch now coalesces rapid state changes, waits for OS operations, avoids rewriting unchanged values, and does not erase another program's proxy settings at app startup.
2. **Transactional Windows proxy restoration:** `plugins/proxy/windows/proxy_plugin.cpp` currently writes WinINet direct/proxy/bypass flags and in StopProxy unconditionally writes `PROXY_TYPE_DIRECT`. It does not snapshot original WinINet settings or user-configured PAC/auto-detect and ignores several API failures. **Not fixed yet.** Native fix must snapshot flags, proxy address, bypass, and PAC per LAN/RAS connection; adopt changes only after snapshot; at stop restore only if the active system proxy is still the one applied by Bettbox. Maintain a minimal ownership journal and recovery path for crash/restart (guarded by a match of expected proxy, never overwrite settings changed by the user/another app).
3. **TUN/DNS/route transaction and rollback:** do not tear down an otherwise healthy TUN on every control-plane config change. Classify deltas into: (i) node/rule/LightGBM/policy hot update, (ii) DNS change, (iii) route/MTU/virtual-interface change requiring a controlled refresh. Snapshot owned routes, DNS and interface state; rollback only owned entries after failure. Abort rather than silently drop down to system proxy on TUN failure.
4. **Network-change recovery:** register Windows IP interface/route/address change events (e.g. `NotifyIpInterfaceChange`) and coalesce bursts. Re-evaluate egress interface and DNS only for real changes, without periodic full interface scans. On sleep/resume, invalidate stale route/endpoint health probes and recover only affected state. No repeated admin prompts.
5. **Avoid extra work while idle:** maintain sockets and drivers using blocking/event-driven waits, not permanent busy polling. Avoid performing Smart model inference on every packet: retain V11 on-demand, cached destination decisions. Background health checks and resource refreshes should use activity-aware intervals and jitter.

### P1 — profile and data-plane performance

6. **Choose MTU from measurements, not a universal 9000-byte value.** Current `Tun` default is 9000. Benchmarks must include path MTU, UDP/QUIC and VPN stacking; offer a conservative compatible preset based on observed network and driver capabilities. Don't silently assume all networks support jumbo frames; do not lower MTU without QA.
7. **TUN stack and ring behavior:** keep sing-tun/Wintun event-driven receive. Compare native stack alternatives only with a pinned compatible version; upstream sing-box 1.15+ changed stack semantics, so importing its names/config blindly can break our Mihomo ABI. Test throughput, cycles per MB, idle wakeups, ring occupancy, packet drops, latency P50/P95/P99 and RAM.
8. **Reduce copies and allocations selectively:** profile Go heap allocations, connection tracking, DNS parser, UDP session churn and Flutter IPC. Keep control-plane callbacks batched or queue bounded. Do not introduce lock-free or polling changes without representative Windows tracing.
9. **Mixed proxy listener:** reuse the same local listener during profile and model switches when port/protocol settings are unchanged. Debounce OS proxy notifications. HTTP keep-alive, DNS caches and Smart destination state must not be forcibly reset on every UI update.

## Suggested state machine

Each mode has **Off -> Preparing -> Running -> Recovering -> Stopping -> Off**, with **Failed** (including OS privilege denied) as an explicit state.
- Idempotent commands: generation ID prevents stale on/off operations applying after a newer request.
- Health checks evaluate the *actual* core listener, route and DNS status instead of trusting a Flutter boolean.
- Recoverable failures apply bounded exponential backoff with jitter; permanent permission errors stop retrying and show a single actionable message.
- All mutations are reversible and scoped to the OS settings owned by Bettbox.
- TUN leak policy remains explicit; never silently substitute narrower proxy coverage.

## Windows QA and benchmarks

Run both modes separately and together on Windows 10/11 x64, Wi-Fi and Ethernet; test laptop battery and AC when possible. Establish baseline with the same server and traffic before applying algorithm changes.

| Workload | Correctness gate | Efficiency metrics |
|---|---|---|
| Cold start and stop, 50 repetitions | OS proxy/PAC, routes, DNS restored exactly; no ghost adapter | activation time P95, CPU-seconds/start |
| Idle 30–60 min | no unexpected polling, leaked sockets or repeated registry changes | process CPU time, context switches, wakeups, private bytes, battery power |
| HTTP/HTTPS/QUIC, TCP/UDP, small/large payload | request completion and no loopback recursion | throughput, CPU cycles/GB, loss and P99 latency |
| 100 rapid profile/node changes | last user request wins, no concurrent OS proxy mutation | dropped sessions, config-apply count, memory |
| 20 disconnect/reconnect & sleep/resume transitions | no orphan routes/DNS/proxy; recovery without restart | recovery P50/P95, duplicate interface events |
| privilege denial, missing Wintun/Helper, high load | correct error and rollback; no silent coverage downgrade | retry count and idle overhead |

Success metrics should be **improvements vs measured baseline**, not invented targets. Treat 0 leaked owned resources, 0 unexpected proxy rewrites and 0 unintended fallback as hard correctness gates. Track launch and throughput regression bounds before selecting any performance default.

## UX

Retain Bettbox's original proxy/network settings. Main view: **系统代理 / TUN** with a simple run-state description and normal existing switch. A single advanced diagnostics sheet holds MTU, stack, DNS/route details and recovery errors. No new model-specific network toggle; Smart runs underneath either mode.

## Current scope

- Implemented on branch: **Flutter system-proxy operation serialization, latest-state coalescing, duplicate write elimination, and avoiding unsafe first-start StopProxy**.
- Not yet implemented or proven on Windows: original proxy restoration/journal, route/DNS transactional reconfigure, event-based Windows network recovery, dynamic MTU tuning, packet-path optimizations, real hardware power and throughput benchmarks.
- Do not mark this optimization plan as a Windows performance release until the original Bettbox feature parity and network-mode QA gates pass.
