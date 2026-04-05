import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../auth/app_user_role.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';

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
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addUser() async {
    var role = AppUserRole.trader;
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
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
                    Text('用户名', style: AppFinanceStyle.labelTextStyle(context)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: userCtrl,
                      style: const TextStyle(color: AppFinanceStyle.valueColor),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('密码', style: AppFinanceStyle.labelTextStyle(context)),
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
                    const SizedBox(height: 16),
                    Text('角色 / 权限', style: AppFinanceStyle.labelTextStyle(context)),
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
                            return FilterChip(
                              label: Text(
                                id,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: on
                                      ? AppFinanceStyle.profitGreenEnd
                                      : AppFinanceStyle.valueColor,
                                ),
                              ),
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
    final newPassword = passCtrl.text;
    userCtrl.dispose();
    passCtrl.dispose();
    if (ok != true || !mounted) return;
    final u = newUsername;
    final p = newPassword;
    if (u.isEmpty || p.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入用户名和密码')),
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
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已创建用户')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e')),
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
      final deleted = await api.deleteUser(row.id);
      if (!mounted) return;
      if (!deleted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除异常: $e')),
      );
    }
  }

  Future<void> _editUser(ManagedUserRow row) async {
    var role = AppUserRole.fromApi(row.role);
    var selected = Set<String>.from(row.linkedAccountIds);
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
                    Text('角色', style: AppFinanceStyle.labelTextStyle(context)),
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
                            return FilterChip(
                              label: Text(
                                id,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: on
                                      ? AppFinanceStyle.profitGreenEnd
                                      : AppFinanceStyle.valueColor,
                                ),
                              ),
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
    if (ok != true || !mounted) return;
    try {
      final base = await _prefs.backendBaseUrl;
      final token = await _prefs.authToken;
      final api = ApiClient(base, token: token);
      final links = role == AppUserRole.customer ? selected.toList() : <String>[];
      final updated = await api.patchUser(
        row.id,
        role: role.apiValue,
        linkedAccountIds: role == AppUserRole.customer ? links : [],
      );
      if (!mounted) return;
      if (updated == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存异常: $e')),
      );
    }
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
            : RefreshIndicator(
                onRefresh: _reload,
                child: ListView.separated(
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
                          '${AppUserRole.label(AppUserRole.fromApi(u.role))}'
                          '${u.linkedAccountIds.isNotEmpty ? ' · ${u.linkedAccountIds.length} 个绑定账户' : ''}',
                          style: TextStyle(
                            color: AppFinanceStyle.labelColor.withValues(alpha: 0.95),
                            fontSize: 13,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '编辑权限',
                              icon: const Icon(Icons.edit_outlined,
                                  color: AppFinanceStyle.labelColor),
                              onPressed: () => _editUser(u),
                            ),
                            IconButton(
                              tooltip: '删除',
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
              );

    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      floatingActionButton: _loading || _error != null
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
