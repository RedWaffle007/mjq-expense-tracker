import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../core/format/money.dart';
import '../../data/entries/entry_repository.dart';
import '../../data/entries/expense_entry.dart';
import '../../data/entries/quantity.dart';
import '../../data/providers.dart';
import '../auth/application/session.dart';
import '../voice/voice_parser.dart';

class EntryFormScreen extends ConsumerStatefulWidget {
  const EntryFormScreen({
    super.key,
    this.initialSiteId,
    this.entry,
    this.voiceFields,
  });
  final String? initialSiteId;
  final ExpenseEntry? entry;
  final VoiceFields? voiceFields;

  @override
  ConsumerState<EntryFormScreen> createState() => _EntryFormScreenState();
}

class _EntryFormScreenState extends ConsumerState<EntryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _item;
  late final TextEditingController _quantity;
  late final TextEditingController _rate;
  late String? _siteId;
  late ExpenseCategory _category;
  late String? _unit;
  late DateTime _date;
  bool _busy = false;
  bool _photoBusy = false;
  final List<String> _newPhotoPaths = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _siteId = entry?.siteId ?? widget.initialSiteId;
    _category =
        entry?.category ??
        widget.voiceFields?.category ??
        ExpenseCategory.other;
    _unit = entry?.unit ?? widget.voiceFields?.unit;
    _date = entry?.expenseDate ?? DateTime.now();
    _item = TextEditingController(
      text: entry?.item ?? widget.voiceFields?.item,
    );
    final voiceQuantity = widget.voiceFields?.quantity;
    final quantity =
        entry?.quantity ??
        (voiceQuantity == null ? null : formatQuantityNumber(voiceQuantity));
    _quantity = TextEditingController(text: quantity ?? '');
    final count = leadingQuantity(quantity) ?? 1;
    final price = entry?.rate != null
        ? entry!.rate! / 100
        : entry != null
        ? entry.amount / 100 / count
        : widget.voiceFields?.rateRupees ??
              (widget.voiceFields?.amountRupees != null
                  ? widget.voiceFields!.amountRupees! / count
                  : null);
    _rate = TextEditingController(
      text: price == null
          ? ''
          : price.toStringAsFixed(2).replaceFirst(RegExp(r'\.00$'), ''),
    );
  }

  @override
  void dispose() {
    for (final controller in [_item, _quantity, _rate]) {
      controller.dispose();
    }
    for (final path in _newPhotoPaths) {
      File(path).delete().ignore();
    }
    super.dispose();
  }

  /// The amount the current quantity and price add up to, or null.
  int? get _amount {
    final rate = parseRupeesToPaise(_rate.text);
    return rate == null || rate <= 0 ? null : amountFor(_quantity.text, rate);
  }

  EntryDraft? _draft() {
    final rate = parseRupeesToPaise(_rate.text);
    final amount = _amount;
    if (_siteId == null || rate == null || amount == null) return null;
    return EntryDraft(
      siteId: _siteId!,
      item: _item.text,
      category: _category,
      amount: amount,
      quantity: _quantity.text,
      unit: _unit,
      rate: rate,
      vendor: widget.entry?.vendor ?? widget.voiceFields?.vendor,
      note: widget.entry?.note ?? widget.voiceFields?.note,
      expenseDate: _date,
      source: widget.voiceFields == null ? 'manual' : 'voice',
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final draft = _draft();
    if (draft == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uid = ref.read(currentUserProvider)?.uid;
      if (uid == null) return;
      final repository = ref.read(entryRepositoryProvider);
      final connectivity = await Connectivity().checkConnectivity();
      final offline = connectivity.contains(ConnectivityResult.none);
      late final String entryId;
      if (widget.entry == null) {
        entryId = await repository.create(
          draft,
          uid: uid,
          pendingPhotoCount: _newPhotoPaths.length,
          waitForServer: !offline,
        );
      } else {
        final changeId = await repository.update(
          widget.entry!,
          draft,
          uid: uid,
          pendingPhotoCount: _newPhotoPaths.length,
          waitForServer: !offline,
        );
        entryId = widget.entry!.id;
        if (offline && changeId != null) {
          await ref
              .read(offlineEditQueueProvider)
              .enqueue(
                entryId: entryId,
                localChangeId: changeId,
                baseChangeId: widget.entry!.lastChangeId,
                before: widget.entry!.editableFields,
                desired: draft.toFields(),
                uid: uid,
              );
        }
      }
      if (_newPhotoPaths.isNotEmpty) {
        await ref
            .read(photoUploadQueueProvider)
            .enqueue(
              entryId: entryId,
              siteId: draft.siteId,
              paths: _newPhotoPaths,
            );
        _newPhotoPaths.clear();
      }
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not save the expense. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    Navigator.pop(context);
    setState(() => _photoBusy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        requestFullMetadata: false,
      );
      if (picked == null) return;
      final path = await ref.read(photoUploadQueueProvider).prepare(picked);
      if (mounted) setState(() => _newPhotoPaths.add(path));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not prepare that photo.')),
        );
      }
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  void _showPhotoSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.voiceFields?.onDevice == true)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.phone_android),
                  title: Text('Parsed on device — please check'),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => _pickPhoto(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => _pickPhoto(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry == null ? 'Add expense' : 'Edit expense'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _item,
              decoration: const InputDecoration(labelText: 'Item name'),
              textCapitalization: TextCapitalization.sentences,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter an item'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _quantity,
              decoration: const InputDecoration(
                labelText: 'Item quantity (optional)',
                hintText: 'e.g. 50 bags, 2.5 ton, 1 load',
              ),
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              validator: (value) => (value?.trim().length ?? 0) > 60
                  ? 'Keep the quantity under 60 characters'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _rate,
              decoration: const InputDecoration(
                labelText: 'Price per item',
                prefixText: '₹ ',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              validator: (value) => (parseRupeesToPaise(value ?? '') ?? 0) <= 0
                  ? 'Enter a valid price'
                  : _amount == null
                  ? 'The total must be more than ₹0'
                  : null,
            ),
            const SizedBox(height: 12),
            Text(
              'Total: ${formatPaise(_amount ?? 0)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_amount != null)
              Text(switch (leadingQuantity(_quantity.text)) {
                null =>
                  'No number at the start of the quantity, so the price is the total.',
                final count =>
                  '${formatQuantityNumber(count)} × ${formatPaise(parseRupeesToPaise(_rate.text)!)}',
              }, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Bill photos',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed:
                      _photoBusy ||
                          _newPhotoPaths.length >= 5 ||
                          _newPhotoPaths.length +
                                  (widget.entry?.photos.length ?? 0) >=
                              10
                      ? null
                      : _showPhotoSource,
                  icon: _photoBusy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (widget.entry?.photos.isNotEmpty == true)
              Text(
                '${widget.entry!.photos.length} saved photo${widget.entry!.photos.length == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (_newPhotoPaths.isNotEmpty)
              SizedBox(
                height: 92,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _newPhotoPaths.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(_newPhotoPaths[index]),
                          width: 92,
                          height: 92,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        right: 2,
                        top: 2,
                        child: IconButton.filled(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Remove photo',
                          onPressed: () async {
                            final path = _newPhotoPaths.removeAt(index);
                            setState(() {});
                            final file = File(path);
                            if (await file.exists()) await file.delete();
                          },
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save expense'),
            ),
          ],
        ),
      ),
    );
  }
}
