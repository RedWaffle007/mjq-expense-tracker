import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/users/manage_users_screen.dart';
import '../../features/admin/sites/manage_sites_screen.dart';
import '../../features/auth/application/session.dart';
import '../../features/auth/presentation/sign_in_screen.dart';
import '../../features/entries/entry_detail_screen.dart';
import '../../features/entries/entry_form_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/sites/site_screen.dart';
import '../../features/activity/activity_screen.dart';
import '../../features/admin/export/export_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../data/entries/expense_entry.dart';
import 'routes.dart';

/// The app's router. Redirects follow the [Session]: loading → splash,
/// signed out → sign-in, active → the app. CEO-only routes redirect managers home.
final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider).value ?? const SessionLoading();
      final at = state.matchedLocation;
      switch (session) {
        case SessionLoading():
          return at == Routes.splash ? null : Routes.splash;
        case SessionSignedOut():
          return at == Routes.signIn ? null : Routes.signIn;
        case SessionActive(:final user):
          if (at == Routes.splash || at == Routes.signIn) return Routes.home;
          if (at.startsWith('/admin') && !user.isCeo) return Routes.home;
          return null;
      }
    },
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const _SplashScreen()),
      GoRoute(path: Routes.signIn, builder: (_, _) => const SignInScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
      GoRoute(path: Routes.activity, builder: (_, _) => const ActivityScreen()),
      GoRoute(path: Routes.export, builder: (_, _) => const ExportScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
      GoRoute(path: Routes.join, redirect: (_, _) => Routes.home),
      GoRoute(
        path: Routes.site,
        builder: (_, state) => SiteScreen(
          siteId: state.pathParameters['siteId']!,
          siteName: state.uri.queryParameters['name'] ?? 'Site',
        ),
      ),
      GoRoute(
        path: Routes.addEntry,
        builder: (_, state) =>
            EntryFormScreen(initialSiteId: state.uri.queryParameters['siteId']),
      ),
      GoRoute(
        path: Routes.editEntry,
        builder: (_, state) =>
            EntryFormScreen(entry: state.extra! as ExpenseEntry),
      ),
      GoRoute(
        path: Routes.entry,
        builder: (_, state) =>
            EntryDetailScreen(entryId: state.pathParameters['entryId']!),
      ),
      GoRoute(
        path: Routes.manageUsers,
        builder: (_, _) => const ManageUsersScreen(),
      ),
      GoRoute(
        path: Routes.manageSites,
        builder: (_, _) => const ManageSitesScreen(),
      ),
    ],
  );
});

/// Re-runs the router's redirect whenever the session changes.
class _SessionRefresh extends ChangeNotifier {
  _SessionRefresh(Ref ref) {
    ref.listen(sessionProvider, (_, _) => notifyListeners());
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
