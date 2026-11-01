import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'ui/layout/home_screen.dart';
import 'ui/providers.dart';
import 'ui/theme/app_theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  try {
    final services = await AppServices.init(args);
    runApp(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: const NoteVibeApp(),
    ));
  } catch (e, st) {
    runApp(_StartupError(error: '$e\n\n$st'));
  }
}

class NoteVibeApp extends ConsumerWidget {
  const NoteVibeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
