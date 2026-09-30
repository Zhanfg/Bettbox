import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class SmartCoreLock {
  final String repository;
  final String repositoryFullName;
  final String ref;
  final String commit;
  final String module;
  final String goVersion;
  final String profile;
  final String cacheDir;
  final String wrapperDir;

  const SmartCoreLock({
    required this.repository,
    required this.repositoryFullName,
    required this.ref,
    required this.commit,
    required this.module,
    required this.goVersion,
    required this.profile,
    required this.cacheDir,
    required this.wrapperDir,
  });

  factory SmartCoreLock.fromJson(Map<String, dynamic> json) {
    String requireString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('smart-core.lock.json: missing or invalid "$key"');
      }
      return value.trim();
    }

    final commit = requireString('commit');
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      throw FormatException('smart-core.lock.json: commit must be a full 40-char SHA');
    }

    return SmartCoreLock(
      repository: requireString('repository'),
      repositoryFullName: requireString('repository_full_name'),
      ref: requireString('ref'),
      commit: commit,
      module: requireString('module'),
      goVersion: requireString('go_version'),
      profile: requireString('profile'),
      cacheDir: requireString('cache_dir'),
      wrapperDir: requireString('wrapper_dir'),
    );
  }
}

class SmartCoreSync {
  static String get repositoryRoot => Directory.current.absolute.path;

  static File get lockFile =>
      File(p.join(repositoryRoot, 'smart-core.lock.json'));

  static Future<SmartCoreLock> loadLock() async {
    if (!await lockFile.exists()) {
      throw StateError('Missing smart-core.lock.json at repository root');
    }
    final decoded = json.decode(await lockFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('smart-core.lock.json must contain a JSON object');
    }
    return SmartCoreLock.fromJson(decoded);
  }

  static Future<void> prepare({bool force = false}) async {
    final lock = await loadLock();
    final cacheRoot = Directory(p.join(repositoryRoot, '.smart-core'));
    final sourceDir = Directory(p.join(repositoryRoot, lock.cacheDir));
    final stampFile = File(p.join(cacheRoot.path, 'source.json'));

    await cacheRoot.create(recursive: true);

    final canReuse = !force &&
        await sourceDir.exists() &&
        await Directory(p.join(sourceDir.path, '.git')).exists() &&
        await _isAtLockedCommit(sourceDir, lock.commit);

    if (!canReuse) {
      await _checkoutLockedSource(sourceDir, lock);
    }

    await _verifySource(sourceDir, lock);
    await _prepareModFile(lock);

    final stamp = <String, dynamic>{
      'repository': lock.repositoryFullName,
      'ref': lock.ref,
      'commit': lock.commit,
      'profile': lock.profile,
      'go_version': lock.goVersion,
      'prepared_at_utc': DateTime.now().toUtc().toIso8601String(),
    };
    await stampFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(stamp) + '\n',
      flush: true,
    );

