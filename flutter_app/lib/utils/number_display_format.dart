/// 界面展示用：金额/数量等为整数；百分比单独 [formatUiPercentLabel] 一位小数。

String _digitsWithGrouping(int n) {
  // 不带千分号，直接返回字符串
  return n.toString();
}

String formatUiInteger(double v) {
  if (!v.isFinite) return '—';
  return _digitsWithGrouping(v.round());
}

String formatUiIntegerOpt(double? v) {
  if (v == null || !v.isFinite) return '—';
  return _digitsWithGrouping(v.round());
}

/// 带正负号的整数（如盈亏列）。
String formatUiSignedInteger(double v) {
  if (!v.isFinite) return '—';
  final r = v.round();
  if (r > 0) return '+${_digitsWithGrouping(r)}';
  return _digitsWithGrouping(r);
}

/// 百分比标签：`12.3%`
String formatUiPercentLabel(double v) {
  if (!v.isFinite) return '—';
  return '${v.toStringAsFixed(1)}%';
}

/// 日历等场景：带符号、两位小数的 USDT 文案，如 `+33.90`、`-12.05`。
String formatUiSignedUsdt2(double v) {
  if (!v.isFinite) return '—';
  if (v > 0) return '+${v.toStringAsFixed(2)}';
  if (v < 0) return v.toStringAsFixed(2);
  return v.toStringAsFixed(2);
}
