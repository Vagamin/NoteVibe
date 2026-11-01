import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app_version.dart';
import '../../sync/discovery/lan_discovery.dart';
import '../../sync/pairing/pairing.dart';
import '../../sync/sync_service.dart';
import '../providers.dart';
import '../widgets/sync_status_chip.dart';

bool get cameraSupported => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(storeChangesProvider);
    final store = ref.watch(storeProvider);
    final sync = ref.watch(syncProvider);
    final status = ref.watch(syncStatusProvider).value ?? sync.currentStatus;
    final discovered = ref.watch(discoveredProvider).value ?? const <DiscoveredDevice>[];
    final peers = store.listPeers();
    final unpaired = discovered.where((d) => peers.every((p) => p.deviceId != d.deviceId)).toList();
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Устройства и синхронизация')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Flexible(child: SyncStatusChip(status: status)),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Синхронизировать сейчас',
                    onPressed: () => sync.syncNow(force: true),
                    icon: const Icon(Icons.sync),
                  ),
                ]),
                if (status.lastError != null) ...[
                  const SizedBox(height: 8),
                  Text(status.lastError!,
                      style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Автоматическая синхронизация'),
                  subtitle: const Text('В одной Wi‑Fi/LAN-сети, без интернета и облака'),
                  value: status.autoSync,
                  onChanged: (v) => sync.autoSync = v,
                ),
                Text('Это устройство: ${sync.identity.name} · ключ ${sync.identity.fingerprint} · v$appVersion',
                    style: t.bodySmall),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, c) {
            final show = FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const ShowPairingScreen())),
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Показать код', maxLines: 1, overflow: TextOverflow.ellipsis),
            );
            final join = OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const JoinPairingScreen())),
              icon: Icon(cameraSupported ? Icons.qr_code_scanner : Icons.pin),
              label: Text(cameraSupported ? 'Подключиться' : 'Ввести код',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            );
            // Stack vertically on narrow screens / large system font.
            if (c.maxWidth < 330 * MediaQuery.textScalerOf(context).scale(1)) {
              return Column(children: [show, const SizedBox(height: 12), join]);
            }
            return Row(children: [
              Expanded(child: show),
              const SizedBox(width: 12),
              Expanded(child: join),
            ]);
          }),
          const SizedBox(height: 24),
          Text('Сопряжённые устройства', style: t.titleSmall),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Пока нет. Откройте «Показать код» на одном устройстве и «Подключиться» на другом.'),
            ),
          for (final p in peers)
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.devices,
                  color: discovered.any((d) => d.deviceId == p.deviceId)
                      ? Colors.green
                      : Theme.of(context).colorScheme.outline,
                ),
                title: Text(p.name),
                subtitle: Text([
                  if (discovered.any((d) => d.deviceId == p.deviceId)) 'в сети' else 'не в сети',
                  if (p.lastSyncAt != null) 'синхр. ${_ago(p.lastSyncAt!)}',
                  if (p.lastAddress != null) p.lastAddress!,
                ].join(' · ')),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'unpair') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('Отвязать «${p.name}»?'),
                          content: const Text('Заметки останутся, но синхронизация прекратится.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Отвязать')),
                          ],
                        ),
                      );
                      if (ok == true) await sync.unpair(p.deviceId);
                    } else if (v == 'addr' && context.mounted) {
                      final r = await _askAddress(context, p.lastAddress, p.lastPort);
                      if (r != null) {
                        sync.addManualAddress(p.deviceId, r.$1, r.$2);
                        sync.syncNow(force: true);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'addr', child: Text('Указать IP вручную')),
                    PopupMenuItem(value: 'unpair', child: Text('Отвязать')),
                  ],
                ),
              ),
            ),
          if (unpaired.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Найдены в сети', style: t.titleSmall),
            const SizedBox(height: 8),
            for (final d in unpaired)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.wifi_tethering),
                  title: Text(d.name),
                  subtitle: Text('${d.address} · ключ ${d.fingerprint}'),
                  trailing: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => JoinPairingScreen(target: d)),
                    ),
                    child: const Text('Сопрячь'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'только что';
    if (d.inHours < 1) return '${d.inMinutes} мин назад';
    if (d.inDays < 1) return '${d.inHours} ч назад';
    return '${d.inDays} дн назад';
  }
}

