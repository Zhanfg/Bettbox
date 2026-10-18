# Android handoff after Windows Smart V11 convergence

**This is a handoff, not an Android release.** Do not merge the Windows-only proxy plugin or Rust Windows Helper into Android targets.

## Proven and reusable across platforms

- The app's original Flutter proxy/resource/backup presentation remains the UX contract, with Smart groups as opt-in additions.
- Smart core pin `Zhanfg/mihomo:integration/bettbox-feature-parity`, Go race-tested per-profile learning namespaces, on-disk Bandit/TinyRouter and replaceable validated LightGBM assets.
- Explicit `learning-scope` uses an anonymized profile-derived stable identifier and never changes subscription YAML.
- Online Bandit/TinyRouter updates are independent of the optional `collectdata` offline CSV. No continuous heavyweight retraining or background ML daemon.
- Bundled Lite baseline remains an immutable recovery asset. Middle/Large are optional network downloads.

## Android-specific implementation plan

1. **Compile foundation first:** repair/build Android Flutter Gradle wrapper situation (repository currently has `android/settings.gradle.kts` and `android/core` but no committed `android/gradlew`), verify Kotlin/NDK versions and Go gomobile/JNI ABI. Do not transplant Windows build steps.
2. **VpnService-first rootless mode:** preserve existing Android foreground VPN service & permission UX; improve tunnel lifecycle only after reading actual service bridge. Enforce Android `VpnService.protect()` on upstream sockets to avoid VPN recursion. No root permission by default.
3. **Real IPv4 + IPv6 + DNS behavior:** test both mobile data and Wi-Fi, dual-stack and IPv6-only, captive portals, roaming and network handoffs; ensure UDP/QUIC and standard web traffic remain correct. Do not silently downgrade the user's VPN coverage on failures.
4. **Power management:** use event wakeups, per-session scoring with bounded queues, suspend expensive group maintenance while idle, no polling loops, and explicit app foreground/Doze behavior. Test CPU time, wakelocks, scheduler activity and battery under comparable loads.
5. **Learning DB lifecycle:** Android Smart cache stays in app-private storage. Verify stop/restart, background process death, forced stop and airplane-mode changes. Opt-in private backup should use the same transaction-safe `smart_stats` snapshot; never upload raw targets/ISP metadata to WebDAV without explicit choice.
6. **Model UX:** original native Resources tab lists Lite/Middle/Large import and status. Android first APK must include the validated Lite fallback and verify it exists in the actual final APK. Keep larger downloads on-demand.
7. **Deliverables:** arm64-v8a debug/test APK first with offline Lite, then signed release mechanism using user-controlled keys; running on an actual phone and passing no-route-loop/no-DNS-leak/doze tests is the prerequisite for release.

## Windows signoff gates carried forward

A successful Windows runner means binaries compiled and were packaged. It does not establish real Windows TUN routing, WinINet PAC/restore behavior, throughput, packet loss or power. Keep [PR #1](https://github.com/Zhanfg/Bettbox/pull/1) draft until Windows tests on a real machine validate these before calling desktop 'finished'.

## Compatibility caveat

The `Model-Lite.bin`/Middle/Large presets are LightGBM weight files requiring Smart's exact 30-feature schema. A larger or differently structured neural model requires a separately designed inference backend; the Android UI must not claim arbitrary GGUF/model support.
