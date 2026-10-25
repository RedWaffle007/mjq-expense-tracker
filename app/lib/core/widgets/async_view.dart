import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';

/// Renders an [AsyncValue] so a stuck listener can never present as an infinite
/// spinner. A Firestore listener can sit in `loading` forever (a query that
/// never emits data or an error), and a bare `.when(...)` would spin silently.
///
/// - loading shows a spinner; after [timeout] with still nothing, it flips to
///   an actionable message with Retry;
/// - an error shows a message with Retry;
/// - an empty collection (per [isEmpty]) shows [emptyMessage].
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.onRetry,
    required this.builder,
    this.isEmpty,
    this.emptyMessage = 'Nothing here yet.',
    this.emptyIcon = Icons.inbox_outlined,
    this.timeout = const Duration(seconds: 12),
  });

  final AsyncValue<T> value;

  /// Called by the Retry button — typically `() => ref.invalidate(provider)`.
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;
  final bool Function(T data)? isEmpty;
  final String emptyMessage;
  final IconData emptyIcon;
  final Duration timeout;

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  Timer? _timer;
  bool _timedOut = false;

  bool get _initialLoading =>
      widget.value.isLoading &&
      !widget.value.hasValue &&
      !widget.value.hasError;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AsyncView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// Keeps the timeout timer in step with the loading state, so a healthy idle
  /// stream (emits once, then goes quiet) never trips a false timeout.
  void _sync() {
    if (_initialLoading) {
      _timer ??= Timer(widget.timeout, () {
        if (mounted) setState(() => _timedOut = true);
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _timedOut = false;
    }
  }

  void _retry() {
    _timer?.cancel();
    _timer = null;
    setState(() => _timedOut = false);
    widget.onRetry();
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_timedOut && _initialLoading) {
      return _Message(
        icon: Icons.hourglass_empty,
        title: 'Taking longer than expected',
        detail: 'Check your connection and try again.',
        onRetry: _retry,
      );
    }
    return widget.value.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Message(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        detail: '$e',
        onRetry: _retry,
      ),
      data: (data) {
        if (widget.isEmpty?.call(data) ?? false) {
          return _Message(icon: widget.emptyIcon, title: widget.emptyMessage);
        }
        return widget.builder(context, data);
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: kScreenPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: muted),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
