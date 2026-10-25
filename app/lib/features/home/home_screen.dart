import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/format/money.dart';
import '../../core/routing/routes.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/async_view.dart';
import '../../data/entries/entry_repository.dart';
import '../../data/providers.dart';
import '../../data/sites/site.dart';
import '../auth/application/session.dart';
import '../photos/photo_sync_banner.dart';

final activeSitesProvider = StreamProvider.autoDispose<List<Site>>(
  (ref) => ref.watch(siteRepositoryProvider).watchActive(),
);

/// Home / Overview (plan.md Section 9, screen 3).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String? _messagingUid;

  Future<void> _startMessaging(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('onboarding_complete') ?? false) && mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Set up reliable alerts'),
          content: const Text(
            'Allow notifications when Android asks. On Xiaomi, Oppo, Vivo, or Realme, also allow autostart and unrestricted battery use. For offline voice, download the English (India) and Hindi speech packs in Android settings.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      await prefs.setBool('onboarding_complete', true);
    }
    if (!mounted) return;
    await ref
        .read(messagingServiceProvider)
        .start(
          uid,
          (entryId) =>
              ref.read(appRouterProvider).go(Routes.entryPath(entryId)),
        );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final theme = Theme.of(context);
    final sites = ref.watch(activeSitesProvider);
    if (user == null) return const SizedBox.shrink();
    if (_messagingUid != user.uid) {
      _messagingUid = user.uid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startMessaging(user.uid);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Overview'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
          IconButton(
            tooltip: 'Activity',
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => context.push(Routes.activity),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(messagingServiceProvider).stop();
              await ref.read(authRepositoryProvider).signOut();
            },
          ),
        ],
      ),
      body: ListView(
        padding: kScreenPadding,
        children: [
          const PhotoSyncBanner(),
          Text('Hello, ${user.name}', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '${user.role.label} · ${user.email}',
            style: theme.textTheme.bodyMedium,
          ),
          if (user.isCeo) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => context.push(Routes.export),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('Generate Excel'),
            ),
          ],
          const SizedBox(height: 24),
          Text('Active sites', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          AsyncView<List<Site>>(
            value: sites,
            onRetry: () => ref.invalidate(activeSitesProvider),
            builder: (context, items) => items.isEmpty
                ? const Card(
                    child: ListTile(
                      leading: Icon(Icons.construction),
                      title: Text('No active sites'),
                      subtitle: Text(
                        'The CEO can add the first site from Manage sites.',
                      ),
                    ),
                  )
                : Column(
                    children: [
                      _GrandTotalCard(
                        totals: [
                          for (final site in items)
                            ref.watch(siteTotalProvider(site.id)).value,
                        ],
                      ),
                      for (final site in items)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.business),
                            title: Text(site.name),
                            subtitle: Text(
                              [
                                if (site.location.isNotEmpty) site.location,
                                switch (ref
                                    .watch(siteTotalProvider(site.id))
                                    .value) {
                                  null => '…',
                                  final total => formatPaise(total.amount),
                                },
                              ].join(' · '),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.push(
                              '${Routes.sitePath(site.id)}?name=${Uri.encodeQueryComponent(site.name)}',
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          if (user.isCeo)
            Card(
              child: ListTile(
                leading: const Icon(Icons.group),
                title: const Text('Manage users'),
                subtitle: const Text('Invite and view managers'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(Routes.manageUsers),
              ),
            ),
          if (user.isCeo)
            Card(
              child: ListTile(
                leading: const Icon(Icons.domain),
                title: const Text('Manage sites'),
                subtitle: const Text('Add, edit, archive, or restore sites'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(Routes.manageSites),
              ),
            ),
        ],
      ),
    );
  }
}

/// All active sites' spending, hidden until tapped so it isn't on screen by
/// default.
class _GrandTotalCard extends StatelessWidget {
  const _GrandTotalCard({required this.totals});

  /// One per active site; null while that site's total is loading.
  final List<SiteTotal?> totals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loaded = totals.nonNulls.toList();
    final notes = [
      if (loaded.length < totals.length) 'still loading some sites',
      if (loaded.any((total) => total.isCached)) 'some sites offline',
      if (loaded.any((total) => total.includesUnsynced))
        'includes unsynced changes',
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.account_balance_wallet_outlined),
        title: const Text('Grand total for all sites'),
        subtitle: const Text('Tap to show'),
        shape: const Border(),
        collapsedShape: const Border(),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(
            formatPaise(loaded.fold(0, (sum, total) => sum + total.amount)),
            style: theme.textTheme.headlineMedium,
          ),
          Text(
            [
              '${totals.length} active site${totals.length == 1 ? '' : 's'}',
              ...notes,
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
