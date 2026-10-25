import '../worker/worker_client.dart';

class PhotoRepository {
  const PhotoRepository(this._worker);
  final WorkerClient _worker;

  Future<Map<String, String>> viewUrls(Iterable<String> publicIds) async {
    final ids = publicIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};
    final result = await _worker.post('/photos/view-urls', {
      'publicIds': ids,
      'variant': 'full',
    });
    final raw = result['urls'];
    if (raw is! Map) throw const WorkerException('invalid-response');
    return raw.map((key, value) => MapEntry(key.toString(), value.toString()));
  }
}
