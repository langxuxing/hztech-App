import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../auth/app_user_role.dart';
import '../secure/prefs.dart';
import '../theme/finance_style.dart';
import '../widgets/water_background.dart';

/// 用户管理弹窗内主文字（与全局 textDefault 一致）
const Color _kUserDialogText = AppFinanceStyle.textDefault;

const TextStyle _userDialogLabel = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
  color: _kUserDialogText,
);

const TextStyle _userDialogField = TextStyle(color: _kUserDialogText);

const TextStyle _userDialogTitle = TextStyle(
  fontSize: 18,
  fontWeight: FontWeight.w600,
  color: _kUserDialogText,
);

TextStyle _userDialogHintStyle() => TextStyle(
  color: _kUserDialogText.withValues(alpha: 0.58),
  fontSize: 13,
);

TextStyle _userDialogCaptionStyle() => TextStyle(
  color: _kUserDialogText.withValues(alpha: 0.88),
  fontSize: 12,
  height: 1.35,
);

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
              : _kUserDialogText,
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

  InputDecoration _userDialogCompactFieldDecoration({String? hint}) {
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      hintText: hint,
      hintStyle: hint != null ? _userDialogHintStyle() : null,
    );
  }

  /// 全名、手机号、角色（类型）同一行。
  Widget _fullNamePhoneRoleRow({
    required TextEditingController fullNameCtrl,
    required TextEditingController phoneCtrl,
    required AppUserRole role,
    required Key roleDropdownKey,
    required void Function(void Function()) setDialogLocal,
    required void Function(AppUserRole newRole) onRoleSelected,
    String fullNameHint = '选填',
    String phoneHint = '选填',
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('全名', style: _userDialogLabel),
              const SizedBox(height: 4),
              TextField(
                controller: fullNameCtrl,
                style: _userDialogField,
                decoration: _userDialogCompactFieldDecoration(hint: fullNameHint),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('手机号', style: _userDialogLabel),
              const SizedBox(height: 4),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                style: _userDialogField,
                decoration: _userDialogCompactFieldDecoration(hint: phoneHint),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('类型', style: _userDialogLabel),
              const SizedBox(height: 4),
              DropdownMenu<AppUserRole>(
                key: roleDropdownKey,
                initialSelection: role,
                textStyle: _userDialogField,
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
                  if (v != null) {
                    setDialogLocal(() => onRoleSelected(v));
                  }
                },
              ),
            ],
          ),
        ),
      ],
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
            return Theme(
              data: Theme.of(ctx).copyWith(
                colorScheme: Theme.of(ctx).colorScheme.copyWith(onSurface: _kUserDialogText),
              ),
              child: AlertDialog(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(ctx).width * 0.5,
              ),
              backgroundColor: const Color(0xFF1a1a24),
              title: const Text(
                '新增用户',
                style: _userDialogTitle,
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('登录名（用户名）', style: _userDialogLabel),
                    const SizedBox(height: 6),
                    TextField(
                      controller: userCtrl,
                      style: _userDialogField,
                      autocorrect: false,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        hintText: '用于登录，不可与已有账号重复',
                        hintStyle: _userDialogHintStyle(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('密码（至少 6 位）', style: _userDialogLabel),
                    const SizedBox(height: 6),
                    TextField(
                      controller: passCtrl,
                      obscureText: true,
                      style: _userDialogField,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('确认密码', style: _userDialogLabel),
                    const SizedBox(height: 6),
                    TextField(
                      controller: pass2Ctrl,
                      obscureText: true,
                      style: _userDialogField,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _fullNamePhoneRoleRow(
                      fullNameCtrl: fullNameCtrl,
                      phoneCtrl: phoneCtrl,
                      role: role,
                      roleDropdownKey: ValueKey<AppUserRole>(role),
                      setDialogLocal: setLocal,
                      onRoleSelected: (r) => role = r,
                      fullNameHint: '选填',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '客户需勾选下方可见账户；其他角色不按账户过滤。',
                      style: _userDialogCaptionStyle(),
                    ),
                    if (role == AppUserRole.customer) ...[
                      const SizedBox(height: 16),
                      const Text(
                        '客户可访问账户（多选）',
                        style: _userDialogLabel,
                      ),
                      const SizedBox(height: 8),
                      if (_accountChoices.isEmpty)
                        Text(
                          '暂无账户列表',
                          style: TextStyle(
                            color: _kUserDialogText.withValues(alpha: 0.9),
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
            ),
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
      builder: (ctx) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(onSurface: _kUserDialogText),
        ),
        child: AlertDialog(
        backgroundColor: const Color(0xFF1a1a24),
        title: const Text(
          '删除用户',
          style: _userDialogTitle,
        ),
        content: Text(
          '确定删除用户「${row.username}」？此操作不可恢复。',
          style: TextStyle(color: _kUserDialogText.withValues(alpha: 0.95)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppFinanceStyle.textLoss,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
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
            return Theme(
              data: Theme.of(ctx).copyWith(
                colorScheme: Theme.of(ctx).colorScheme.copyWith(onSurface: _kUserDialogText),
              ),
              child: AlertDialog(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(ctx).width * 0.5,
              ),
              backgroundColor: const Color(0xFF1a1a24),
              title: Text(
                row.username,
                style: _userDialogTitle,
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '登录名不可在此修改；全名与手机号仅用于展示与联系。',
                      style: _userDialogCaptionStyle(),
                    ),
                    const SizedBox(height: 12),
                    _fullNamePhoneRoleRow(
                      fullNameCtrl: fullNameCtrl,
                      phoneCtrl: phoneCtrl,
                      role: role,
                      roleDropdownKey: ValueKey<AppUserRole>(role),
                      setDialogLocal: setLocal,
                      onRoleSelected: (r) => role = r,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '改为非管理员时，若该用户是最后一位管理员，将无法保存。',
                      style: _userDialogCaptionStyle(),
                    ),
                    if (role == AppUserRole.customer) ...[
                      const SizedBox(height: 16),
                      const Text(
                        '客户可访问账户（多选）',
                        style: _userDialogLabel,
                      ),
                      const SizedBox(height: 8),
                      if (_accountChoices.isEmpty)
                        Text(
                          '暂无账户列表，请先配置 Account_List',
                          style: TextStyle(
                            color: _kUserDialogText.withValues(alpha: 0.9),
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
            ),
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

  Widget _embedHeaderCard(BuildContext context) {
    final titleStyle =
        (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
      color: AppFinanceStyle.labelColor,
      fontSize:
          (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) + 2,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24 + AppFinanceStyle.webSummaryTitleSpacing,
        24,
        8,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: FinanceCard(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: LayoutBuilder(
              builder: (context, c) {
                final narrow = c.maxWidth < 560;
                final actions = FilledButton.tonalIcon(
                  onPressed: _addUser,
                  style: FilledButton.styleFrom(
                    foregroundColor: AppFinanceStyle.profitGreenEnd,
                    backgroundColor:
                        AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.14),
                  ),
                  icon: const Icon(Icons.person_add_outlined, size: 22),
                  label: const Text('新增用户'),
                );
                final headline = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('用户管理', style: titleStyle),
                    const SizedBox(height: 6),
                    Text(
                      '维护登录账号、角色类型与客户可见交易账户',
                      style: AppFinanceStyle.labelTextStyle(context).copyWith(
                        fontSize: 13,
                        color: AppFinanceStyle.textDefault.withValues(
                          alpha: 0.55,
                        ),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '请勿删除全部管理员，至少保留一名可登录的管理员账号。',
                      style: AppFinanceStyle.labelTextStyle(context).copyWith(
                        fontSize: 12,
                        height: 1.45,
                        color: AppFinanceStyle.textDefault.withValues(
                          alpha: 0.48,
                        ),
                      ),
                    ),
                  ],
                );
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      headline,
                      const SizedBox(height: 16),
                      actions,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: headline),
                    const SizedBox(width: 16),
                    actions,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _roleBadge(String roleLabel) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.32),
        ),
      ),
      child: Text(
        roleLabel,
        style: const TextStyle(
          color: AppFinanceStyle.profitGreenEnd,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, {int maxLines = 3}) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: AppFinanceStyle.labelColor.withValues(alpha: 0.62),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppFinanceStyle.valueColor,
                fontSize: 14,
                height: 1.4,
              ),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _userCard(ManagedUserRow u) {
    final roleEnum = AppUserRole.fromApi(u.role);
    final roleLabel = AppUserRole.label(roleEnum);
    final phoneDisp = u.phone.isEmpty ? '—' : u.phone;
    final nameDisp =
        u.fullName.trim().isEmpty ? '—' : u.fullName.trim();
    final accounts = u.linkedAccountIds;
    final accountsEmptyHint = roleEnum == AppUserRole.customer
        ? '未绑定'
        : '—';
    final accountsText = accounts.isEmpty
        ? accountsEmptyHint
        : accounts.join('，');

    final profileParts = <String>[];
    if (nameDisp != '—') profileParts.add(nameDisp);
    if (phoneDisp != '—') profileParts.add(phoneDisp);
    final profileSub = profileParts.isEmpty ? null : profileParts.join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _editUser(u),
        borderRadius: BorderRadius.circular(AppFinanceStyle.cardRadius),
        child: FinanceCard(
          padding: const EdgeInsets.fromLTRB(20, 18, 8, 18),
          child: LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 520;
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '编辑资料、角色与可见账户',
                    icon: const Icon(
                      Icons.edit_outlined,
                      color: AppFinanceStyle.labelColor,
                    ),
                    onPressed: () => _editUser(u),
                  ),
                  IconButton(
                    tooltip: '删除用户',
                    icon: Icon(
                      Icons.delete_outline,
                      color: AppFinanceStyle.textLoss.withValues(alpha: 0.92),
                    ),
                    onPressed: () => _deleteUser(u),
                  ),
                ],
              );
              final titleBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    u.username,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontSize: (Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.fontSize ??
                                  22) +
                              2,
                          color: AppFinanceStyle.valueColor,
                          letterSpacing: -0.35,
                        ),
                  ),
                  if (profileSub != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      profileSub,
                      style: AppFinanceStyle.labelTextStyle(context).copyWith(
                        fontSize: 13,
                        color: AppFinanceStyle.textDefault.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ],
                ],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (narrow)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: titleBlock),
                            actions,
                          ],
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _roleBadge(roleLabel),
                        ),
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: titleBlock),
                        const SizedBox(width: 12),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _roleBadge(roleLabel),
                        ),
                        actions,
                      ],
                    ),
                  _detailRow('中文名', nameDisp),
                  _detailRow('手机号', phoneDisp),
                  _detailRow(
                    roleEnum == AppUserRole.customer ? '可访问账户' : '账户范围',
                    roleEnum == AppUserRole.customer
                        ? accountsText
                        : '非客户角色不按账户过滤',
                    maxLines: roleEnum == AppUserRole.customer ? 5 : 2,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: FinanceCard(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.group_add_outlined,
                  size: 52,
                  color: AppFinanceStyle.labelColor.withValues(alpha: 0.45),
                ),
                const SizedBox(height: 20),
                Text(
                  '暂无用户',
                  style: AppFinanceStyle.labelTextStyle(context).copyWith(
                        color: AppFinanceStyle.valueColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.embedInShell
                      ? '使用上方「新增用户」创建第一个登录账号'
                      : '点击下方按钮创建第一个登录账号',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppFinanceStyle.labelColor.withValues(alpha: 0.72),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                if (!widget.embedInShell) ...[
                  const SizedBox(height: 24),
                  FilledButton.tonalIcon(
                    onPressed: _addUser,
                    style: FilledButton.styleFrom(
                      foregroundColor: AppFinanceStyle.profitGreenEnd,
                      backgroundColor: AppFinanceStyle.profitGreenEnd
                          .withValues(alpha: 0.14),
                    ),
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('新增用户'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showFab = !widget.embedInShell &&
        !_loading &&
        _error == null &&
        _users.isNotEmpty;

    late final Widget main;
    if (_loading) {
      main = const Center(
        child: CircularProgressIndicator(color: AppFinanceStyle.profitGreenEnd),
      );
    } else if (_error != null) {
      main = Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: FinanceCard(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppFinanceStyle.labelColor),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _reload,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      main = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.embedInShell) _embedHeaderCard(context),
          Expanded(
            child: RefreshIndicator(
              color: AppFinanceStyle.profitGreenEnd,
              onRefresh: _reload,
              child: _users.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 48),
                      children: [_emptyState()],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        24,
                        widget.embedInShell ? 8 : 16,
                        24,
                        showFab ? 88 : 32,
                      ),
                      itemCount: _users.length,
                      itemBuilder: (ctx, i) {
                        final gap = i < _users.length - 1 ? 14.0 : 0.0;
                        return Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1600),
                            child: Padding(
                              padding: EdgeInsets.only(bottom: gap),
                              child: _userCard(_users[i]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppFinanceStyle.backgroundDark,
      floatingActionButton: showFab
          ? FloatingActionButton.extended(
              onPressed: _addUser,
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('新增用户'),
              backgroundColor:
                  AppFinanceStyle.profitGreenEnd.withValues(alpha: 0.85),
            )
          : null,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              title: Text(
                '用户管理',
                style: AppFinanceStyle.labelTextStyle(context).copyWith(
                  color: AppFinanceStyle.valueColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              actions: [
                if (!_loading && _error == null)
                  IconButton(
                    tooltip: '新增用户',
                    icon: Icon(
                      Icons.person_add_outlined,
                      color: AppFinanceStyle.profitGreenEnd.withValues(
                        alpha: 0.95,
                      ),
                    ),
                    onPressed: _addUser,
                  ),
              ],
              backgroundColor: AppFinanceStyle.backgroundDark,
              foregroundColor: AppFinanceStyle.valueColor,
              surfaceTintColor: Colors.transparent,
            ),
      body: ColoredBox(
        color: AppFinanceStyle.backgroundDark,
        child: WaterBackground(child: main),
      ),
    );
  }
}
