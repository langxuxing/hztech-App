/// 将网络/连接类异常转为面向用户的简短中文提示。
String friendlyNetworkError(Object e) {
  final lower = e.toString().toLowerCase();
  if (lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('network is unreachable') ||
      lower.contains('clientexception') ||
      lower.contains('handshakeexception') ||
      lower.contains('timed out') ||
      lower.contains('timeout')) {
    return '无法连接服务器，请检查网络或在「应用设置」中填写正确的服务器地址。';
  }
  return e.toString();
}

/// 与 [friendlyNetworkError] 相同，保留旧名称供个别界面调用。
String networkErrorMessage(Object e) => friendlyNetworkError(e);
