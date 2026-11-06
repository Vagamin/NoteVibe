import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/note_store.dart';
import '../../sync/crypto/secure_channel.dart';
import '../../sync/transfer/note_transfer.dart';
import '../../sync/transfer/transfer_session.dart';
import '../../sync/discovery/lan_discovery.dart';
import '../providers.dart';

Future<void> showTransferMenu(BuildContext context, WidgetRef ref) async {
  final action = await showDialog<String>(context: context, builder: (c) => AlertDialog(
    title: const Text('Разовая передача'),
    content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('В одной Wi-Fi или локальной сети. Без постоянного сопряжения.'),
        const SizedBox(height: 20),
        FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => Navigator.pop(c, 'send'), icon: const Icon(Icons.upload_outlined), label: const Text('Отправить')),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => Navigator.pop(c, 'receive'), icon: const Icon(Icons.download_outlined), label: const Text('Получить')),
      ])),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Закрыть'))],
  ));
  if (!context.mounted || action == null) return;
  if (action == 'send') {
    ref.read(transferSelectionProvider.notifier).set(true);
    ref.read(selectionProvider.notifier).start();
  } else {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const TransferScreen(receive: true)));
  }
}

class TransferScreen extends ConsumerStatefulWidget {
  final Set<String>? selectedIds;
  final bool receive;
  const TransferScreen({super.key, this.selectedIds, this.receive = false});
  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  final _selected = <String>{};
  final _code = TextEditingController();
  TransferSession? _offer;
  SecureChannel? _channel;
  String? _mode;
  String? _error;
  String? _status;
  bool _busy = false;
  bool _scan = false;
  int? _completedCount;
  NoteTransferProgress? _progress;
  LanDiscovery? _discovery;
  StreamSubscription<List<DiscoveredDevice>>? _discoverySubscription;
  List<DiscoveredDevice> _senders = [];
  DiscoveredDevice? _sender;
  bool _manualLink = false;
  AppServices? _services;
  Future<void> _onLock() async {
    await _discoverySubscription?.cancel();
    _discovery?.dispose();
    _discovery = null;
    await _offer?.close();
    await _channel?.close();
  }

  Future<void> _discover() async {
    if (_discovery != null) return;
    final discovery = LanDiscovery(deviceId: 'receiver-${DateTime.now().microsecondsSinceEpoch}',
      name: 'Получатель', fingerprint: '', tcpPort: () => 0, udpPort: TransferSession.discoveryPort);
    _discovery = discovery;
    _discoverySubscription = discovery.devices.listen((devices) {
      if (!mounted) return;
      setState(() {
        _senders = devices.where((d) {
          try { return d.port > 0 && d.deviceId.length <= 128 && base64Url.decode(d.fingerprint).length == 32; }
          catch (_) { return false; }
        }).take(20).toList();
        final matches = _senders.where((d) => d.deviceId == _sender?.deviceId);
        _sender = matches.isNotEmpty ? matches.first : _senders.length == 1 ? _senders.first : null;
      });
    });
    try { await discovery.start(); }
    catch (_) { if (mounted) setState(() => _error = 'Поиск недоступен. Используйте QR или ссылку.'); }
  }

  void _onProgress(NoteTransferProgress progress) {
    if (mounted) setState(() { _progress = progress; });
  }

  Future<void> _showCompletion(int count, {required bool received}) async {
    if (!mounted) return;
    setState(() { _completedCount = count; });
    final scheme = Theme.of(context).colorScheme;
    await showDialog<void>(context: context, builder: (c) => AlertDialog(
      icon: Icon(Icons.check_circle_rounded, size: 64, color: scheme.primary),
      title: Text(received ? 'Заметки получены!' : 'Заметки переданы!'),
      content: Text('${received ? 'Сохранено на этом устройстве' : 'Получатель подтвердил приём'}: $count.',
        textAlign: TextAlign.center),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Готово'))],
    ));
  }

