import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/dates.dart';
import '../../core/format/money.dart';
import '../../core/routing/routes.dart';
import '../../data/entries/expense_entry.dart';
import '../../data/providers.dart';
import '../../data/users/app_user.dart';
import '../auth/application/session.dart';

final _entryProvider = StreamProvider.autoDispose.family<ExpenseEntry?, String>(
  (ref, id) => ref.watch(entryRepositoryProvider).watchOne(id),
);
final _historyProvider = StreamProvider.autoDispose
    .family<List<EntryHistory>, String>(
      (ref, id) => ref.watch(entryRepositoryProvider).watchHistory(id),
    );
final _historyUsersProvider = StreamProvider.autoDispose<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).watchAll(),
);
final _photoUrlsProvider = FutureProvider.autoDispose
    .family<Map<String, String>, String>(
      (ref, joinedIds) => ref
          .watch(photoRepositoryProvider)
          .viewUrls(joinedIds.isEmpty ? const [] : joinedIds.split('|')),
    );

class EntryDetailScreen extends ConsumerWidget {
  const EntryDetailScreen({required this.entryId, super.key});
  final String entryId;

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ExpenseEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${entry.item}?'),
        content: const Text(
          'It will disappear from lists and totals, but its history will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final uid = ref.read(currentUserProvider)?.uid;
    if (uid == null) return;
    await ref.read(entryRepositoryProvider).softDelete(entry, uid: uid);
    if (context.mounted) context.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncEntry = ref.watch(_entryProvider(entryId));
    return asyncEntry.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => const Scaffold(
        body: Center(child: Text('Could not load this expense.')),
      ),
      data: (entry) {
        if (entry == null) {
          return const Scaffold(
            body: Center(child: Text('Expense not found.')),
          );
        }
        final history =
            ref.watch(_historyProvider(entryId)).value ??
            const <EntryHistory>[];
        final users =
            ref.watch(_historyUsersProvider).value ?? const <AppUser>[];
        String userName(String uid) =>
            users
                .where((user) => user.uid == uid)
                .map((user) => user.name)
                .firstOrNull ??
            uid;
        final photoIds = entry.photos.map((photo) => photo.publicId).toList();
        final photoUrls = photoIds.isEmpty
            ? const <String, String>{}
            : ref.watch(_photoUrlsProvider(photoIds.join('|'))).value ??
                  const {};
        return Scaffold(
          appBar: AppBar(
            title: Text(entry.item),
            actions: [
              if (!entry.isDeleted)
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit),
                  onPressed: () => context.push(
                    Routes.editEntryPath(entry.id),
                    extra: entry,
                  ),
                ),
              if (!entry.isDeleted)
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context, ref, entry),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (entry.hasConflict)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.sync_problem),
                    title: Text(
                      'Edited by someone else while you were offline',
                    ),
                  ),
                ),
              if (entry.hasPendingWrites) const LinearProgressIndicator(),
              if (entry.pendingPhotoCount > 0)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined),
                    title: Text(
                      '${entry.pendingPhotoCount} bill photo${entry.pendingPhotoCount == 1 ? '' : 's'} waiting to sync',
                    ),
                  ),
                ),
              Text(
                formatPaise(entry.amount),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              _line('Category', entry.category.label),
              _line('Date', formatDate(entry.expenseDate)),
              if (entry.quantity != null)
                _line(
                  'Quantity',
                  '${entry.quantity} ${entry.unit ?? ''}'.trim(),
                ),
              if (entry.rate != null)
                _line('Price per item', formatPaise(entry.rate!)),
              if (entry.vendor != null) _line('Vendor', entry.vendor!),
              if (entry.note != null) _line('Note', entry.note!),
              if (entry.photos.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Bill photos',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: entry.photos.length,
                  itemBuilder: (context, index) {
                    final photo = entry.photos[index];
                    final url = photoUrls[photo.publicId];
                    if (url == null) {
                      return const DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black12),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return InkWell(
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (context) => Dialog.fullscreen(
                          child: Scaffold(
                            appBar: AppBar(
                              title: const Text('Bill photo'),
                              leading: const CloseButton(),
                            ),
                            body: InteractiveViewer(
                              minScale: 0.8,
                              maxScale: 5,
                              child: Center(
                                child: CachedNetworkImage(
                                  imageUrl: url,
                                  fit: BoxFit.contain,
                                  errorWidget: (_, _, _) => const Center(
                                    child: Text('Could not load this photo.'),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.broken_image),
                        ),
                      ),
                    );
                  },
                ),
              ],
              const Divider(height: 32),
              Text('History', style: Theme.of(context).textTheme.titleLarge),
              for (final change in history)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    change.action == 'delete'
                        ? Icons.delete_outline
                        : change.action == 'create'
                        ? Icons.add
                        : Icons.edit,
                  ),
                  title: Text(_historyText(change)),
                  subtitle: Text(
                    '${userName(change.by)}${change.at == null ? '' : ' · ${formatDateTime(change.at!)}'}${change.conflict ? ' · Conflict' : ''}',
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(child: Text(value)),
      ],
    ),
  );

  String _historyText(EntryHistory history) {
    if (history.action == 'create') return 'Expense created';
    if (history.action == 'delete') return 'Expense deleted';
    if (history.changes.length == 1 && history.changes.containsKey('photos')) {
      return 'Bill photo added';
    }
    return history.changes.entries
        .map((change) {
          String value(Object? raw) => switch (raw) {
            final int paise
                when change.key == 'amount' || change.key == 'rate' =>
              formatPaise(paise),
            null => 'empty',
            _ => raw.toString(),
          };
          final label = switch (change.key) {
            'rate' => 'price per item',
            'item' => 'item name',
            final key => key,
          };
          final map = Map<String, dynamic>.from(change.value as Map);
          return '$label: ${value(map['before'])} → ${value(map['after'])}';
        })
        .join(' · ');
  }
}
