import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

final appLockProvider = ChangeNotifierProvider<AppLockController>((ref) {
  final controller = AppLockController();
  controller.load();
  return controller;
});

class AppLockController extends ChangeNotifier {
  static const _key = 'app_lock_enabled';
  final LocalAuthentication _auth = LocalAuthentication();
  bool initialized = false;
  bool enabled = false;
  bool locked = false;
  bool busy = false;
  DateTime? _backgroundedAt;

  Future<void> load() async {
    enabled = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    locked = enabled;
    initialized = true;
    notifyListeners();
  }

  Future<bool> setEnabled(bool value) async {
    if (value && !await _auth.isDeviceSupported()) return false;
    enabled = value;
    locked = false;
    await (await SharedPreferences.getInstance()).setBool(_key, value);
    notifyListeners();
    return true;
  }

  void background() => _backgroundedAt = DateTime.now();
  void foreground() {
    final left = _backgroundedAt;
    _backgroundedAt = null;
    if (enabled &&
        left != null &&
        DateTime.now().difference(left) >= const Duration(minutes: 3)) {
      locked = true;
      notifyListeners();
    }
  }

  Future<void> unlock() async {
    if (busy || !locked) return;
    busy = true;
    notifyListeners();
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock your expense tracker',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (ok) locked = false;
    } catch (_) {
      // Stay locked; the OS prompt provides the actionable error.
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({required this.child, super.key});
  final Widget child;
  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ref.read(appLockProvider).background();
    }
    if (state == AppLifecycleState.resumed) {
      ref.read(appLockProvider).foreground();
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(appLockProvider);
    final obscured = !lock.initialized || lock.locked;
    return Stack(
      children: [
        IgnorePointer(
          ignoring: obscured,
          child: ExcludeSemantics(excluding: obscured, child: widget.child),
        ),
        if (obscured)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      lock.initialized
                          ? Icons.lock_outline
                          : Icons.shield_outlined,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      lock.initialized
                          ? 'MJQ Expense Tracker is locked'
                          : 'Securing MJQ Expense Tracker',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    if (lock.initialized)
                      FilledButton.icon(
                        onPressed: lock.busy ? null : lock.unlock,
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Unlock'),
                      )
                    else
                      const CircularProgressIndicator(),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
