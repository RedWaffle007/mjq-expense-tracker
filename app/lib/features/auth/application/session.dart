import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../data/users/app_user.dart';
import '../../../data/worker/worker_client.dart';
import '../data/auth_repository.dart';

/// Who is using the app right now, as far as access goes.
sealed class Session {
  const Session();
}

class SessionLoading extends Session {
  const SessionLoading();
}

/// Signed out. [message] explains why when we signed the user out ourselves
/// (not invited, deactivated, network failure during signup).
class SessionSignedOut extends Session {
  const SessionSignedOut({this.message});
  final String? message;
}

class SessionActive extends Session {
  const SessionActive(this.user);
  final AppUser user;
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    ref.watch(firebaseAuthProvider),
    ref.watch(workerClientProvider),
  ),
);

final authStateProvider = StreamProvider<User?>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges(),
);

/// Why we last signed the user out, shown on the sign-in screen.
class SignOutReason extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;
}

final signOutReasonProvider = NotifierProvider<SignOutReason, String?>(
  SignOutReason.new,
);

/// The current [Session]. Signs the user up on first sign-in (via the Worker),
/// then follows their users doc so a deactivation signs them out at once.
final sessionProvider = StreamProvider<Session>((ref) {
  final auth = ref.watch(authStateProvider);
  final user = auth.value;
  if (user == null) {
    if (auth.isLoading) return Stream.value(const SessionLoading());
    // Watched only on this branch, so setting a reason while signed in
    // doesn't restart the session.
    return Stream.value(
      SessionSignedOut(message: ref.watch(signOutReasonProvider)),
    );
  }
  return _sessionFor(ref, user);
});

Stream<Session> _sessionFor(Ref ref, User user) async* {
  final authRepo = ref.read(authRepositoryProvider);
  final users = ref.read(userRepositoryProvider);

  Future<void> signOutWith(String message) async {
    ref.read(signOutReasonProvider.notifier).set(message);
    await authRepo.signOut();
  }

  yield const SessionLoading();

  bool hasClaim;
  try {
    hasClaim = await authRepo.hasActiveClaim(user);
  } on FirebaseAuthException catch (e) {
    // Offline with an expired token: let the cached users doc decide.
    if (e.code != 'network-request-failed') rethrow;
    hasClaim = true;
  }

  if (!hasClaim) {
    try {
      await authRepo.completeSignup(user);
    } on WorkerException catch (e) {
      await signOutWith(workerErrorMessage(e));
      return;
    }
  }

  try {
    await for (final appUser in users.watchUser(user.uid)) {
      if (appUser == null) {
        await signOutWith(
          workerErrorMessage(const WorkerException('not-invited')),
        );
        return;
      }
      if (!appUser.active) {
        await signOutWith('Your access has been turned off. Contact the CEO.');
        return;
      }
      yield SessionActive(appUser);
    }
  } on FirebaseException catch (e) {
    if (e.code == 'permission-denied' || e.code == 'unauthenticated') {
      await signOutWith('Your access has been turned off. Contact the CEO.');
      return;
    }
    rethrow;
  }
}

/// The signed-in, active user, or null.
final currentUserProvider = Provider<AppUser?>((ref) {
  final session = ref.watch(sessionProvider).value;
  return session is SessionActive ? session.user : null;
});