  @override
  void initState() {
    super.initState();
    _services = ref.read(servicesProvider);
    _services!.lockHandlers.add(_onLock);
    if (widget.receive) { _mode = 'receive'; _discover(); }
    if (widget.selectedIds != null) {
      _selected.addAll(widget.selectedIds!);
      _mode = 'send';
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _send(); });
    }
  }

  @override
  void dispose() {
    _services?.lockHandlers.remove(_onLock);
    _discoverySubscription?.cancel();
    _discovery?.dispose();
    _offer?.close();
    _channel?.close();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || _selected.isEmpty) return;
    setState(() { _busy = true; _progress = null; _completedCount = null; _error = null; _status = 'Подготовка…'; });
    try {
      final services = ref.read(servicesProvider);
      final items = <RemoteNote>[];
      for (final id in _selected) {
        final note = services.store.getNote(id);
        if (note == null || note.deleted || note.trashedAt != null) throw const FormatException('Одна из заметок больше недоступна');
        items.add(RemoteNote(note, attachments: services.store.attachmentsFor(id)));
      }
      final addresses = <String>[];
      for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) addresses.add(address.address);
        }
      }
      // Only private LAN addresses are accepted by the transfer QR parser.
      final private = addresses.where((a) => a.startsWith('10.') || a.startsWith('192.168.') ||
        (a.startsWith('172.') && int.tryParse(a.split('.')[1]) != null && int.parse(a.split('.')[1]) >= 16 && int.parse(a.split('.')[1]) <= 31)).take(8).toList();
      if (private.isEmpty) throw const FormatException('Подключитесь к локальной Wi-Fi сети');
      final offer = await TransferSession.create(addresses: private);
      if (!mounted) { await offer.close(); return; }
      _offer = offer;
      try { await offer.announce(services.sync.identity.name); }
      catch (_) { /* QR remains available if UDP discovery is blocked. */ }
      setState(() { _status = 'Покажите QR получателю. Действует 5 минут.'; });
      final channel = await offer.connected;
      if (!mounted) { await channel.close(); return; }
      _channel = channel;
      setState(() { _offer = null; _status = 'Ожидание подтверждения и передача…'; });
      final accepted = await NoteTransfer.send(channel, items, services.attachments, onProgress: _onProgress);
      if (mounted) setState(() => _status = accepted ? 'Заметки переданы' : 'Получатель отказался от приёма');
      if (accepted) await _showCompletion(items.length, received: false);
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _status = null; });
    } finally {
      await _offer?.close();
      _offer = null;
      await _channel?.close();
      _channel = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receive(String code, {DiscoveredDevice? sender}) async {
    if (_busy) return;
    if (sender != null) {
      final current = _discovery?.current.where((d) => d.deviceId == sender!.deviceId).toList();
      if (current != null && current.isNotEmpty) sender = current.first;
    }
    setState(() { _busy = true; _progress = null; _completedCount = null; _scan = false; _error = null; _status = 'Подключение…'; });
    try {
      final services = ref.read(servicesProvider);
      final channel = sender == null ? await TransferSession.connect(code) : await TransferSession.connectCode(sender, code.replaceAll(' ', ''));
      if (!mounted) { await channel.close(); return; }
      _channel = channel;
      final notes = await NoteTransfer.receive(channel, services.store, services.attachments,
        onProgress: _onProgress,
        confirm: (items, bytes) async {
          if (!mounted) return false;
          return await showDialog<bool>(context: context, builder: (c) => AlertDialog(
            title: const Text('Принять заметки?'),
            content: SizedBox(width: 360, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${items.length} заметок · ${(bytes / 1048576).toStringAsFixed(1)} МБ вложений'),
                const SizedBox(height: 12),
                for (final item in items) Text('• ${item.note.displayTitle}', maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
                const Text('Будут созданы отдельные копии. Постоянная синхронизация не включается.'),
              ]))),
            actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отказаться')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Принять'))],
          )) ?? false;
        });
      if (mounted) setState(() => _status = notes.isEmpty ? 'Приём отменён' : 'Получено заметок: ${notes.length}');
      if (notes.isNotEmpty) await _showCompletion(notes.length, received: true);
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _status = null; });
    } finally {
      await _channel?.close();
      _channel = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('Разовая передача')), body: ListView(
      padding: const EdgeInsets.all(16), children: [
        if (_completedCount != null) ...[
          Semantics(liveRegion: true, child: Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(padding: const EdgeInsets.all(20), child: Row(children: [
              Icon(Icons.check_circle_rounded, size: 40, color: Theme.of(context).colorScheme.onPrimaryContainer),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_mode == 'receive' ? 'Заметки получены!' : 'Заметки переданы!',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer)),
                const SizedBox(height: 4),
                Text('Успешно: $_completedCount', style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer)),
              ])),
            ])),
          )),
          const SizedBox(height: 16),
        ],
         if (_offer == null) const Text('Оба устройства должны быть в одной Wi-Fi или локальной сети. Передача зашифрована и не добавляет устройство в постоянную синхронизацию.'),
         if (_offer == null) const SizedBox(height: 16),
        if (!_busy && widget.selectedIds == null) Wrap(spacing: 12, runSpacing: 12, children: [
          FilledButton.tonalIcon(onPressed: () {
            ref.read(transferSelectionProvider.notifier).set(true);
            ref.read(selectionProvider.notifier).start();
            Navigator.pop(context);
          }, icon: const Icon(Icons.upload_outlined), label: const Text('Отправить')),
           FilledButton.tonalIcon(onPressed: () { setState(() { _mode = 'receive'; _completedCount = null; _scan = false; _status = null; _error = null; }); _discover(); }, icon: const Icon(Icons.download_outlined), label: const Text('Получить')),
        ]),
        if (_mode == 'send' && !_busy) ...[
          const SizedBox(height: 16),
          FilledButton(onPressed: _send, child: const Text('Повторить передачу')),
        ],
         if (_offer != null) ...[
           Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
             const Text('Код для получателя'),
             const SizedBox(height: 8),
             SelectableText('${_offer!.code.substring(0, 3)} ${_offer!.code.substring(3)}',
               style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 4)),
             const SizedBox(height: 8),
             const Text('«Получить» → отправитель → 6 цифр.\n5 минут · до 3 неверных попыток', textAlign: TextAlign.center),
           ]))),
           const SizedBox(height: 12),
           Center(child: Container(color: Colors.white, padding: const EdgeInsets.all(12),
             child: QrImageView(data: _offer!.qr.encode(), size: (MediaQuery.sizeOf(context).height * 0.29).clamp(160.0, 240.0)))),
          TextButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: _offer!.qr.encode())),
             icon: const Icon(Icons.copy), label: const Text('Копировать ссылку')),
        ],
         if (_mode == 'receive' && !_busy && _completedCount == null) ...[
           const SizedBox(height: 16),
           if (!_manualLink && !_scan) ...[
             Text('Отправители в локальной сети', style: Theme.of(context).textTheme.titleMedium),
             const SizedBox(height: 8),
             if (_senders.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 12),
               child: Text('Поиск отправителя… Откройте «Отправить» на другом устройстве в той же Wi-Fi сети.')),
             for (final device in _senders) Card(child: ListTile(
               leading: Icon(_sender?.deviceId == device.deviceId ? Icons.radio_button_checked : Icons.radio_button_unchecked),
               title: Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(device.address),
               onTap: () => setState(() => _sender = device))),
             const SizedBox(height: 12),
             TextField(controller: _code, keyboardType: TextInputType.number, maxLength: 6,
               inputFormatters: [FilteringTextInputFormatter.digitsOnly],
               decoration: const InputDecoration(labelText: 'Код из 6 цифр', hintText: '123456'),
               onSubmitted: (code) { if (_sender != null) _receive(code, sender: _sender); }),
             const SizedBox(height: 12),
             FilledButton(onPressed: _sender == null ? null : () => _receive(_code.text, sender: _sender), child: const Text('Подключиться')),
           ],
           Wrap(spacing: 8, children: [
             if (Platform.isAndroid) TextButton.icon(onPressed: () => setState(() { _scan = !_scan; _manualLink = false; _code.clear(); }),
               icon: const Icon(Icons.qr_code_scanner), label: Text(_scan ? 'Ввести 6 цифр' : 'Сканировать QR')),
             TextButton(onPressed: () => setState(() { _manualLink = !_manualLink; _scan = false; _code.clear(); }),
               child: Text(_manualLink ? 'Ввести 6 цифр' : 'Вставить длинную ссылку')),
           ]),
           if (_scan) ...[ClipRRect(borderRadius: BorderRadius.circular(20), clipBehavior: Clip.hardEdge,
             child: SizedBox(height: 280, child: MobileScanner(onDetect: (capture) {
            final raw = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
            if (raw != null) _receive(raw);
           }))), const SizedBox(height: 20)],
           if (_manualLink) TextField(controller: _code, decoration: const InputDecoration(labelText: 'Ссылка передачи', hintText: 'Вставьте скопированную ссылку из QR')),
          const SizedBox(height: 12),
           if (_manualLink) FilledButton(onPressed: () => _receive(_code.text), child: const Text('Подключиться')),
        ],
         if (_busy && _offer == null && _completedCount == null) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
           child: TransferProgressCard(progress: _progress, status: _status ?? 'Подготовка…')),
         if (!_busy && _status != null && _completedCount == null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status!)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ],
    ));
  }
}

class TransferProgressCard extends StatelessWidget {
  final NoteTransferProgress? progress;
  final String status;
  const TransferProgressCard({super.key, required this.progress, required this.status});
  @override
  Widget build(BuildContext context) {
    final p = progress;
    final fraction = p == null || p.totalBytes == 0 ? null : (p.completedBytes / p.totalBytes).clamp(0.0, 0.99);
    final title = p == null ? status : p.finalizing ? 'Проверка и сохранение заметок…' : 'Передача заметок…';
    return Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: p?.finalizing == true ? null : fraction,
          minHeight: 10, borderRadius: BorderRadius.circular(8)),
        const SizedBox(height: 10),
        if (p != null && p.totalBytes > 0)
          Text('${((fraction ?? 0) * 100).floor()}% · ${(p.completedBytes / 1048576).toStringAsFixed(2)} / ${(p.totalBytes / 1048576).toStringAsFixed(2)} МБ',
            style: Theme.of(context).textTheme.bodyMedium),
        if (p != null && p.totalBytes == 0) const Text('Передача текста и подтверждение приёма'),
      ],
    )));
  }
}
