import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/providers.dart';
import '../../../data/invites/invite_repository.dart';
import '../../../data/users/app_user.dart';
import '../../../data/worker/worker_client.dart';

/// Invite a user by name, Google account email, and role (plan.md Section 3.1).
class InviteDialog extends ConsumerStatefulWidget {
  const InviteDialog({super.key});

  @override
  ConsumerState<InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends ConsumerState<InviteDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController(text: '+91 ');
  UserRole _role = UserRole.manager;
  bool _busy = false;
  String? _error;
  InviteDelivery? _createdInvite;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_createdInvite == null && !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final delivery =
          _createdInvite ??
          await ref
              .read(inviteRepositoryProvider)
              .create(
                email: _email.text.trim(),
                phone: _phone.text.trim(),
                name: _name.text.trim(),
                role: _role,
              );
      _createdInvite = delivery;
      final message =
          'You have been invited to MJQ Builders & Developers. '
          'Open this link and sign in with ${_email.text.trim()}: ${delivery.inviteUrl}';
      final sms = Uri(
        scheme: 'sms',
        path: delivery.phone,
        queryParameters: {'body': message},
      );
      final opened = await launchUrl(sms, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (!opened) {
        setState(
          () => _error =
              'The invitation was created, but no SMS app could be opened.',
        );
        return;
      }
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = workerErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite someone'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(
                  labelText: 'Google account email',
                  hintText: 'name@gmail.com',
                ),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                validator: (v) {
                  final value = v?.trim() ?? '';
                  return RegExp(
                        r'^[^\s@/]+@[^\s@/]+\.[^\s@/]+$',
                      ).hasMatch(value)
                      ? null
                      : 'Enter a valid email';
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                decoration: const InputDecoration(
                  labelText: 'Mobile number',
                  hintText: '+91 98765 43210',
                ),
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                enabled: _createdInvite == null,
                validator: (v) {
                  var value = (v ?? '').replaceAll(RegExp(r'[\s()-]'), '');
                  if (RegExp(r'^\d{10}$').hasMatch(value)) value = '+91$value';
                  return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(value)
                      ? null
                      : 'Enter a valid mobile number with country code';
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<UserRole>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final role in UserRole.values)
                    DropdownMenuItem(value: role, child: Text(role.label)),
                ],
                onChanged: _createdInvite == null
                    ? (r) => setState(() => _role = r ?? UserRole.manager)
                    : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
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
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _createdInvite == null
                      ? 'Invite & open SMS'
                      : 'Open SMS again',
                ),
        ),
      ],
    );
  }
}
