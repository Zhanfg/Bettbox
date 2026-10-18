import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/clash_config.dart';
import 'package:bett_box/models/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Smart V11 frontend contract', () {
    test('Smart is parsed as a first-class profile group', () {
      expect(GroupType.parseProfileType('smart'), GroupType.Smart);
      expect(GroupType.Smart.isComputedSelected, isTrue);
    });

    test('last observed automatic winner must not be shown as manual pin', () {
      final group = Group.fromJson({
        'name': 'Auto',
        'type': 'Smart',
        'now': 'Smart - Select',
        'all': <Object>[],
        'fixed': '',
        'pathProfile': {'node': 'JP-1', 'tunnelRTT': 38},
      });
      expect(group.type, GroupType.Smart);
      expect(group.pathProfile?['node'], 'JP-1');
      expect(group.getCurrentSelectedName('JP-1'), isEmpty);
    });

    test('core-reported manual pin is reflected in UI', () {
      final group = Group.fromJson({
        'name': 'Auto',
        'type': 'Smart',
        'now': 'US-2',
        'all': <Object>[],
        'fixed': 'US-2',
      });
      expect(group.getCurrentSelectedName(''), 'US-2');
    });

    test('Smart-specific YAML options round-trip through profile model', () {
      final group = ProxyGroup.fromJson({
        'name': 'Smart',
        'type': 'smart',
        'proxies': ['JP-1', 'US-2'],
        'country': 'JP',
        'country-affinity': true,
        'sample-rate': 0.5,
        'prefer-asn': true,
        'auto-ip-family': true,
        'uselightgbm': true,
      });
      expect(group.type, GroupType.Smart);
      expect(group.country, 'JP');
      expect(group.countryAffinity, isTrue);
      expect(group.sampleRate, 0.5);
      expect(group.preferASN, isTrue);
      expect(group.autoIPFamily, isTrue);
      expect(group.useLightGBM, isTrue);
    });
  });
}
