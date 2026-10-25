import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/dates.dart';
import '../../core/routing/routes.dart';
import '../../data/activity/activity_repository.dart';
import '../../data/providers.dart';
import '../../data/users/app_user.dart';

final _activitiesProvider = StreamProvider.autoDispose<List<ActivityItem>>(
  (ref) => ref.watch(activityRepositoryProvider).watchLatest(),
);
final _activityUsersProvider = StreamProvider.autoDispose<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).watchAll(),
);

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(_activityUsersProvider).value ?? const <AppUser>[];
    String name(String uid) =>
        users.where((u) => u.uid == uid).map((u) => u.name).firstOrNull ??
        'Someone';
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: ref
          .watch(_activitiesProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) =>
                const Center(child: Text('Could not load activity.')),
            data: (items) => items.isEmpty
                ? const Center(child: Text('No activity yet.'))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        leading: Icon(
                          item.type == 'create'
                              ? Icons.add_circle_outline
                              : item.type == 'delete'
                              ? Icons.delete_outline
                              : Icons.edit_outlined,
                        ),
                        title: Text(item.summary),
                        subtitle: Text(
                          '${name(item.actorId)}${item.createdAt == null ? '' : ' · ${formatDateTime(item.createdAt!)}'}',
                        ),
                        onTap: item.entryId.isEmpty
                            ? null
                            : () =>
                                  context.push(Routes.entryPath(item.entryId)),
                      );
                    },
                  ),
          ),
    );
  }
}
