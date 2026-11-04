import 'package:flutter/material.dart';

import '../../sync/sync_service.dart';

class SyncStatusChip extends StatelessWidget {
  final SyncStatus status;
  final VoidCallback? onTap;
  final bool compact;
  const SyncStatusChip({super.key, required this.status, this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (status.state) {
      SyncState.synced => (Icons.cloud_done_outlined, Colors.green),
      SyncState.syncing => (Icons.sync, s.primary),
      SyncState.offline => (Icons.cloud_off_outlined, s.outline),
      SyncState.conflict => (Icons.call_split, s.error),
    };
    final label = status.autoSync || status.state != SyncState.offline
        ? status.label
        : '${status.label} (авто выкл.)';
    final iconWidget = status.state == SyncState.syncing
        ? SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(icon, size: 24, color: color);
    final child = compact
        ? SizedBox(width: 48, height: 48, child: Center(child: iconWidget))
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              iconWidget,
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ]),
          );
    return Tooltip(
      message: status.lastError ?? label,
      child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: child),
    );
  }
}
