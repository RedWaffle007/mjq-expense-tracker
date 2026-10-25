import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../applock/app_lock.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('App lock'),
            subtitle: const Text(
              'Require fingerprint, face, or device PIN after 3 minutes away',
            ),
            value: lock.enabled,
            onChanged: (value) async {
              final ok = await lock.setEnabled(value);
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Set up a device PIN or biometric first.'),
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Notification and battery help'),
            subtitle: const Text(
              'Allow notifications, autostart, and unrestricted battery use on Xiaomi, Oppo, Vivo, and Realme phones.',
            ),
            trailing: const Icon(Icons.settings),
            onTap: () => launchUrl(
              Uri.parse('app-settings:'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          const ListTile(
            leading: Icon(Icons.record_voice_over_outlined),
            title: Text('Offline speech packs'),
            subtitle: Text(
              'In Android settings, download English (India) and Hindi speech recognition packs for offline voice entry.',
            ),
          ),
        ],
      ),
    );
  }
}