    stdout.writeln(
      'Smart Core ready: ${lock.repositoryFullName}@${lock.commit.substring(0, 12)} '
      '(${lock.profile})',
    );
  }

  static Future<void> check() async {
    final lock = await loadLock();
    final sourceDir = Directory(p.join(repositoryRoot, lock.cacheDir));
    if (!await sourceDir.exists()) {
      throw StateError('Smart Core cache is missing: ${sourceDir.path}');
    }
    if (!await _isAtLockedCommit(sourceDir, lock.commit)) {
      throw StateError('Smart Core cache does not match locked commit ${lock.commit}');
    }
    await _verifySource(sourceDir, lock);

    final modFile = File(p.join(repositoryRoot, lock.wrapperDir, 'smart.mod'));
    if (!await modFile.exists()) {
      throw StateError('Generated smart.mod is missing; run the sync step first');
    }

    final modText = await modFile.readAsString();
    final expectedReplace =
        'replace ${lock.module} => ../${lock.cacheDir.replaceAll('\\\\', '/')}';
    if (!modText.contains(expectedReplace)) {
      throw StateError('smart.mod does not point at the locked Smart Core cache');
    }

    stdout.writeln(
      'Smart Core check passed: ${lock.repositoryFullName}@${lock.commit.substring(0, 12)}',
    );
  }

  static Future<bool> _isAtLockedCommit(
    Directory sourceDir,
    String commit,
  ) async {
    final result = await Process.run(
      'git',
      ['-C', sourceDir.path, 'rev-parse', 'HEAD'],
      runInShell: Platform.isWindows,
    );
    return result.exitCode == 0 && result.stdout.toString().trim() == commit;
  }

  static Future<void> _checkoutLockedSource(
    Directory sourceDir,
    SmartCoreLock lock,
  ) async {
    if (await sourceDir.exists()) {
      await sourceDir.delete(recursive: true);
    }
    await sourceDir.parent.create(recursive: true);

    await _run(
      'git',
      [
        'clone',
        '--filter=blob:none',
        '--no-checkout',
        lock.repository,
        sourceDir.path,
      ],
      label: 'clone Smart Core',
    );

    await _run(
      'git',
      [
        '-C',
        sourceDir.path,
        'fetch',
        '--depth=1',
        'origin',
        lock.commit,
      ],
      label: 'fetch locked Smart Core commit',
    );

    await _run(
      'git',
      [
        '-C',
        sourceDir.path,
        'checkout',
        '--detach',
        lock.commit,
      ],
      label: 'checkout locked Smart Core commit',
    );
  }

  static Future<void> _verifySource(
    Directory sourceDir,
    SmartCoreLock lock,
  ) async {
    final head = await _runCapture(
      'git',
      ['-C', sourceDir.path, 'rev-parse', 'HEAD'],
      label: 'verify Smart Core SHA',
    );
    if (head.trim() != lock.commit) {
      throw StateError(
        'Smart Core SHA mismatch: expected ${lock.commit}, got ${head.trim()}',
      );
    }

    final goMod = File(p.join(sourceDir.path, 'go.mod'));
    if (!await goMod.exists()) {
      throw StateError('Locked Smart Core has no go.mod');
    }
    final goModText = await goMod.readAsString();

    final moduleMatch =
        RegExp(r'^module\s+(.+)$', multiLine: true).firstMatch(goModText);
    final module = moduleMatch?.group(1)?.trim();
    if (module != lock.module) {
      throw StateError(
        'Smart Core module mismatch: expected ${lock.module}, got $module',
      );
    }

    final goMatch =
        RegExp(r'^go\s+([0-9.]+)$', multiLine: true).firstMatch(goModText);
    final goVersion = goMatch?.group(1)?.trim();
    if (goVersion != lock.goVersion) {
      throw StateError(
        'Smart Core Go version mismatch: expected ${lock.goVersion}, got $goVersion',
      );
    }
  }

  static Future<void> _prepareModFile(SmartCoreLock lock) async {
    final wrapper = Directory(p.join(repositoryRoot, lock.wrapperDir));
    final baseMod = File(p.join(wrapper.path, 'go.mod'));
    final baseSum = File(p.join(wrapper.path, 'go.sum'));
    final smartMod = File(p.join(wrapper.path, 'smart.mod'));
    final smartSum = File(p.join(wrapper.path, 'smart.sum'));

    if (!await baseMod.exists()) {
      throw StateError('Bettbox wrapper go.mod is missing: ${baseMod.path}');
    }

    var modText = await baseMod.readAsString();
    final replacePattern = RegExp(
      r'^replace\s+github\.com/metacubex/mihomo\s+=>\s+.+$',
      multiLine: true,
    );
    final replacement =
        'replace ${lock.module} => ../${lock.cacheDir.replaceAll('\\\\', '/')}';

    if (!replacePattern.hasMatch(modText)) {
      throw StateError('Bettbox wrapper go.mod has no Mihomo replace directive');
    }

    modText = modText.replaceFirst(replacePattern, replacement);
    modText = modText.replaceFirst(
      RegExp(r'^go\s+[0-9.]+$', multiLine: true),
      'go ${lock.goVersion}',
    );

    await smartMod.writeAsString(modText, flush: true);

    if (await baseSum.exists()) {
      await baseSum.copy(smartSum.path);
    } else if (await smartSum.exists()) {
      await smartSum.delete();
    }
  }

  static Future<void> _run(
    String executable,
    List<String> arguments, {
    required String label,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        '$label failed\n${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  static Future<String> _runCapture(
    String executable,
    List<String> arguments, {
    required String label,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        '$label failed\n${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
    return result.stdout.toString();
  }
}

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final checkOnly = args.contains('--check');

  if (args.any((arg) => arg != '--force' && arg != '--check')) {
    stderr.writeln('Usage: dart run tool/smart_core.dart [--force] [--check]');
    exitCode = 64;
    return;
  }

  try {
    if (checkOnly) {
      await SmartCoreSync.check();
    } else {
      await SmartCoreSync.prepare(force: force);
    }
  } catch (error, stackTrace) {
    stderr.writeln('Smart Core sync failed: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}