Future<(String, int)?> _askAddress(BuildContext context, String? host, int? port) async {
  final h = TextEditingController(text: host ?? '');
  final p = TextEditingController(text: '${port ?? SyncService.preferredPort}');
  return showDialog<(String, int)>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Адрес устройства'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: h, decoration: const InputDecoration(labelText: 'IP-адрес')),
        const SizedBox(height: 12),
        TextField(
          controller: p,
          decoration: const InputDecoration(labelText: 'Порт'),
          keyboardType: TextInputType.number,
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
        FilledButton(
          onPressed: () {
            final port = int.tryParse(p.text.trim());
            if (h.text.trim().isEmpty || port == null) return;
            Navigator.pop(c, (h.text.trim(), port));
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Shows QR code + 6-digit code; waits for the other device to connect.
class ShowPairingScreen extends ConsumerStatefulWidget {
  const ShowPairingScreen({super.key});
  @override
  ConsumerState<ShowPairingScreen> createState() => _ShowPairingScreenState();
}

class _ShowPairingScreenState extends ConsumerState<ShowPairingScreen> {
  PairingOffer? _offer;
  PairingQr? _qr;
  Timer? _tick;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _create();
    _sub = ref.read(syncProvider).pairedEvents.listen((name) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Устройство «$name» сопряжено')));
      Navigator.pop(context);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _create() async {
    final (o, q) = await ref.read(syncProvider).createPairingOffer();
    if (mounted) {
      setState(() {
        _offer = o;
        _qr = q;
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    final s = ref.read(syncProvider);
    if (s.offer == _offer) s.cancelPairingOffer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = _offer;
    final q = _qr;
    final t = Theme.of(context).textTheme;
    final left = o == null ? 0 : o.expiresAt.difference(DateTime.now()).inSeconds;
    final expired = o != null && (o.expired || o.codeRevoked);
    return Scaffold(
      appBar: AppBar(title: const Text('Сопряжение')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: o == null || q == null
                ? const CircularProgressIndicator()
                : Column(children: [
                    Text('Отсканируйте QR-код на другом устройстве',
                        textAlign: TextAlign.center, style: t.titleMedium),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          color: Colors.white, borderRadius: BorderRadius.circular(20)),
                      child: Opacity(
                        opacity: expired ? 0.2 : 1,
                        child: QrImageView(data: q.encode(), size: 240, backgroundColor: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text('или введите код', style: t.bodyMedium),
                    const SizedBox(height: 8),
                    SelectableText(
                      '${o.code.substring(0, 3)} ${o.code.substring(3)}',
                      style: t.displaySmall?.copyWith(
                          fontWeight: FontWeight.w700, letterSpacing: 6, fontFeatures: const []),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Адрес: ${q.addresses.isEmpty ? '—' : q.addresses.first}:${q.port}',
                      style: t.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    if (expired)
                      FilledButton.icon(
                        onPressed: _create,
                        icon: const Icon(Icons.refresh),
                        label: Text(o.codeRevoked ? 'Слишком много попыток — новый код' : 'Код истёк — новый код'),
                      )
                    else
                      Text('Действует ещё ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}',
                          style: t.bodySmall),
                  ]),
          ),
        ),
      ),
    );
  }
}

/// Scans a QR code (on devices with a camera) or accepts code + address.
class JoinPairingScreen extends ConsumerStatefulWidget {
  final DiscoveredDevice? target;
  const JoinPairingScreen({super.key, this.target});
  @override
  ConsumerState<JoinPairingScreen> createState() => _JoinPairingScreenState();
}

class _JoinPairingScreenState extends ConsumerState<JoinPairingScreen> {
  late bool _scan = cameraSupported && widget.target == null;
  final _code = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '${SyncService.preferredPort}');
  bool _busy = false;
  String? _error;
  DiscoveredDevice? _target;

  @override
  void initState() {
    super.initState();
    _target = widget.target;
    if (_target != null) {
      _host.text = _target!.address;
      _port.text = '${_target!.port}';
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Сопряжено с «$name»')));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onQr(String raw) {
    if (_busy) return;
    final qr = PairingQr.tryParse(raw);
    if (qr == null) {
      setState(() => _error = 'Это не QR-код NoteVibe');
      return;
    }
    setState(() => _scan = false);
    _run(() => ref.read(syncProvider).pairWithQr(qr));
  }

  @override
  Widget build(BuildContext context) {
    final discovered = ref.watch(discoveredProvider).value ?? const <DiscoveredDevice>[];
    final peers = ref.watch(storeProvider).listPeers();
    final candidates = discovered.where((d) => peers.every((p) => p.deviceId != d.deviceId)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Подключиться к устройству')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_scan) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                height: 320,
                child: MobileScanner(
                  onDetect: (r) {
                    final v = r.barcodes.isEmpty ? null : r.barcodes.first.rawValue;
                    if (v != null) _onQr(v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _scan = false),
              child: const Text('Ввести код вручную'),
            ),
          ] else ...[
            if (cameraSupported)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () => setState(() => _scan = true),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Сканировать QR-код'),
              ),
            const SizedBox(height: 16),
            Text('На другом устройстве откройте «Показать код» и введите 6 цифр.',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (candidates.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                initialValue: _target?.deviceId,
                decoration: const InputDecoration(labelText: 'Устройство в сети'),
                items: [
                  for (final d in candidates)
                    DropdownMenuItem(value: d.deviceId, child: Text('${d.name} (${d.address})')),
                ],
                onChanged: (id) {
                  final d = candidates.firstWhere((x) => x.deviceId == id);
                  setState(() {
                    _target = d;
                    _host.text = d.address;
                    _port.text = '${d.port}';
                  });
                },
              ),
              const SizedBox(height: 12),
            ],
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(labelText: 'IP-адрес'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Порт'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(labelText: 'Код', counterText: ''),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _busy
                  ? null
                  : () {
                      final port = int.tryParse(_port.text.trim());
                      if (_host.text.trim().isEmpty || port == null || _code.text.length != 6) {
                        setState(() => _error = 'Укажите адрес, порт и 6-значный код');
                        return;
                      }
                      _run(() => ref.read(syncProvider).pairWithCode(_host.text.trim(), port, _code.text));
                    },
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Сопрячь'),
            ),
          ],
          if (_busy && _scan == false && _code.text.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
