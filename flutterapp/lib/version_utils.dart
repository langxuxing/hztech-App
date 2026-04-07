/// 语义版本比较（仅比较 `+` 之前的 major.minor.patch，缺失段视为 0）。
int compareSemanticVersion(String a, String b) {
  final pa = parseSemanticVersionParts(a);
  final pb = parseSemanticVersionParts(b);
  for (var i = 0; i < 3; i++) {
    final c = pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return 0;
}

List<int> parseSemanticVersionParts(String v) {
  final trimmed = v.trim();
  if (trimmed.isEmpty) return [0, 0, 0];
  final main = trimmed.split('+').first.trim();
  final parts = main.split('.');
  int p(int i) {
    if (i >= parts.length) return 0;
    return int.tryParse(parts[i].trim()) ?? 0;
  }
  return [p(0), p(1), p(2)];
}

/// [required] 为空时不视为「需要更高版本」。
bool isVersionLower(String current, String? required) {
  final r = required?.trim() ?? '';
  if (r.isEmpty) return false;
  return compareSemanticVersion(current, r) < 0;
}
