import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/llm.dart';
import '../core/models.dart';
import '../core/playback.dart';

// ─────────────────────────────── Secure store (LOS-10) ───────────────────────────────

enum SecretKey {
  claudeAPIKey('api.claude'),
  geminiAPIKey('api.gemini'),
  spotifyRefreshToken('spotify.refresh');

  final String raw;
  const SecretKey(this.raw);

  static SecretKey? apiKeyFor(EngineKind e) => switch (e) {
        EngineKind.onDevice => null,
        EngineKind.claude => SecretKey.claudeAPIKey,
        EngineKind.gemini => SecretKey.geminiAPIKey,
      };
}

/// Keychain on iOS, Android Keystore-backed encrypted storage on Android.
/// Values are mirrored in memory so the UI can read them synchronously.
class SecureStore {
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  final _cache = <SecretKey, String>{};

  Future<void> load() async {
    for (final k in SecretKey.values) {
      try {
        final v = await _storage.read(key: k.raw);
        if (v != null) _cache[k] = v;
      } catch (_) {}
    }
  }

  String? value(SecretKey k) => _cache[k];

  Future<void> set(String value, SecretKey k) async {
    await _storage.write(key: k.raw, value: value);
    _cache[k] = value;
  }

  Future<void> delete(SecretKey k) async {
    _cache.remove(k);
    try {
      await _storage.delete(key: k.raw);
    } catch (_) {}
  }

  /// "Delete all" removes every secret explicitly — Keychain items can survive an uninstall (PR-10).
  Future<void> deleteAll() async {
    for (final k in SecretKey.values) {
      await delete(k);
    }
  }
}

/// Masks a key for display after saving (RQ-14): "sk-ant-…a1b2".
String maskSecret(String s) => s.length <= 8 ? '•' * s.length : '${s.substring(0, 6)}…${s.substring(s.length - 4)}';

// ─────────────────────────────── Engines (Win-AGRE-4) ───────────────────────────────

/// Downloads, verifies (SHA-256), and deletes the GGUF model (PR-9).
class ModelManager {
  static const modelName = 'gemma-2b-it';
  static const expectedSHA256 = 'TBD-after-S1';
  static const approximateBytes = 1600000000;
  static late Directory baseDir;

  static File get modelFile => File('${baseDir.path}/Models/$modelName.gguf');
  static bool get isInstalled => modelFile.existsSync();
  static int get modelBytes => isInstalled ? modelFile.lengthSync() : 0;

  /// Prototype download: reports progress for ~4 s, then writes a small marker file in place of
  /// the GGUF so the installed state, storage meter and delete button can be tested.
  static Future<void> download(void Function(double) progress) async {
    for (var step = 1; step <= 20; step++) {
      await Future.delayed(const Duration(milliseconds: 200));
      progress(step / 20);
    }
    modelFile.parent.createSync(recursive: true);
    modelFile.writeAsStringSync('prototype-model-placeholder', flush: true);
  }

  static void deleteModel() {
    try {
      if (modelFile.existsSync()) modelFile.deleteSync();
    } catch (_) {}
  }
}

/// Placeholder for the llama.cpp engine (SIR-8). Integration (llama.cpp via FFI on both
/// platforms, Gemma 2B Q4 GGUF) lands after spike S1. Until then it delegates to the demo engine.
class LlamaEngine extends DemoEngine {
  const LlamaEngine();
  @override
  String get id => 'llama:${ModelManager.modelName}@q4';
  @override
  bool get isAvailable => ModelManager.isInstalled;
}

class EngineFactory {
  static TranslationEngine make(EngineKind kind, String? apiKey) => switch (kind) {
        EngineKind.claude => ClaudeEngine(apiKey ?? ''),
        EngineKind.gemini => GeminiEngine(apiKey ?? ''),
        EngineKind.onDevice => ModelManager.isInstalled ? const LlamaEngine() : const DemoEngine(),
      };

  /// The engine currently answering for a choice, for the badge (SIR-3).
  static String label(EngineKind kind) {
    if (kind != EngineKind.onDevice) return kind.badgeLabel;
    return ModelManager.isInstalled ? 'On-device · Gemma' : 'On-device · Demo';
  }
}

// ─────────────────────────────── Music sources ───────────────────────────────

/// Spotify App Remote (SIR-5) and Apple Music (SIR-6) adapters are not wired in this build:
/// the Spotify SDK is a separately downloaded binary that needs a registered client ID.
/// Until then both connect to a mock link that "plays" the given track on a timer, so the
/// now-playing bar, synced lyrics and transport all work on Android and iOS alike.
class MockMusicLink {
  static SimulatedSource make(SourceID id, TrackKey track) => SimulatedSource(track, id: id)..load(track);
}

// ─────────────────────────────── Covers (RQ-6) ───────────────────────────────

class CoverStore {
  static late Directory dir;

  /// Copies the picked (already downscaled to ≤1024 px) image into app storage.
  static String? save(String sourcePath, String songID) {
    try {
      dir.createSync(recursive: true);
      final name = '$songID.jpg';
      File(sourcePath).copySync('${dir.path}/$name');
      return name;
    } catch (_) {
      return null;
    }
  }

  static File file(String path) => File('${dir.path}/$path');

  static void delete(String path) {
    try {
      file(path).deleteSync();
    } catch (_) {}
  }
}

// ─────────────────────────────── Storage meter / haptics ───────────────────────────────

class StorageMeter {
  static int bytes(Directory d) {
    var total = 0;
    if (!d.existsSync()) return 0;
    for (final f in d.listSync(recursive: true)) {
      if (f is File) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  }

  static String format(int bytes) {
    if (bytes < 1000) return '$bytes bytes';
    const units = ['KB', 'MB', 'GB'];
    var v = bytes / 1000;
    var u = 0;
    while (v >= 1000 && u < units.length - 1) {
      v /= 1000;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
  }
}

class Haptics {
  static void light() => HapticFeedback.lightImpact();
  static void success() => HapticFeedback.mediumImpact();
}
