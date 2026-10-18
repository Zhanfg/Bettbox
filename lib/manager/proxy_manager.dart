import 'dart:async';

import 'package:bett_box/common/proxy.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  // The WinINet plugin changes OS-global user settings. Serializing updates
  // avoids a slow StartProxy completing after a newer StopProxy request.
  // Redundant provider emissions should not repeatedly write the registry or
  // broadcast settings-change notifications (especially on laptops).
  ProxyState? _requested;
  ProxyState? _applied;
  bool _running = false;
  bool _ownsProxyInThisSession = false;

  void _schedule(ProxyState next) {
    _requested = next;
    if (!_running) unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (mounted) {
        final desired = _requested;
        if (desired == null) break;
        _requested = null;
        final enabled = desired.isStart && desired.systemProxy;
        final appliedEnabled =
            _applied != null && _applied!.isStart && _applied!.systemProxy;

        // If the OS proxy has never been claimed during this process, do not
        // blindly reset an unrelated Windows manual proxy or PAC on startup.
        if (!enabled && !_ownsProxyInThisSession) {
          _applied = desired;
          continue;
        }

        if (enabled && appliedEnabled &&
            _applied!.port == desired.port &&
            listEquals(_applied!.bypassDomain, desired.bypassDomain)) {
          _applied = desired;
          continue;
        }

        bool ok = false;
        try {
          if (enabled) {
            ok = await proxy?.startProxy(desired.port, desired.bypassDomain) == true;
          } else {
            ok = await proxy?.stopProxy() == true;
          }
        } catch (error) {
          debugPrint('Unable to apply Windows system proxy: $error');
        }
        if (ok) {
          _ownsProxyInThisSession = enabled;
          _applied = desired;
        } else {
          debugPrint('Windows system proxy update failed; state not committed.');
        }
        // While awaiting the OS call, another state may have arrived. Drain
        // only the newest target rather than applying every obsolete state.
      }
    } finally {
      _running = false;
    }
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(proxyStateProvider, (prev, next) {
      if (prev != next) _schedule(next);
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
