import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A Worker call that failed. [code] is the Worker's error code
/// (e.g. `not-invited`, `ceo-only`) or a transport code (`network`, `timeout`).
class WorkerException implements Exception {
  const WorkerException(this.code, {this.status});

  final String code;
  final int? status;

  @override
  String toString() => 'WorkerException($code, status: $status)';
}

/// POSTs JSON to the Cloudflare Worker with the caller's Firebase ID token
/// (plan.md Section 6). Every Worker endpoint goes through here.
class WorkerClient {
  WorkerClient({
    required this.baseUrl,
    required this._auth,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final FirebaseAuth _auth;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, Object?> body = const {},
  ]) async {
    final user = _auth.currentUser;
    if (user == null) throw const WorkerException('signed-out');

    final http.Response response;
    try {
      final idToken = await user.getIdToken();
      String? appCheckToken;
      try {
        appCheckToken = await FirebaseAppCheck.instance.getToken().timeout(
          const Duration(seconds: 5),
        );
      } catch (error) {
        // App Check can be unavailable before the debug token is registered.
        // The Worker decides whether an unattested request is allowed.
        debugPrint('App Check token unavailable: $error');
      }
      response = await _client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
              'X-Firebase-AppCheck': ?appCheckToken,
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const WorkerException('timeout');
    } on FirebaseAuthException catch (e) {
      throw WorkerException('auth-${e.code}');
    } catch (_) {
      throw const WorkerException('network');
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw WorkerException('invalid-response', status: response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded['error'];
      throw WorkerException(
        code is String ? code : 'http-${response.statusCode}',
        status: response.statusCode,
      );
    }
    return decoded;
  }
}

/// A short, human message for a Worker error, for snackbars and dialogs.
String workerErrorMessage(Object error) {
  if (error is! WorkerException) {
    return 'Something went wrong. Please try again.';
  }
  return switch (error.code) {
    'network' || 'timeout' =>
      'Couldn\'t reach the server. Check your internet and try again.',
    'not-invited' =>
      'This Google account hasn\'t been invited. Ask the CEO to invite your email.',
    'deactivated' ||
    'not-active' => 'Your access has been turned off. Contact the CEO.',
    'invite-already-used' => 'This invite was already used by another account.',
    'email-not-verified' => 'Your Google email isn\'t verified.',
    'ceo-only' => 'Only the CEO can do this.',
    'already-registered' => 'That email has already signed up.',
    'invalid-email' => 'Enter a valid email address.',
    'invalid-phone' => 'Enter a valid mobile number with country code.',
    'cloudinary-credentials-invalid' =>
      'The photo service credentials need to be corrected by the administrator.',
    'photos-not-configured' =>
      'The photo service isn\'t set up on the server yet.',
    'entry-not-found' =>
      'The expense hasn\'t reached the server yet. Tap Retry once it syncs.',
    'invalid-app-check' =>
      'This app needs App Check setup before it can reach the server.',
    'invalid-name' => 'Enter a name.',
    'cannot-change-self' => 'You can\'t change your own access.',
    'retry' => 'Someone else just changed this. Please try again.',
    _ => 'Something went wrong (${error.code}). Please try again.',
  };
}
