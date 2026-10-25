import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../data/sites/site.dart';
import '../../auth/application/session.dart';

class SiteDialog extends ConsumerStatefulWidget {
  const SiteDialog({super.key, this.site});
  final Site? site;

  @override
  ConsumerState<SiteDialog> createState() => _SiteDialogState();
}

class _SiteDialogState extends ConsumerState<SiteDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.site?.name);
    _location = TextEditingController(text: widget.site?.location);
    _notes = TextEditingController(text: widget.site?.notes);
  }

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repository = ref.read(siteRepositoryProvider);
      final site = widget.site;
      if (site == null) {
        final uid = ref.read(currentUserProvider)?.uid;
        if (uid == null) return;
        await repository.create(
          uid: uid,
          name: _name.text,
          location: _location.text,
          notes: _notes.text,
        );
      } else {
        await repository.update(
          site,
          name: _name.text,
          location: _location.text,
          notes: _notes.text,
          status: site.status,
        );
      }
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save the site. Please try again.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.site == null ? 'Add site' : 'Edit site'),
    content: Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Site name'),
              maxLength: 100,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a site name'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _location,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Location / address',
              ),
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
              maxLength: 1000,
              minLines: 2,
              maxLines: 4,
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Save'),
      ),
    ],
  );
}
