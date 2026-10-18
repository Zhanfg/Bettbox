import 'dart:convert';

import 'package:bett_box/clash/core.dart';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'smart_policy_editor.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A live, read-only view of Smart V11's actual proxy-group snapshots.
/// The only mutation here is releasing an explicit manual pin; tuning the
/// immutable group policy requires editing the profile and reloading it.
class SmartInsightsView extends ConsumerWidget {
  const SmartInsightsView({super.key});

  Future<void> _enableSmart(
    BuildContext context,
    WidgetRef ref,
    Group group,
  ) async {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || group.name == 'GLOBAL') return;
    final nextTypes = Set<String>.from(profile.smartGroupOverrides)
      ..add(group.name);
    final selected = Map<String, String>.from(profile.selectedMap)
      ..remove(group.name);
    ref.read(profilesProvider.notifier).updateProfile(
      profile.id,
      (value) => value.copyWith(
        smartGroupOverrides: nextTypes,
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

  Widget _groupCard(BuildContext context, Group group) {
    final path = group.pathProfile;
    final endToEnd = group.endToEnd;
    final pin = group.fixed ?? '';
    final isPinned = pin.isNotEmpty;
    final lastNode = path?['node'];
    final lastTarget = endToEnd?['target'];
    final country = group.country;
    final routeFresh = endToEnd?['freshNetwork'] == true;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Chip(
                  label: Text(isPinned ? 'Pinned' : 'Automatic'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _field('Manual pin', isPinned ? pin : 'None — Smart chooses per target'),
            _field('Last observed route', _display(lastNode)),
            _field('Last destination', _display(lastTarget)),
            _field(
              'End-to-end sample',
              endToEnd == null
                  ? 'No sample yet'
                  : routeFresh ? 'Current network' : 'Previous network',
            ),
            const Divider(),
            Text('Routing policy', style: Theme.of(context).textTheme.titleSmall),
            _field('Country', (country == null || country.isEmpty) ? 'Any' : country),
            _field('Country affinity', _yesNo(group.countryAffinity)),
            _field('Auto IP family', _yesNo(group.autoIPFamily)),
            _field('Prefer ASN', _yesNo(group.preferASN)),
            _field('Prefer IPv4 / IPv6',
                '${_yesNo(group.preferIPv4)} / ${_yesNo(group.preferIPv6)}'),
            _field('Require IPv4 / IPv6',
                '${_yesNo(group.requireIPv4)} / ${_yesNo(group.requireIPv6)}'),
            _field('Expert weighting', _yesNo(group.useLightGBM)),
            _field('Learning data', _yesNo(group.collectData)),
            _field('Sample rate', _display(group.sampleRate)),
            if (path != null) ...[
              const Divider(),
              Text('Last path observation', style: Theme.of(context).textTheme.titleSmall),
              _field('Tunnel condition', _display(path['tunnelState'])),
              _field('Confidence', _display(path['confidence'])),
              _field('Tunnel RTT (ms)', _display(path['tunnelRTT'])),
              _field('Tunnel loss', _display(path['tunnelLoss'])),
              _field('Egress country', _display(path['egressCountry'])),
              _field('Egress consistency', _display(path['egressConsistent'])),
              _field('UDP available', _display(path['udpAvailable'])),
            ],
            if (endToEnd != null) ...[
              const Divider(),
              Text('Last connection sample', style: Theme.of(context).textTheme.titleSmall),
              _field('Connection (ms)', _display(endToEnd['connectTimeMs'])),
              _field('First response (ms)', _display(endToEnd['firstResponseMs'])),
              _field('Loss ratio', _display(endToEnd['lossRate'])),
              _field('Failed', _display(endToEnd['failed'])),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => _showRankings(context, group.name),
                icon: const Icon(Icons.leaderboard_outlined),
                label: const Text('Real node ranking'),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => SmartPolicyEditor(group: group),
                  );
                },
                icon: const Icon(Icons.tune),
                label: const Text('Edit Smart policy'),
              ),
            ),
            if (isPinned) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () {
                    final controller = globalState.appController;
                    controller.updateCurrentSelectedMap(group.name, '');
                    controller.changeProxyDebounce(group.name, '');
                  },
                  icon: const Icon(Icons.auto_mode),
                  label: const Text('Return to automatic routing'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          title: const Text('Smart V11 diagnostics'),
          subtitle: const Text(
            'Shows actual core snapshots, not simulated scores. '
            'Smart may select a different node for each destination.',
          ),
          trailing: IconButton(
            tooltip: 'Refresh core snapshot',
            icon: const Icon(Icons.refresh),
            onPressed: () => globalState.appController.updateGroupsDebounce(),
          ),
        ),
        if (smartGroups.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No Smart proxy groups in the active profile.'),
          ),
        ...smartGroups.map((group) => _groupCard(context, group)),
        if (candidates.isNotEmpty)
          ExpansionTile(
            title: const Text('Enable Smart for an existing group'),
            subtitle: const Text(
              'Local reversible conversion; original subscription unchanged.',
            ),
            children: candidates.map(
              (group) => ListTile(
                title: Text(group.name),
                subtitle: Text('Currently ${group.type.name}'),
                trailing: OutlinedButton(
                  onPressed: () => _enableSmart(context, ref, group),
                  child: const Text('Enable Smart'),
                ),
              ),
            ).toList(),
          ),
      ],
    );
  }
}
