import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/core.dart';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'smart_policy_editor.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// This view polls only while it is visible. Smart V11 does not expose
/// Bettbox's legacy push hooks, so polling is needed for truthful snapshots.
class SmartInsightsView extends ConsumerStatefulWidget {
  const SmartInsightsView({super.key});

  @override
  ConsumerState<SmartInsightsView> createState() => _SmartInsightsViewState();
}

class _SmartInsightsViewState extends ConsumerState<SmartInsightsView> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted || !globalState.isInit || !globalState.isStart) return;
      globalState.appController.updateGroupsDebounce();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }


  Future<void> _enableSmart(
    BuildContext context,
    WidgetRef ref,
    Group group,
  ) async {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || group.name == 'GLOBAL') return;
    final nextTypes = Set<String>.from(profile.smartGroupOverrides)
      ..add(group.name);
    final previous = Map<String, String>.from(profile.smartPreviousSelections);
    final originalSelection = profile.selectedMap[group.name];
    if (originalSelection != null) {
      previous[group.name] = originalSelection;
    }
    final selected = Map<String, String>.from(profile.selectedMap)
      ..remove(group.name);
    ref.read(profilesProvider.notifier).updateProfile(
      profile.id,
      (value) => value.copyWith(
        smartGroupOverrides: nextTypes,
        smartPreviousSelections: previous,
        selectedMap: selected,
      ),
    );
    try {
      final raw = await globalState.patchRawConfig(
        patchConfig: ref.read(patchClashConfigProvider),
      );
      final validation = await clashCore.validateConfig(json.encode(raw));
      if (validation.isNotEmpty) {
        throw StateError(validation);
      }
      await globalState.appController.applyProfile(silence: true);
    } catch (e) {
      ref.read(profilesProvider.notifier).updateProfile(
        profile.id,
        (value) => value.copyWith(
          smartGroupOverrides: profile.smartGroupOverrides,
          smartPreviousSelections: profile.smartPreviousSelections,
          selectedMap: profile.selectedMap,
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Smart conversion failed: $e')),
        );
      }
    }
  }

  Future<void> _restoreOriginalGroup(
    BuildContext context,
    WidgetRef ref,
    Group group,
  ) async {
    final profile = ref.read(currentProfileProvider);
    if (profile == null ||
        !profile.smartGroupOverrides.contains(group.name)) return;
    final nextTypes = Set<String>.from(profile.smartGroupOverrides)
      ..remove(group.name);
    final restored = Map<String, String>.from(profile.selectedMap);
    final previous = Map<String, String>.from(profile.smartPreviousSelections);
    final oldSelection = previous.remove(group.name);
    if (oldSelection == null) {
      restored.remove(group.name);
    } else {
      restored[group.name] = oldSelection;
    }
    ref.read(profilesProvider.notifier).updateProfile(
      profile.id,
      (value) => value.copyWith(
        smartGroupOverrides: nextTypes,
        smartPreviousSelections: previous,
        selectedMap: restored,
      ),
    );
    try {
      final config = await globalState.patchRawConfig(
        patchConfig: ref.read(patchClashConfigProvider),
      );
      final validation = await clashCore.validateConfig(json.encode(config));
      if (validation.isNotEmpty) throw StateError(validation);
      await globalState.appController.applyProfile(silence: true);
    } catch (e) {
      ref.read(profilesProvider.notifier).updateProfile(
        profile.id,
        (value) => value.copyWith(
          smartGroupOverrides: profile.smartGroupOverrides,
          smartPreviousSelections: profile.smartPreviousSelections,
          selectedMap: profile.selectedMap,
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Could not restore group: $e')),
        );
      }
    }
  }

  static String _display(dynamic value, {String missing = '—'}) {
    if (value == null) return missing;
    if (value is String && value.isEmpty) return missing;
    if (value is num) {
      if (!value.isFinite) return missing;
      return value.toString();
    }
    return value.toString();
  }

  static String _yesNo(bool? value) {
    if (value == null) return 'Unknown';
    return value ? 'Yes' : 'No';
  }

  Future<void> _showRankings(BuildContext context, String groupName) async {
    try {
      final weights = await clashCore.getSmartRankings(groupName);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Smart rankings · $groupName'),
          content: SizedBox(
            width: 470,
            height: 380,
            child: weights.isEmpty
                ? const Center(child: Text(
                    'No ranking has been learned yet. Generate traffic and retry.',
                  ))
                : ListView.builder(
                    itemCount: weights.length,
                    itemBuilder: (_, index) {
                      final item = weights[index];
                      return ListTile(
                        leading: CircleAvatar(child: Text('${index + 1}')),
                        title: Text(_display(item['Name'])),
                        subtitle: Text(_display(item['Rank'])),
                        trailing: Text(_display(item['Weight'])),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Smart ranking unavailable: $e')),
        );
      }
    }
  }

  Widget _field(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(title)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  // The normal view shows one actionable status line per Smart group.
  // Low-level diagnostics exist, but never occupy the primary workflow.
  Widget _groupCard(BuildContext context, Group group) {
    final pinned = group.fixed?.isNotEmpty == true;
    final profile = ref.watch(currentProfileProvider);
    final converted = profile?.smartGroupOverrides.contains(group.name) ?? false;
    final path = group.pathProfile;
    final endToEnd = group.endToEnd;
    final recentNode = _display(path?['node'], missing: '');
    final description = pinned
        ? '已固定：${group.fixed}'
        : recentNode.isNotEmpty
            ? '自动选择 · 最近使用 $recentNode'
            : '自动选择 · 由内核决定节点';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        key: PageStorageKey('smart-group-${group.name}'),
        leading: const Icon(Icons.auto_awesome_outlined),
        title: Text(group.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(description, maxLines: 1, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          _field('选路状态', pinned ? '手动固定' : '自动'),
          _field('偏好地区', (group.country?.isNotEmpty ?? false) ? group.country! : '不限制'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text('偏好设置'),
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => SmartPolicyEditor(group: group),
                  );
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.leaderboard_outlined),
                label: const Text('节点排名'),
                onPressed: () => _showRankings(context, group.name),
              ),
              if (pinned)
                TextButton.icon(
                  icon: const Icon(Icons.auto_mode),
                  label: const Text('恢复自动选择'),
                  onPressed: () {
                    final controller = globalState.appController;
                    controller.updateCurrentSelectedMap(group.name, '');
                    controller.changeProxyDebounce(group.name, '');
                  },
                ),
              if (converted)
                TextButton.icon(
                  icon: const Icon(Icons.restore),
                  label: const Text('恢复原代理组'),
                  onPressed: () => _restoreOriginalGroup(context, ref, group),
                ),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('详细诊断'),
            subtitle: const Text('仅在排障时查看链路及算法指标'),
            children: [
              _field('最后访问目标', _display(endToEnd?['target'])),
              _field('网络观测', _display(path?['tunnelState'])),
              _field('RTT (ms)', _display(path?['tunnelRTT'])),
              _field('丢包率', _display(path?['tunnelLoss'])),
              _field('置信度', _display(path?['confidence'])),
              _field('出口国家', _display(path?['egressCountry'])),
              _field('ASN 优先', _yesNo(group.preferASN)),
              _field('自动 IP 族', _yesNo(group.autoIPFamily)),
              _field('IPv4 强制 / IPv6 强制',
                  '${_yesNo(group.requireIPv4)} / ${_yesNo(group.requireIPv6)}'),
              _field('模型评分', _yesNo(group.useLightGBM)),
              _field('采样率', _display(group.sampleRate)),
              _field('建立连接 (ms)', _display(endToEnd?['connectTimeMs'])),
              _field('首包响应 (ms)', _display(endToEnd?['firstResponseMs'])),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final allGroups = ref.watch(groupsProvider);
    final smartGroups = allGroups
        .where((group) => group.type == GroupType.Smart)
        .toList();
    final candidates = allGroups
        .where((group) =>
            group.name != 'GLOBAL' &&
            group.type != GroupType.Smart)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ListTile(
          title: const Text('智能选路'),
          subtitle: const Text(
            '默认自动选择合适节点；点击代理组可调整偏好或查看状态。',
          ),
          trailing: IconButton(
            tooltip: '刷新选路状态',
            icon: const Icon(Icons.refresh),
            onPressed: () => globalState.appController.updateGroupsDebounce(),
          ),
        ),
        if (smartGroups.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('当前没有智能代理组。原有代理功能不受影响。'),
          ),
        ...smartGroups.map((group) => _groupCard(context, group)),
        if (candidates.isNotEmpty)
          ExpansionTile(
            title: const Text('高级操作 · 将现有代理组改为智能选路'),
            subtitle: const Text(
              '按需启用，可随时恢复；不会更改原始订阅。',
            ),
            children: candidates.map(
              (group) => ListTile(
                title: Text(group.name),
                subtitle: Text('现有类型：${group.type.name}'),
                trailing: OutlinedButton(
                  onPressed: () => _enableSmart(context, ref, group),
                  child: const Text('启用'),
                ),
              ),
            ).toList(),
          ),
      ],
    );
  }
}
