import 'package:bett_box/clash/smart_lite_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Smart replaceable model catalog', () {
    test('bundled Lite remains independent from the active model', () {
      expect(SmartLiteModel.fallbackName, 'Model-Lite.bin');
      expect(SmartLiteModel.activeName, 'Model.bin');
      expect(SmartLiteModel.assetPath, 'assets/data/Model-Lite.bin');
    });

    test('pinned preset sizes increase without increasing bundled fallback', () {
      expect(SmartLiteModel.expectedBytes, 9345218);
      expect(SmartLiteModel.middleBytes, greaterThan(SmartLiteModel.expectedBytes));
      expect(SmartLiteModel.largeBytes, greaterThan(SmartLiteModel.middleBytes));
      expect(SmartLiteModel.expectedSha256.length, 64);
      expect(SmartLiteModel.middleSha256.length, 64);
      expect(SmartLiteModel.largeSha256.length, 64);
      expect(SmartLiteModel.expectedSha256, isNot(SmartLiteModel.middleSha256));
      expect(SmartLiteModel.middleSha256, isNot(SmartLiteModel.largeSha256));
    });
  });
}
