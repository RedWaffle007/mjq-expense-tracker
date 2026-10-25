import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';

class PhotoSyncBanner extends ConsumerWidget {
  const PhotoSyncBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(photoUploadQueueProvider);
    final edits = ref.watch(offlineEditQueueProvider);
    final total = queue.pendingCount + edits.pendingCount;
    if (total == 0) return const SizedBox.shrink();
    final hasErrors = queue.errorCount > 0 || edits.errorCount > 0;
    final processing = queue.isProcessing || edits.isProcessing;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: processing
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                hasErrors
                    ? Icons.sync_problem_outlined
                    : Icons.cloud_upload_outlined,
              ),
        title: Text(
          processing
              ? 'Syncing offline changes…'
              : '$total item${total == 1 ? '' : 's'} waiting to sync',
        ),
        subtitle: hasErrors
            ? Text(
                queue.items
                        .where((item) => item.error != null)
                        .map((item) => item.error!)
                        .firstOrNull ??
                    'Your expense is saved. Retry when you are online.',
              )
            : null,
        trailing: hasErrors
            ? TextButton(
                onPressed: () {
                  queue.retry();
                  edits.retry();
                },
                child: const Text('Retry'),
              )
            : null,
      ),
    );
  }
}
