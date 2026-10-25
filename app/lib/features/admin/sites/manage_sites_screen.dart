import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_view.dart';
import '../../../data/providers.dart';
import '../../../data/sites/site.dart';
import 'site_dialog.dart';

final allSitesProvider = StreamProvider.autoDispose<List<Site>>(
  (ref) => ref.watch(siteRepositoryProvider).watchAll(),
);

class ManageSitesScreen extends ConsumerWidget {
  const ManageSitesScreen({super.key});

  Future<void> _toggleArchive(
    BuildContext context,
    WidgetRef ref,
    Site site,
  ) async {
    final archive = site.isActive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${archive ? 'Archive' : 'Restore'} ${site.name}?'),
        content: Text(
          archive
              ? 'It will leave the active Overview. Expenses and history stay available.'
              : 'It will return to the active Overview.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(archive ? 'Archive' : 'Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(siteRepositoryProvider)
          .update(
            site,
            name: site.name,
            location: site.location,
            notes: site.notes,
            status: archive ? SiteStatus.archived : SiteStatus.active,
          );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update the site. Please try again.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sites = ref.watch(allSitesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manage sites')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const SiteDialog(),
        ),
        icon: const Icon(Icons.add_business),
        label: const Text('Add site'),
      ),
      body: AsyncView<List<Site>>(
        value: sites,
        onRetry: () => ref.invalidate(allSitesProvider),
        builder: (context, items) => items.isEmpty
            ? const Center(
                child: Text('No sites yet. Add the first construction site.'),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final site = items[index];
                  return ListTile(
                    leading: Icon(
                      site.isActive
                          ? Icons.business
                          : Icons.inventory_2_outlined,
                    ),
                    title: Text(site.name),
                    subtitle: Text(
                      [
                        if (site.location.isNotEmpty) site.location,
                        if (!site.isActive) 'Archived',
                      ].join(' · '),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'edit') {
                          showDialog<void>(
                            context: context,
                            builder: (_) => SiteDialog(site: site),
                          );
                        } else {
                          _toggleArchive(context, ref, site);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(
                          value: 'archive',
                          child: Text(site.isActive ? 'Archive' : 'Restore'),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
