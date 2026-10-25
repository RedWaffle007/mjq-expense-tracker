import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../data/users/user_repository.dart';

const expenseActivityChannel = AndroidNotificationChannel(
  'expense_activity',
  'Expense activity',
  description: 'Expense changes made by other team members',
  importance: Importance.high,
);

class MessagingService {
  MessagingService(this._users);
  final UserRepository _users;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _refresh;
  StreamSubscription<RemoteMessage>? _foreground;
  StreamSubscription<RemoteMessage>? _opened;
  String? _uid;
  void Function(String entryId)? _onOpen;

  Future<void> start(String uid, void Function(String entryId) onOpen) async {
    _uid = uid;
    _onOpen = onOpen;
    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final value = response.payload;
        if (value != null && value.isNotEmpty) _onOpen?.call(value);
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(expenseActivityChannel);
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _users.addFcmToken(uid, token);
    await _refresh?.cancel();
    _refresh = FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) => _users.addFcmToken(uid, token),
    );
    await _foreground?.cancel();
    _foreground = FirebaseMessaging.onMessage.listen(_showForeground);
    await _opened?.cancel();
    _opened = FirebaseMessaging.onMessageOpenedApp.listen(_openMessage);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) scheduleMicrotask(() => _openMessage(initial));
  }

  Future<void> _showForeground(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    await _local.show(
      id: message.hashCode,
      title: notification.title,
      body: notification.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'expense_activity',
          'Expense activity',
          channelDescription: 'Expense changes made by other team members',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: message.data['entryId'],
    );
  }

  void _openMessage(RemoteMessage message) {
    final entryId = message.data['entryId'];
    if (entryId is String && entryId.isNotEmpty) _onOpen?.call(entryId);
  }

  Future<void> stop() async {
    final uid = _uid;
    final token = await FirebaseMessaging.instance.getToken();
    if (uid != null && token != null) await _users.removeFcmToken(uid, token);
    await _refresh?.cancel();
    await _foreground?.cancel();
    await _opened?.cancel();
    _uid = null;
  }
}
