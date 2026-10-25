import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_view.dart';
import '../../../data/invites/invite.dart';
import '../../../data/providers.dart';
import '../../../data/users/app_user.dart';
import '../../auth/application/session.dart';
import 'invite_dialog.dart';

final _allUsersProvider = StreamProvider.autoDispose<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).watchAll(),
);

final _pendingInvitesProvider = StreamProvider.autoDispose<List<Invite>>(
  (ref) => ref.watch(inviteRepositoryProvider).watchPending(),
);

/// CEO: Manage users (plan.md Section 9, screen 8). Invite and list users.
class ManageUsersScreen extends ConsumerWidget {
  const ManageUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserProvider);
    final users = ref.watch(_allUsersProvider);
    final invites = ref.watch(_pendingInvitesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Manage users')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const InviteDialog(),
        ),
        icon: const Icon(Icons.person_add),
        label: const Text('Invite'),
      ),
      body: AsyncView<List<AppUser>>(
        value: users,
        onRetry: () {
          ref.invalidate(_allUsersProvider);
          ref.invalidate(_pendingInvitesProvider);
        },
        builder: (context, userList) {
          final pending = invites.value ?? const <Invite>[];
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              const _SectionHeader('People'),
              for (final user in userList)
                _UserTile(user: user, isMe: user.uid == me?.uid),
              if (pending.isNotEmpty) ...[
                const _SectionHeader('Invited, not signed in yet'),
                for (final invite in pending)
                  ListTile(
                    leading: const Icon(Icons.sms_outlined),
                    title: Text(invite.name),
                    subtitle: Text(
                      [
                        invite.role.label,
                        invite.email,
                        if (invite.phone.isNotEmpty) invite.phone,
                      ].join(' · '),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.isMe});
  final AppUser user;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final subtitle = [user.role.label, user.email].join(' · ');
    return ListTile(
      leading: CircleAvatar(
        child: Text(user.name.isEmpty ? '?' : user.name[0].toUpperCase()),
      ),
      title: Text(isMe ? '${user.name} (you)' : user.name),
      subtitle: Text(subtitle),
    );
  }
}
