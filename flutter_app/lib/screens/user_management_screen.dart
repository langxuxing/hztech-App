import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../auth/app_user_role.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';

String _userFacingError(Object e) {
  if (e is StateError) {
    final m = e.message;
    if (m.isNotEmpty) return m;
  }
  final s = e.toString();
  if (s.startsWith('StateError: ')) {
    return s.substring('StateError: '.length).trim();
  }
  if (s.startsWith('Exception: ')) {
    return s.substring('Exception: '.length).trim();
  }
  if (s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('Connection refused')) {
    return '网络异常，请检查网络与后端地址';
  }
  if (s.contains('TimeoutException')) {
    return '请求超时，请稍后重试';
  }
  return '操作失败，请稍后重试';
}

/// 管理员：维护用户角色与客户可见账户（绑定 tradingbot_id / account_id）。
class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key, this.embedInShell = false});

  final bool embedInShell;

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final _prefs = SecurePrefs();
  List<ManagedUserRow> _users = [];
  List<String> _accountChoices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 深色对话框内的客户账户多选：避免默认 Chip 浅色底与浅色字对比度不足。
  Widget _customerAccountFilterChip({
    required String id,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(
        id,
        style: TextStyle(
          fontSize: 12,
          color: selected
              ? AppFinanceStyle.profitGreenEnd
              : AppFinanceStyle.valueColor,
        ),
      ),
      selected: selected,
      onSelected: onSelected,
      backgroundColor: const Color(0xFF2a2a36),
      selectedColor: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.22),
      checkmarkColor: AppFinanceStyle.profitGreenEnd,
      side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      surfaceTintColor: Colors.transparent,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      final users = await api.getUsersList();
      final botsResp = await api.getTradingBots();
      final ids = botsResp.botList.map((b) => b.tradingbotId).where((s) => s.isNotEmpty).toList();
      if (!mounted) return;
      setState(() {
        _users = users;
        _accountChoices = ids.toSet().toList()..sort();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _userFacingError(e);
        _loading = false;
      });
    }
  }

  Future<void> _addUser() async {
    var role = AppUserRole.trader;
    final userCtrl = TextEditingController();
    final fullNameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final pass2Ctrl = TextEditingController();
    var selected = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1a1a24),
              title: Text(
                '新增用户',
                style: const TextStyle(color: AppFinanceStyle.valueColor),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('登录名（用户名）', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: userCtrl,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      autocorrect: false,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        hintText: '用于登录，不可与已有账号重复',
                        hintStyle: TextStyle(
                          color: AppFinanceStyle.labelColor.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('全名', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: fullNameCtrl,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        hintText: '选填，用于列表展示',
                        hintStyle: TextStyle(
                          color: AppFinanceStyle.labelColor.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('手机号', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        hintText: '选填',
                        hintStyle: TextStyle(
                          color: AppFinanceStyle.labelColor.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('密码（至少 6 位）', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: passCtrl,
                      obscureText: true,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('确认密码', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: pass2Ctrl,
                      obscureText: true,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('角色', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 4),
                    Text(
                      '客户需勾选下方可见账户；其他角色不按账户过滤。',
                      style: TextStyle(
                        color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownMenu<AppUserRole>(
                      key: ValueKey<AppUserRole>(role),
                      initialSelection: role,
                      textStyle: const TextStyle(color: AppFinanceStyle.valueColor),
                      menuStyle: MenuStyle(
                        backgroundColor: WidgetStateProperty.all(const Color(0xFF2a2a36)),
                      ),
                      dropdownMenuEntries: [
                        for (final r in AppUserRole.assignableRoles())
                          DropdownMenuEntry(
                            value: r,
                            label: AppUserRole.label(r),
                          ),
                      ],
                      onSelected: (v) {
                        if (v != null) setLocal(() => role = v);
                      },
                    ),
                    if (role == AppUserRole.customer) ...[
                      const SizedBox(height: 16),
                      Text(
                        '客户可访问账户（多选）',
                        style: AppFinanceStyle.labelTextStyle(context),
                      ),
                      const SizedBox(height: 8),
                      if (_accountChoices.isEmpty)
                        Text(
                          '暂无账户列表',
                          style: TextStyle(
                            color: AppFinanceStyle.labelColor.withValues(alpha: 0.9),
                            fontSize: 13,
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _accountChoices.map((id) {
                            final on = selected.contains(id);
                            return _customerAccountFilterChip(
                              id: id,
                              selected: on,
                              onSelected: (v) {
                                setLocal(() {
                                  if (v) {
                                    selected.add(id);
                                  } else {
                                    selected.remove(id);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('创建'),
                ),
              ],
            );
          },
        );
      },
    );
    final newUsername = userCtrl.text.trim();
    final newFullName = fullNameCtrl.text.trim();
    final newPhone = phoneCtrl.text.trim();
    final newPassword = passCtrl.text;
    final newPassword2 = pass2Ctrl.text;
    userCtrl.dispose();
    fullNameCtrl.dispose();
    phoneCtrl.dispose();
    passCtrl.dispose();
    pass2Ctrl.dispose();
    if (ok != true || !mounted) return;
    final u = newUsername;
    final p = newPassword;
    if (u.isEmpty || p.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入用户名和密码')),
      );
      return;
    }
    if (p.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码至少 6 位')),
      );
      return;
    }
    if (p != newPassword2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('两次输入的密码不一致')),
      );
      return;
    }
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      final links =
          role == AppUserRole.customer ? selected.toList() : <String>[];
      await api.createUser(
        username: u,
        password: p,
        role: role.apiValue,
        linkedAccountIds:
            role == AppUserRole.customer ? links : null,
        fullName: newFullName.isEmpty ? null : newFullName,
        phone: newPhone.isEmpty ? null : newPhone,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已创建用户')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_userFacingError(e))),
      );
    }
  }

  Future<void> _deleteUser(ManagedUserRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a24),
        title: const Text(
          '删除用户',
          style: TextStyle(color: AppFinanceStyle.valueColor),
        ),
        content: Text(
          '确定删除用户「${row.username}」？此操作不可恢复。',
          style: TextStyle(color: AppFinanceStyle.labelColor.withValues(alpha: 0.95)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      await api.deleteUser(row.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_userFacingError(e))),
      );
    }
  }

  Future<void> _editUser(ManagedUserRow row) async {
    var role = AppUserRole.fromApi(row.role);
    var selected = Set<String>.from(row.linkedAccountIds);
    final fullNameCtrl = TextEditingController(text: row.fullName);
    final phoneCtrl = TextEditingController(text: row.phone);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1a1a24),
              title: Text(
                row.username,
                style: const TextStyle(color: AppFinanceStyle.valueColor),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '登录名不可在此修改；全名与手机号仅用于展示与联系。',
                      style: TextStyle(
                        color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('全名', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: fullNameCtrl,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        hintText: '选填',
                        hintStyle: TextStyle(
                          color: AppFinanceStyle.labelColor.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('手机号', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        hintText: '选填',
                        hintStyle: TextStyle(
                          color: AppFinanceStyle.labelColor.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('角色', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 4),
                    Text(
                      '改为非管理员时，若该用户是最后一位管理员，将无法保存。',
                      style: TextStyle(
                        color: AppFinanceStyle.labelColor.withValues(alpha: 0.85),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownMenu<AppUserRole>(
                      key: ValueKey<AppUserRole>(role),
                      initialSelection: role,
                      textStyle: const TextStyle(color: AppFinanceStyle.valueColor),
                      menuStyle: MenuStyle(
                        backgroundColor: WidgetStateProperty.all(const Color(0xFF2a2a36)),
                      ),
                      dropdownMenuEntries: [
                        for (final r in AppUserRole.assignableRoles())
                          DropdownMenuEntry(
                            value: r,
                            label: AppUserRole.label(r),
                          ),
                      ],
                      onSelected: (v) {
                        if (v != null) setLocal(() => role = v);
                      },
                    ),
                    if (role == AppUserRole.customer) ...[
                      const SizedBox(height: 16),
                      Text(
                        '客户可访问账户（多选）',
                        style: AppFinanceStyle.labelTextStyle(context),
                      ),
                      const SizedBox(height: 8),
                      if (_accountChoices.isEmpty)
                        Text(
                          '暂无账户列表，请先配置 Account_List',
                          style: TextStyle(
                            color: AppFinanceStyle.labelColor.withValues(alpha: 0.9),
                            fontSize: 13,
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _accountChoices.map((id) {
                            final on = selected.contains(id);
                            return _customerAccountFilterChip(
                              id: id,
                              selected: on,
                              onSelected: (v) {
                                setLocal(() {
                                  if (v) {
                                    selected.add(id);
                                  } else {
                                    selected.remove(id);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    final editedFullName = fullNameCtrl.text.trim();
    final editedPhone = phoneCtrl.text.trim();
    fullNameCtrl.dispose();
    phoneCtrl.dispose();
    if (ok != true || !mounted) return;
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      final links = role == AppUserRole.customer ? selected.toList() : <String>[];
      await api.patchUser(
        row.id,
        role: role.apiValue,
        linkedAccountIds: role == AppUserRole.customer ? links : [],
        fullName: editedFullName,
        phone: editedPhone,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_userFacingError(e))),
      );
    }
  }

  Widget _embedHintBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: const Color(0xFF1e1e2a),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            '在此维护登录账号、角色与客户可见账户。请勿删除全部管理员；至少保留一名可登录的管理员账号。',
            style: TextStyle(
              color: AppFinanceStyle.labelColor.withValues(alpha: 0.95),
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.group_add_outlined,
            size: 56,
            color: AppFinanceStyle.labelColor.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无用户',
            style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  color: AppFinanceStyle.valueColor,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右下角「新增用户」创建第一个账号',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppFinanceStyle.labelColor.withValues(alpha: 0.9),
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _addUser,
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('新增用户'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppFinanceStyle.labelColor),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _reload, child: const Text('重试')),
                    ],
                  ),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.embedInShell) _embedHintBanner(),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _reload,
                      child: _users.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.only(bottom: 88),
                              children: [_emptyState()],
                            )
                          : ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
                              itemCount: _users.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (ctx, i) {
                                final u = _users[i];
                                return Material(
                                  color: const Color(0xFF16161f),
                                  borderRadius: BorderRadius.circular(12),
                                  child: ListTile(
                                    title: Text(
                                      u.username,
                                      style: const TextStyle(
                                        color: AppFinanceStyle.valueColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      () {
                                        final parts = <String>[
                                          AppUserRole.label(AppUserRole.fromApi(u.role)),
                                          if (u.fullName.isNotEmpty) u.fullName,
                                          if (u.phone.isNotEmpty) u.phone,
                                          if (u.linkedAccountIds.isNotEmpty)
                                            '${u.linkedAccountIds.length} 个绑定账户',
                                        ];
                                        return parts.join(' · ');
                                      }(),
                                      style: TextStyle(
                                        color: AppFinanceStyle.labelColor.withValues(alpha: 0.95),
                                        fontSize: 13,
                                      ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: '编辑资料、角色与可见账户',
                                          icon: const Icon(Icons.edit_outlined,
                                              color: AppFinanceStyle.labelColor),
                                          onPressed: () => _editUser(u),
                                        ),
                                        IconButton(
                                          tooltip: '删除用户',
                                          icon: Icon(Icons.delete_outline,
                                              color: Colors.red.shade300),
                                          onPressed: () => _deleteUser(u),
                                        ),
                                      ],
                                    ),
                                    onTap: () => _editUser(u),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              );

    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      floatingActionButton: _loading || _error != null || _users.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _addUser,
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('新增用户'),
              backgroundColor: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.85),
            ),
      appBar: widget.embedInShell
          ? null
          : AppBar(
              title: Text(
                '用户管理',
                style: AppFinanceStyle.labelTextStyle(context).copyWith(
                      color: AppFinanceStyle.valueColor,
                      fontSize: 18,
                    ),
              ),
              backgroundColor: AppFinanceStyle.backgroundDark,
              foregroundColor: AppFinanceStyle.valueColor,
              surfaceTintColor: Colors.transparent,
            ),
      body: body,
    );
  }
}
