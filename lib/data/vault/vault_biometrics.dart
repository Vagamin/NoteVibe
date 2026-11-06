import 'dart:io';
import 'package:flutter/services.dart';

class VaultBiometrics {
  static const _channel = MethodChannel('notevibe/update');
  static Future<bool> enabled() async => Platform.isAndroid &&
    (await _channel.invokeMethod<bool>('vaultBioStatus') ?? false);
  static Future<void> enroll(String password) => _channel.invokeMethod<void>('vaultBioEnable', {'password': password});
  static Future<String?> unlock() => _channel.invokeMethod<String>('vaultBioUnlock');
  static Future<void> disable() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('vaultBioDisable');
  }
}
