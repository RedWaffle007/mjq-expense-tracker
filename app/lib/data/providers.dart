import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/config/app_config.dart';
import 'invites/invite_repository.dart';
import 'entries/entry_repository.dart';
import 'entries/expense_entry.dart';
import 'entries/offline_edit_queue.dart';
import 'entries/pending_totals.dart';
import 'photos/photo_upload_queue.dart';
import 'photos/photo_repository.dart';
import 'sites/site_repository.dart';
import 'users/user_repository.dart';
import 'worker/worker_client.dart';
import 'activity/activity_repository.dart';
import '../features/notifications/messaging_service.dart';

// SDK singletons behind providers, so tests can override them.
final firebaseAuthProvider = Provider<FirebaseAuth>(
  (ref) => FirebaseAuth.instance,
);
final firestoreProvider = Provider<FirebaseFirestore>(
  (ref) => FirebaseFirestore.instance,
);

final workerClientProvider = Provider<WorkerClient>(
  (ref) => WorkerClient(
    baseUrl: AppConfig.workerUrl,
    auth: ref.watch(firebaseAuthProvider),
  ),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => UserRepository(
    ref.watch(firestoreProvider),
    ref.watch(workerClientProvider),
  ),
);

final inviteRepositoryProvider = Provider<InviteRepository>(
  (ref) => InviteRepository(
    ref.watch(firestoreProvider),
    ref.watch(workerClientProvider),
  ),
);

final siteRepositoryProvider = Provider<SiteRepository>(
  (ref) => SiteRepository(ref.watch(firestoreProvider)),
);

final entryRepositoryProvider = Provider<EntryRepository>((ref) {
  final repository = EntryRepository(
    ref.watch(firestoreProvider),
    ref.watch(workerClientProvider),
    PendingTotals(PreferencesPendingTotalsStore()),
  );
  unawaited(repository.settlePendingTotals());
  return repository;
});

/// Counts up whenever site totals may have changed; total providers watch it.
/// (A counter, because providers skip updates equal to the previous value.)
final totalsChangesProvider = StreamProvider.autoDispose<int>((ref) {
  var tick = 0;
  return ref.watch(entryRepositoryProvider).totalsChanges().map((_) => ++tick);
});

final siteTotalProvider = FutureProvider.autoDispose.family<SiteTotal, String>((
  ref,
  siteId,
) {
  ref.watch(totalsChangesProvider);
  return ref.watch(entryRepositoryProvider).totalForSite(siteId);
});

final categoryTotalsProvider = FutureProvider.autoDispose
    .family<Map<ExpenseCategory, int>, String>((ref, siteId) {
      ref.watch(totalsChangesProvider);
      return ref.watch(entryRepositoryProvider).totalsByCategory(siteId);
    });

final photoUploadQueueProvider = ChangeNotifierProvider<PhotoUploadQueue>((
  ref,
) {
  final queue = PhotoUploadQueue(
    ref.watch(workerClientProvider),
    ref.watch(entryRepositoryProvider),
    ref.watch(firebaseAuthProvider),
  );
  queue.start();
  return queue;
});

final photoRepositoryProvider = Provider<PhotoRepository>(
  (ref) => PhotoRepository(ref.watch(workerClientProvider)),
);

final activityRepositoryProvider = Provider<ActivityRepository>(
  (ref) => ActivityRepository(ref.watch(firestoreProvider)),
);

final messagingServiceProvider = Provider<MessagingService>(
  (ref) => MessagingService(ref.watch(userRepositoryProvider)),
);

final offlineEditQueueProvider = ChangeNotifierProvider<OfflineEditQueue>((
  ref,
) {
  final queue = OfflineEditQueue(ref.watch(entryRepositoryProvider));
  queue.start();
  return queue;
});
