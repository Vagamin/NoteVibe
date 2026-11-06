import 'package:flutter/material.dart';
import 'dart:ui' show AppExitResponse;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'ui/layout/home_screen.dart';
import 'ui/providers.dart';
import 'ui/theme/app_theme.dart';
import 'ui/cache_service.dart';
import 'dart:async';
import 'data/vault/vault_mode.dart';
import 'ui/settings/vault_unlock.dart';
import 'ui/widgets/vault_save_status.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  try {
    final services = await AppServices.init(args);
    runApp(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: const NoteVibeApp(),
    ));
    unawaited(() async {
      try {
        final last = int.tryParse(services.store.getSetting('cache_last_clean') ?? '') ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        final due = now - last >= const Duration(days: 1).inMilliseconds;
        await (await temporaryCache()).clean(maintenance: due);
        if (due) services.store.setSetting('cache_last_clean', '$now');
      } catch (_) { /* Cache maintenance must never block startup. */ }
    }());
  } on VaultLocked {
    runApp(MaterialApp(title: 'NoteVibe', theme: AppTheme.light(), darkTheme: AppTheme.dark(),
      home: VaultUnlock(args: args, onUnlocked: (services) {
        runApp(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NoteVibeApp()));
      })));
  } catch (e, st) {
    runApp(_StartupError(error: '$e\n\n$st'));
  }
}

Future<void> restartApplication(List<String> args, String? password) async {
  final services = await AppServices.init(args, password);
  runApp(ProviderScope(key: UniqueKey(), overrides: [servicesProvider.overrideWithValue(services)],
    child: const NoteVibeApp()));
}

class NoteVibeApp extends ConsumerStatefulWidget {
  const NoteVibeApp({super.key});
  @override
  ConsumerState<NoteVibeApp> createState() => _NoteVibeAppState();
}

class _NoteVibeAppState extends ConsumerState<NoteVibeApp> {
  bool _locked = false;
  Future<void>? _locking;

  void _lockMobile() {
    final services = ref.read(servicesProvider);
    if (!Platform.isAndroid || services.vault == null || services.transitioning || _locked) return;
    services.mobileLocked = true;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _locked = true);
    _locking = () async {
      await services.sync.stop();
      for (final stop in services.lockHandlers.toList()) { await stop(); }
      await services.flush();
    }();
    unawaited(_locking!.catchError((Object _) {}));
  }
  static const _closeChannel = MethodChannel('notehub/lifecycle');
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _closeChannel.setMethodCallHandler((call) async {
        if (call.method != 'requestClose') return;
        try {
          if (ref.read(servicesProvider).transitioning) throw StateError('Перенос выполняется');
          await ref.read(servicesProvider).close();
          await _closeChannel.invokeMethod<void>('closeReady');
        } catch (_) {
          await _closeChannel.invokeMethod<void>('closeCancelled');
        }
      });
      unawaited(_closeChannel.invokeMethod<void>('enableCloseGuard').catchError((Object _) {}));
    }
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      try {
        if (ref.read(servicesProvider).transitioning) return AppExitResponse.cancel;
        await ref.read(servicesProvider).close();
        return AppExitResponse.exit;
      } catch (_) {
        return AppExitResponse.cancel;
      }
    }, onInactive: () {
      unawaited(ref.read(servicesProvider).flush().catchError((Object _) {}));
    }, onPause: _lockMobile);
  }
  @override
  void dispose() { _lifecycle.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoteVibe',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: const HomeScreen(),
      builder: (context, child) => Stack(children: [Column(children: [
        const VaultSaveStatus(),
        Expanded(child: child ?? const SizedBox.shrink()),
      ]),
        if (_locked) Positioned.fill(child: BlockSemantics(child: VaultUnlock(args: const [],
          lockedServices: ref.read(servicesProvider), pendingLock: _locking, onUnlocked: (_) async {
            try {
              await _locking;
              ref.read(servicesProvider).mobileLocked = false;
              if (mounted) setState(() => _locked = false);
            } catch (_) { /* Keep locked if pending changes could not be saved. */ }
          }))),
      ]),
    );
  }
}

class _StartupError extends StatelessWidget {
  final String error;
  const _StartupError({required this.error});
  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: SelectableText('Не удалось запустить NoteVibe:\n\n$error'),
            ),
          ),
        ),
      );
}
