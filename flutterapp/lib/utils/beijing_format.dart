// 展示用：毫秒时间戳或 ISO 字符串格式化为北京时间（固定 UTC+8，无夏令时）。

String _two(int x) => x.toString().padLeft(2, '0');

/// `c_time_ms` / `u_time_ms` 等 epoch 毫秒字符串 → `yyyy-MM-dd HH:mm:ss`（北京）
String formatEpochMsAsBeijing(String? ms) {
  if (ms == null || ms.isEmpty) return '—';
  final v = int.tryParse(ms.trim());
  if (v == null) return ms;
  final utc = DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
  final bj = utc.add(const Duration(hours: 8));
  return '${bj.year}-${_two(bj.month)}-${_two(bj.day)} '
      '${_two(bj.hour)}:${_two(bj.minute)}:${_two(bj.second)}';
}

/// 赛季 API 的 ISO 时间 → 北京同格式（解析为 UTC 后 +8）
String formatIsoAsBeijing(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  try {
    final dt = DateTime.parse(iso.trim());
    final utc = dt.isUtc ? dt : dt.toUtc();
    final bj = utc.add(const Duration(hours: 8));
    return '${bj.year}-${_two(bj.month)}-${_two(bj.day)} '
        '${_two(bj.hour)}:${_two(bj.minute)}:${_two(bj.second)}';
  } catch (_) {
    return iso;
  }
}
