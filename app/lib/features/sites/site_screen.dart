import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/dates.dart';
import '../../core/format/money.dart';
import '../../core/routing/routes.dart';
import '../../data/entries/expense_entry.dart';
import '../../data/providers.dart';
import '../../data/users/app_user.dart';

final _siteEntriesProvider = StreamProvider.autoDispose
    .family<List<ExpenseEntry>, String>(
      (ref, siteId) => ref.watch(entryRepositoryProvider).watchForSite(siteId),
    );
final _filterUsersProvider = StreamProvider.autoDispose<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).watchAll(),
);

class SiteScreen extends ConsumerStatefulWidget {
  const SiteScreen({required this.siteId, required this.siteName, super.key});
  final String siteId;
  final String siteName;

  @override
  ConsumerState<SiteScreen> createState() => _SiteScreenState();
}

class _SiteScreenState extends ConsumerState<SiteScreen> {
  String _search = '';
  ExpenseCategory? _category;
  DateTimeRange? _dates;
  String? _enteredBy;

  @override
  Widget build(BuildContext context) {
    final siteId = widget.siteId;
    final entries = ref.watch(_siteEntriesProvider(siteId));
    final total = ref.watch(siteTotalProvider(siteId));
    final categoryTotals =
        ref.watch(categoryTotalsProvider(siteId)).value ?? const {};
    final users = ref.watch(_filterUsersProvider).value ?? const <AppUser>[];
    return Scaffold(
      appBar: AppBar(title: Text(widget.siteName)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(Routes.addEntryPath(siteId)),
        icon: const Icon(Icons.add),
        label: const Text('Add expense'),
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(16),
            child: ListTile(
              title: const Text('Total spent'),
              subtitle: Text(
                [
                  '${total.value?.count ?? 0} expenses',
                  if (total.value?.isCached == true &&
                      total.value?.asOf != null)
                    'offline · as of ${formatDateTime(total.value!.asOf!)}',
                  if (total.value?.includesUnsynced == true)
                    'includes unsynced changes',
                ].join(' · '),
              ),
              trailing: total.value == null
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      formatPaise(total.value!.amount),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
            ),
          ),
          if (categoryTotals.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final category in ExpenseCategory.values)
                    if ((categoryTotals[category] ?? 0) > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          label: Text(
                            '${category.label}: ${formatPaise(categoryTotals[category]!)}',
                          ),
                        ),
                      ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search item or vendor',
                    ),
                    onChanged: (value) =>
                        setState(() => _search = value.trim().toLowerCase()),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<ExpenseCategory?>(
                  tooltip: 'Category filter',
                  icon: Icon(
                    _category == null
                        ? Icons.filter_list
                        : Icons.filter_list_alt,
                  ),
                  onSelected: (value) => setState(() => _category = value),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: null,
                      child: Text('All categories'),
                    ),
                    for (final value in ExpenseCategory.values)
                      PopupMenuItem(value: value, child: Text(value.label)),
                  ],
                ),
                PopupMenuButton<String?>(
                  tooltip: 'Entered by',
                  icon: Icon(
                    _enteredBy == null ? Icons.person_outline : Icons.person,
                  ),
                  onSelected: (value) => setState(() => _enteredBy = value),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: null, child: Text('Anyone')),
                    for (final user in users)
                      PopupMenuItem(value: user.uid, child: Text(user.name)),
                  ],
                ),
                IconButton(
                  tooltip: 'Date range',
                  icon: Icon(
                    _dates == null ? Icons.date_range : Icons.event_available,
                  ),
                  onPressed: () async {
                    final value = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                      initialDateRange: _dates,
                    );
                    if (value != null) setState(() => _dates = value);
                  },
                ),
                if (_category != null || _dates != null || _enteredBy != null)
                  IconButton(
                    tooltip: 'Clear filters',
                    icon: const Icon(Icons.filter_alt_off),
                    onPressed: () => setState(() {
                      _category = null;
                      _dates = null;
                      _enteredBy = null;
                    }),
                  ),
              ],
            ),
          ),
          Expanded(
            child: entries.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) =>
                  const Center(child: Text('Could not load expenses.')),
              data: (allItems) {
                final items = allItems.where((entry) {
                  final matchesText =
                      _search.isEmpty ||
                      entry.item.toLowerCase().contains(_search) ||
                      (entry.vendor?.toLowerCase().contains(_search) ?? false);
                  final matchesCategory =
                      _category == null || entry.category == _category;
                  final matchesDate =
                      _dates == null ||
                      (!entry.expenseDate.isBefore(_dates!.start) &&
                          entry.expenseDate.isBefore(
                            _dates!.end.add(const Duration(days: 1)),
                          ));
                  final matchesUser =
                      _enteredBy == null || entry.createdBy == _enteredBy;
                  return matchesText &&
                      matchesCategory &&
                      matchesDate &&
                      matchesUser;
                }).toList();
                return items.isEmpty
                    ? const Center(child: Text('No expenses yet.'))
                    : RefreshIndicator(
                        onRefresh: () async {
                          ref
                            ..invalidate(categoryTotalsProvider(siteId))
                            ..invalidate(siteTotalProvider(siteId));
                          await ref.read(siteTotalProvider(siteId).future);
                        },
                        child: ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final entry = items[index];
                            return ListTile(
                              leading: entry.hasPendingWrites
                                  ? const Icon(Icons.cloud_upload_outlined)
                                  : const Icon(Icons.receipt_long),
                              title: Text(entry.item),
                              subtitle: Text(
                                '${entry.category.label} · ${formatDate(entry.expenseDate)}',
                              ),
                              trailing: Text(formatPaise(entry.amount)),
                              onTap: () =>
                                  context.push(Routes.entryPath(entry.id)),
                            );
                          },
                        ),
                      );
              },
            ),
          ),
        ],
      ),
    );
  }
}
