import 'package:bett_box/clash/smart_learning_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Smart long-term learning integration', () {
    test('converted group opts into bundled model, not raw CSV logging', () {
      final group = <String, dynamic>{
        'name': 'Auto',
        'type': 'url-test',
        'proxies': ['JP-1', 'US-2'],
      };
      final applied = enableSmartLearningForConvertedGroup(group, {'Auto'});
      expect(applied, true);
      expect(group['type'], 'smart');
      expect(group['uselightgbm'], true);
      expect(group.containsKey('collectdata'), false);
      expect(group['proxies'], ['JP-1', 'US-2']);
    });

    test('explicit model opt-out survives local conversion', () {
      final group = <String, dynamic>{
        'name': 'Auto', 'type': 'select', 'uselightgbm': false
      };
      expect(enableSmartLearningForConvertedGroup(group, {'Auto'}), true);
      expect(group['uselightgbm'], false);
    });

    test('non-selected groups and GLOBAL never get changed', () {
      final other = <String, dynamic>{'name':'Other','type':'fallback'};
      final global = <String, dynamic>{'name':'GLOBAL','type':'select'};
      expect(enableSmartLearningForConvertedGroup(other, {'Auto'}), false);
      expect(enableSmartLearningForConvertedGroup(global, {'GLOBAL'}), false);
      expect(other['type'], 'fallback');
      expect(global['type'], 'select');
      expect(other.containsKey('uselightgbm'), false);
    });

    test('native Smart groups keep their own LightGBM policy', () {
      final group = <String, dynamic>{'name':'Custom','type':'smart'};
      expect(enableSmartLearningForConvertedGroup(group, {'Custom'}), false);
      expect(group.containsKey('uselightgbm'), false);
    });

    test('configuration change is idempotent', () {
      final group = <String, dynamic>{'name':'Auto','type':'load-balance'};
      expect(enableSmartLearningForConvertedGroup(group, {'Auto'}), true);
      expect(enableSmartLearningForConvertedGroup(group, {'Auto'}), false);
      expect(group['type'], 'smart');
      expect(group['uselightgbm'], true);
    });
  });
}
