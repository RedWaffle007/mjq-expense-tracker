import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/providers.dart';
import 'export_service.dart';

final exportServiceProvider = Provider<ExportService>(
  (ref) => ExportService(
    ref.watch(entryRepositoryProvider),
    ref.watch(siteRepositoryProvider),
    ref.watch(userRepositoryProvider),
    ref.watch(photoRepositoryProvider),
    ref.watch(firestoreProvider),
  ),
);

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});
  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  bool _busy = false;
  ExportRange _range = ExportRange.thisMonth;
  File? _file;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await ref.read(exportServiceProvider).generate(_range);
      if (mounted) setState(() => _file = file);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Export needs internet and fresh data. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Generate Excel')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.table_view_outlined),
            title: Text('Expense workbook'),
            subtitle: Text(
              'One sheet per site, plus an All Sites summary. Deleted expenses are excluded.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Include expenses from'),
        const SizedBox(height: 8),
        SegmentedButton<ExportRange>(
          segments: const [
            ButtonSegment(
              value: ExportRange.thisMonth,
              label: Text('This month'),
            ),
            ButtonSegment(value: ExportRange.allTime, label: Text('All time')),
          ],
          selected: {_range},
          onSelectionChanged: _busy
              ? null
              : (selection) => setState(() {
                  _range = selection.first;
                  _file = null;
                }),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(_busy ? 'Generating…' : 'Generate Excel'),
        ),
        if (_file != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => OpenFilex.open(_file!.path),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open'),
          ),
          OutlinedButton.icon(
            onPressed: () => SharePlus.instance.share(
              ShareParams(files: [XFile(_file!.path)]),
            ),
            icon: const Icon(Icons.share),
            label: const Text('Share'),
          ),
        ],
      ],
    ),
  );
}
