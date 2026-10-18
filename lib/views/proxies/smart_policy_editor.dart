import 'dart:convert';

import 'package:bett_box/models/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Applies Smart group settings as profile-local overrides, never rewriting
/// remote subscription YAML. Changes are validated by the real Go core.
class SmartPolicyEditor extends ConsumerStatefulWidget {
  final Group group;
  const SmartPolicyEditor({super.key, required this.group});

  @override
  ConsumerState<SmartPolicyEditor> createState() => _SmartPolicyEditorState();
}

class _SmartPolicyEditorState extends ConsumerState<SmartPolicyEditor> {
  late final TextEditingController _country;
  late final TextEditingController _sampleRate;
  late final TextEditingController _policyPriority;
  late final Map<String, bool> _flags;
  bool _saving = false;
  String? _error;

  static const _labels = <String, String>{
    'country-affinity': 'Country affinity (soft preference)',
    'prefer-asn': 'Group destinations by ASN',
    'auto-ip-family': 'Adapt to IPv4 / IPv6 availability',
    'prefer-ipv4': 'Prefer IPv4',
    'require-ipv4': 'Require IPv4',
    'require-ipv6': 'Require IPv6',
    'uselightgbm': 'Enable expert weight model',
    'collectdata': 'Collect Smart training statistics',
  };

  @override
  void initState() {
    super.initState();
    final current = ref.read(currentProfileProvider);
    final saved = current?.smartPolicies[widget.group.name] ?? const <String, dynamic>{};
    final group = widget.group;
    _country = TextEditingController(
      text: (saved['country'] ?? group.country ?? '').toString(),
    );
    _sampleRate = TextEditingController(
      text: (saved['sample-rate'] ?? group.sampleRate ?? 1.0).toString(),
    );
    _policyPriority = TextEditingController(
      text: (saved['policy-priority'] ?? group.policyPriority ?? '').toString(),
    );
    final base = <String, bool?>{
      'country-affinity': group.countryAffinity,
      'prefer-asn': group.preferASN,
      'auto-ip-family': group.autoIPFamily,
      'prefer-ipv4': group.preferIPv4,
      'require-ipv4': group.requireIPv4,
      'require-ipv6': group.requireIPv6,
      'uselightgbm': group.useLightGBM,
      'collectdata': group.collectData,
    };
    _flags = {
      for (final key in _labels.keys)
        key: (saved[key] as bool?) ?? base[key] ?? false,
    };
  }

  @override
  void dispose() {
    _country.dispose();
    _sampleRate.dispose();
    _policyPriority.dispose();
    super.dispose();
  }

  Future<void> _save({bool reset = false}) async {
    if (_saving) return;
    final profile = ref.read(currentProfileProvider);
    if (profile == null) {
      setState(() => _error = 'Select a profile first.');
      return;
    }

    final country = _country.text.trim().toUpperCase();
    final sampleRate = double.tryParse(_sampleRate.text.trim());
    if (!reset && country.isNotEmpty &&
        !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      setState(() => _error = 'Country must be a two-letter ISO code.');
      return;
    }
    if (!reset && (sampleRate == null || !sampleRate.isFinite ||
        sampleRate <= 0 || sampleRate > 1)) {
      setState(() => _error = 'Sample rate must be in (0, 1].');
      return;
    }
    if (!reset && _flags['require-ipv4'] == true &&
        _flags['require-ipv6'] == true) {
      setState(() => _error = 'Cannot require IPv4 and IPv6 simultaneously.');
      return;
    }

    final previous = Map<String, Map<String, dynamic>>.from(profile.smartPolicies);
    final proposed = Map<String, Map<String, dynamic>>.from(previous);
    if (reset) {
      proposed.remove(widget.group.name);
    } else {
      proposed[widget.group.name] = {
        'country': country,
        'sample-rate': sampleRate!,
        'policy-priority': _policyPriority.text.trim(),
        ..._flags,
      };
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      ref.read(profilesProvider.notifier).updateProfile(
        profile.id,
        (value) => value.copyWith(smartPolicies: proposed),
      );
      final raw = await globalState.patchRawConfig(
        patchConfig: ref.read(patchClashConfigProvider),
      );
      final configForValidation = Map<String, dynamic>.from(raw);
      if (configForValidation.containsKey('rule')) {
        configForValidation['rules'] = configForValidation.remove('rule');
      }
      final validation = await clashCore.validateConfig(json.encode(configForValidation));
      if (validation.isNotEmpty) {
        throw StateError('Smart policy rejected by core: $validation');
      }
      await globalState.appController.applyProfile(silence: true);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      ref.read(profilesProvider.notifier).updateProfile(
        profile.id,
        (value) => value.copyWith(smartPolicies: previous),
      );
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Smart policy · ${widget.group.name}'),
      content: SizedBox(
        width: 510,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These preferences override only this Smart group in the '
                'active profile. The original subscription is unchanged.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _country,
                maxLength: 2,
                decoration: const InputDecoration(
                  labelText: 'Preferred country (ISO 3166-1 alpha-2)',
                  hintText: 'e.g. JP, US; blank = any',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sampleRate,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Learning sample rate',
                  helperText: '0 < rate ≤ 1',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _policyPriority,
                decoration: const InputDecoration(
                  labelText: 'Advanced policy priority',
                  helperText: 'Leave blank for the core default',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              ..._labels.entries.map(
                (item) => SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.value),
                  value: _flags[item.key] ?? false,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _flags[item.key] = value),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => _save(reset: true),
          child: const Text('Reset overrides'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Applying…' : 'Save and reload core'),
        ),
      ],
    );
  }
}
