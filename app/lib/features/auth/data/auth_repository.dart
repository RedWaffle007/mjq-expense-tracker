import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/config/app_config.dart';
import '../../../data/worker/worker_client.dart';

/// Wraps Firebase Auth, Google Sign-In, and the Worker's signup call so the
/// rest of the app doesn't touch the SDKs directly.
class AuthRepository {
  AuthRepository(this._auth, this._worker);

  final FirebaseAuth _auth;
  final WorkerClient _worker;

  // google_sign_in v7 requires initialize() exactly once per run.
  bool _googleInitialized = false;

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    await GoogleSignIn.instance.initialize(
      serverClientId: AppConfig.googleServerClientId,
    );
    _googleInitialized = true;
  }

  /// Interactive Google sign-in, exchanged for a Firebase session.
  /// Cancelling is a normal return; real failures are rethrown.
  Future<void> signInWithGoogle() async {
    await _ensureGoogleInitialized();
    final GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw Exception('Google sign-in did not return an ID token.');
    }
    await _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  /// Whether the current token already carries the Worker-set `active` claim.
  Future<bool> hasActiveClaim(User user) async {
    final result = await user.getIdTokenResult();
    return result.claims?['active'] == true;
  }

  /// First sign-in of an invited account: the Worker checks the invite and
  /// sets the role claims; then refresh the token so rules see them.
  /// Throws [WorkerException] (e.g. `not-invited`).
  Future<void> completeSignup(User user) async {
    await _worker.post('/signup/complete');
    await user.getIdToken(true);
  }

  Future<void> signOut() async {
    // Sign out of Google too, so the next sign-in shows the account picker.
    try {
      await _ensureGoogleInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // No active Google session; nothing to do.
    }
    await _auth.signOut();
  }
}
