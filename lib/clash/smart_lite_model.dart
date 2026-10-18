import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/common/common.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// An immutable, verified LightGBM baseline bundled into the Windows package.
///
/// Model.bin is the smallest upstream LightGBM model (not a fabricated
/// distilled model). It can be superseded by a user-downloaded model while
/// Model-Lite.bin remains available as an offline recovery source.
class SmartLiteModel {
  static const assetPath = 'assets/data/Model-Lite.bin';
  static const fallbackName = 'Model-Lite.bin';
  static const activeName = 'Model.bin';
  static const expectedBytes = 9345218;
  static const expectedSha256 =
      '23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788';

  static bool _isValidBytes(Uint8List data) =>
      data.length == expectedBytes &&
      sha256.convert(data).toString() == expectedSha256;

  static Future<bool> _isValidFile(File file) async {
    if (!await file.exists()) return false;
    if (await file.length() != expectedBytes) return false;
    final streamHash = await sha256.bind(file.openRead()).first;
    return streamHash.toString() == expectedSha256;
  }

  static Future<void> _writeAtomically(File dest, Uint8List bytes) async {
    await dest.parent.create(recursive: true);
    final temporary = File('${dest.path}.installing');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (!await _isValidFile(temporary)) {
        throw const FormatException('Bundled Lite model verification failed.');
      }
      // Renaming over an existing file is not supported consistently on
      // Windows; only the immutable fallback file is replaceable here.
      if (await dest.exists()) await dest.delete();
      await temporary.rename(dest.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Called before initializing the Smart core. It never overwrites a
  /// user-installed active Model.bin. Network access is never required.
  static Future<void> provision() async {
    if (!system.isWindows) return;
    final asset = await rootBundle.load(assetPath);
    final data = Uint8List.view(
      asset.buffer,
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    if (!_isValidBytes(data)) {
      throw const FormatException(
        'The application package is missing a verified Lite model.',
      );
    }
    final dir = await appPath.homeDirPath;
    final fallback = File(p.join(dir, fallbackName));
    if (!await _isValidFile(fallback)) {
      await _writeAtomically(fallback, data);
    }
    final active = File(p.join(dir, activeName));
    if (!await active.exists()) {
      await _writeAtomically(active, data);
    }
  }

  static Future<SmartLiteModelStatus> status() async {
    final home = await appPath.homeDirPath;
    final active = File(p.join(home, activeName));
    final fallback = File(p.join(home, fallbackName));
    final activeExists = await active.exists();
    return SmartLiteModelStatus(
      activeExists: activeExists,
      activeSize: activeExists ? await active.length() : 0,
      fallbackVerified: await _isValidFile(fallback),
      activeIsLite: await _isValidFile(active),
      activeModified: activeExists ? await active.lastModified() : null,
    );
  }
}

class SmartLiteModelStatus {
  final bool activeExists;
  final int activeSize;
  final bool fallbackVerified;
  final bool activeIsLite;
  final DateTime? activeModified;

  const SmartLiteModelStatus({
    required this.activeExists,
    required this.activeSize,
    required this.fallbackVerified,
    required this.activeIsLite,
    required this.activeModified,
  });
}
