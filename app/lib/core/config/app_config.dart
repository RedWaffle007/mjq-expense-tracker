/// Build-time configuration, set with `--dart-define`.
///
/// Normal run against the real project:
///   flutter run
/// Against the local emulators and `wrangler dev`:
///   flutter run --dart-define=USE_EMULATORS=true
abstract final class AppConfig {
  /// Talk to the Firebase emulators and the local Worker instead of production.
  static const bool useEmulators = bool.fromEnvironment('USE_EMULATORS');

  /// Host of the emulators and `wrangler dev`, as seen from the phone.
  /// 10.0.2.2 is the host machine from the Android emulator.
  static const String emulatorHost = String.fromEnvironment(
    'EMULATOR_HOST',
    defaultValue: '10.0.2.2',
  );

  static const String _prodWorkerUrl = String.fromEnvironment(
    'WORKER_URL',
    defaultValue: 'https://mjq-worker.timeapp.workers.dev',
  );

  static String get workerUrl =>
      useEmulators ? 'http://$emulatorHost:8787' : _prodWorkerUrl;

  /// The Firebase "web" OAuth client ID (client_type 3 in google-services.json).
  /// google_sign_in needs it as `serverClientId` so the returned ID token is
  /// accepted by Firebase Auth. Not a secret.
  static const String googleServerClientId =
      '71897827045-45ct72ejvguh9t7jf413ddv2kovulns3.apps.googleusercontent.com';
}
