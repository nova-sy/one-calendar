import 'package:dio/dio.dart';

class UpdateInfo {
  final String version; // e.g. "1.2.0"
  final String url; // release page
  final String notes;
  const UpdateInfo({required this.version, required this.url, required this.notes});
}

/// Checks the GitHub Releases API for a newer version than [currentVersion].
class UpdateChecker {
  final String repo;
  final String currentVersion;
  final Dio _dio;

  UpdateChecker({
    required this.currentVersion,
    this.repo = 'nova-sy/one-calendar',
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              validateStatus: (_) => true,
              headers: {'User-Agent': 'OneCalendar', 'Accept': 'application/vnd.github+json'},
            ));

  Future<UpdateInfo?> check() async {
    final res = await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repo/releases/latest');
    if (res.statusCode != 200 || res.data == null) return null;
    final tag = (res.data!['tag_name'] as String?) ?? '';
    final latest = _normalize(tag);
    if (latest.isEmpty || !isNewer(latest, currentVersion)) return null;
    return UpdateInfo(
      version: latest,
      url: (res.data!['html_url'] as String?) ?? 'https://github.com/$repo/releases/latest',
      notes: (res.data!['body'] as String?) ?? '',
    );
  }

  static String _normalize(String tag) => tag.startsWith('v') ? tag.substring(1) : tag;

  /// True if [a] is a higher semantic version than [b].
  static bool isNewer(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i] > pb[i];
    }
    return false;
  }

  static List<int> _parts(String v) {
    final core = v.split('+').first.split('-').first;
    final nums = core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    while (nums.length < 3) {
      nums.add(0);
    }
    return nums;
  }
}
