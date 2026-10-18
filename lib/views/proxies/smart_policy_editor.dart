import 'dart:convert';

import 'package:bett_box/clash/core.dart';

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
  final Set<String> _changedFlags = <String>{};
  late Map<String, bool> _initialFlags;
  late String _initialCountry;
  late String _initialSampleRate;
  late String _initialPolicyPriority;

  static const _labels = <String, String>{
    'country-affinity': '优先匹配国家',
    'prefer-asn': '优先 ASN 路由',
    'auto-ip-family': '自动适配 IPv4 / IPv6',
    'prefer-ipv4': '优先 IPv4',
    'require-ipv4': '只允许 IPv4',
    'require-ipv6': '只允许 IPv6',
    'uselightgbm': '使用 Smart 模型评分',
    'collectdata': '保存离线训练样本（增加磁盘写入）',
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
    _initialFlags = Map<String, bool>.from(_flags);
    _initialCountry = _country.text;
    _initialSampleRate = _sampleRate.text;
    _initialPolicyPriority = _policyPriority.text;
  }

  void _setFlag(String key, bool value) {
    setState(() {
      _flags[key] = value;
      if (value == _initialFlags[key]) {
        _changedFlags.remove(key);
      } else {
        _changedFlags.add(key);
      }
    });
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
    if (!reset && _sampleRate.text.trim() != _initialSampleRate.trim() &&
        (sampleRate == null || !sampleRate.isFinite ||
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
      // Preserve the profile/subscription defaults. Writing every switch,
      // including untouched false values, silently disabled upstream features.
      final overrides = Map<String, dynamic>.from(
        proposed[widget.group.name] ?? const <String, dynamic>{},
      );
      if (country != _initialCountry.trim().toUpperCase()) {
        overrides['country'] = country;
      }
      if (_sampleRate.text.trim() != _initialSampleRate.trim()) {
        overrides['sample-rate'] = sampleRate!;
      }
      if (_policyPriority.text.trim() != _initialPolicyPriority.trim()) {
        final priority = _policyPriority.text.trim();
        if (priority.isEmpty) {
          overrides.remove('policy-priority');
        } else {
          overrides['policy-priority'] = priority;
        }
      }
      for (final key in _changedFlags) {
        overrides[key] = _flags[key]!;
      }
      if (overrides.isEmpty) {
        proposed.remove(widget.group.name);
      } else {
        proposed[widget.group.name] = overrides;
      }
    }

    // Opening Preferences and pressing Save without an edit is a no-op.
    // Reloading the entire proxy profile otherwise causes needless churn.
    final didEdit = reset
        ? previous.containsKey(widget.group.name)
        : country != _initialCountry.trim().toUpperCase() ||
            _sampleRate.text.trim() != _initialSampleRate.trim() ||
            _policyPriority.text.trim() != _initialPolicyPriority.trim() ||
            _changedFlags.isNotEmpty;
    if (!didEdit) {
      if (mounted) Navigator.of(context).pop();
      return;
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
      title: Text('智能选路偏好 · ${widget.group.name}'),
      content: SizedBox(
        width: 510,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '长期学习会自动利用真实连接反馈，无需手动开启采集。'
                '此处只调整选路偏好；保留订阅中未修改的设置。',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _country,
                maxLength: 2,
                decoration: const InputDecoration(
                  labelText: '优先国家 / 地区（可选）',
                  hintText: '例如 JP、US；留空表示不指定',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动适配 IPv4 / IPv6'),
                subtitle: const Text('推荐开启，由内核判断可用性'),
                value: _flags['auto-ip-family'] ?? false,
                onChanged: _saving
                    ? null
                    : (value) => _setFlag('auto-ip-family', value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('使用模型辅助选路'),
                subtitle: const Text('需要可用的 LightGBM 模型；不影响普通代理组'),
                value: _flags['uselightgbm'] ?? false,
                onChanged: _saving
                    ? null
                    : (value) => _setFlag('uselightgbm', value),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: false,
                title: const Text('高级参数'),
                subtitle: const Text('ASN、强制 IP 族及样本采集等'),
                children: [
                  TextField(
                    controller: _policyPriority,
                    decoration: const InputDecoration(
                      labelText: '节点优先级表达式',
                      helperText: '留空时采用内核或订阅中的配置',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _sampleRate,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: '样本采集比例',
                      helperText: '仅在开启样本采集时使用，范围 (0, 1]',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  ..._labels.entries
                      .where((item) =>
                          item.key != 'auto-ip-family' &&
                          item.key != 'uselightgbm')
                      .map(
                        (item) => SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(item.value),
                          value: _flags[item.key] ?? false,
                          onChanged: _saving
                              ? null
                              : (value) => _setFlag(item.key, value),
                        ),
                      ),
                ],
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
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在应用…' : '保存'),
        ),
      ],
    );
  }
}
