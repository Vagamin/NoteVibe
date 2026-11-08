import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_version.dart';
import '../../update/update_service.dart';

enum _Phase { idle, checking, upToDate, available, downloading, failed }

/// "Проверить обновления" block for the settings screen. Works on Android and Windows.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> with WidgetsBindingObserver {
  Completer<void>? _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground?.complete();
      _foreground = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _foreground?.complete();
    _foreground = null;
    super.dispose();
  }

  Future<void> _waitForForeground() async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    _foreground ??= Completer<void>();
    await _foreground!.future;
  }
  _Phase _phase = _Phase.idle;
  Release? _release;
  ReleaseAsset? _asset;
  double _progress = 0;
  String? _error;

  bool get _supported => Platform.isAndroid || Platform.isWindows;

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
    });
    try {
      final r = await UpdateService.fetchLatest();
      final abi = Platform.isAndroid ? await UpdateService.androidAbi() : '';
      final asset = UpdateService.pickAsset(r, abi: abi);
      if (!mounted) return;
      final newer = UpdateService.isNewer(r.version, appVersion);
      setState(() {
        _release = r;
        _asset = asset;
        _phase = !newer
            ? _Phase.upToDate
            : asset == null
                ? _Phase.failed
                : _Phase.available;
        if (newer && asset == null) _error = 'В релизе ${r.version} нет файла для этой платформы.';
      });
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = 'Не удалось проверить обновления: $e';
        });
      }
    }
  }

  Future<void> _install() async {
    if (_asset == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _error = null;
    });
    try {
      // Recheck at install time: the settings page may have stayed open while
      // newer releases were published. Updates are full packages, not patches.
      final latest = await UpdateService.fetchLatest();
      final abi = Platform.isAndroid ? await UpdateService.androidAbi() : '';
      final asset = UpdateService.pickAsset(latest, abi: abi);
      if (asset == null) throw const UpdateException('Нет файла обновления для этого устройства.');
      _release = latest;
      _asset = asset;
      if (Platform.isAndroid) {
        if (!await UpdateService.canInstallApks()) {
          if (!mounted) return;
          await _askInstallPermission();
          setState(() => _phase = _Phase.available);
          return;
        }
        final dir = await UpdateService.downloadDir();
        final file = await UpdateService.download(asset, dir, _onProgress);
        if (!mounted) return;
        await _waitForForeground();
        if (!mounted) return;
        await UpdateService.installApk(file);
        if (mounted) {
          setState(() => _phase = _Phase.available);
        }
      } else {
        final launcher = UpdateService.windowsLauncherPath();
        final file = await UpdateService.download(
          asset,
          await UpdateService.downloadDir(),
          _onProgress,
        );
        if (launcher == null) {
        if (mounted) {
          setState(() {
            _phase = _Phase.available;
            _error = 'Файл скачан в ${file.path}. Запустите его вместо текущей версии.';
          });
        }
          return;
        }
        final updatedLauncher = await UpdateService.replaceWindowsLauncher(file, launcher);
        await UpdateService.launchWindows(updatedLauncher);
        exit(0);
      }
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = 'Ошибка установки: $e';
        });
      }
    }
  }

  void _onProgress(double v) {
    if (mounted) {
      setState(() => _progress = v.clamp(0, 1));
    }
  }

  Future<void> _askInstallPermission() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Разрешите установку'),
        content: const Text(
          'Чтобы установить обновление, разрешите NoteVibe устанавливать приложения. '
          'Откроется системная настройка: включите переключатель и вернитесь в приложение.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Открыть настройки')),
        ],
      ),
    );
    if (go == true) await UpdateService.openInstallSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _phase == _Phase.checking || _phase == _Phase.downloading;

    final String status = switch (_phase) {
      _Phase.idle => 'Текущая версия $appVersion',
      _Phase.checking => 'Проверяем GitHub…',
      _Phase.upToDate => 'Установлена последняя версия ($appVersion)',
      _Phase.available => 'Доступна версия ${_release?.version}',
      _Phase.downloading => 'Загрузка ${_asset?.name} · ${(_progress * 100).round()}%',
      _Phase.failed => _error ?? 'Ошибка',
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          SizedBox(width: 24, child: Icon(Icons.system_update_alt, size: 22, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(child: Text(status, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600))),
        ]),
        if (_phase == _Phase.downloading) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _progress > 0 ? _progress : null),
        ],
        if (_phase == _Phase.available && _release != null && _release!.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_release!.notes.trim(), style: theme.textTheme.bodySmall, maxLines: 8, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!_supported)
              Text('Автообновление доступно на Android и Windows.', style: theme.textTheme.bodySmall)
            else if (_phase == _Phase.available)
              FilledButton.icon(
                onPressed: busy ? null : _install,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Установить', maxLines: 1, softWrap: false),
              )
            else
               OutlinedButton.icon(
                onPressed: busy ? null : _check,
                icon: const Icon(Icons.refresh),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Проверить обновления', maxLines: 1, softWrap: false),
                ),
              ),
            if (_release != null && _phase == _Phase.available)
              TextButton(onPressed: () => openUrl(_release!.pageUrl), child: const Text('Что нового')),
          ],
        ),
      ],
    ),
      ),
    );
  }
}

/// Opens a link in the system browser.
Future<void> openUrl(String url) => UpdateService.openUrl(url);
