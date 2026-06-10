import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:voicegpt/core/models/login_result.dart';
import 'package:voicegpt/core/storage/preference_manager.dart';

/// 用户状态管理通知器
/// 负责登录/注册/会话恢复与私人智能体配置所需的用户 ID
class UserNotifier with ChangeNotifier {
  User? _currentUser;
  bool _isLoading = false;
  String? _errorMessage;
  bool _hasRestored = false;

  User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isLoggedIn => _currentUser != null;

  /// 登录方法（本地模拟登录）
  Future<LoginResult> login(String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await Future.delayed(const Duration(milliseconds: 700));

      if (username.trim().isEmpty || password.isEmpty) {
        _isLoading = false;
        _errorMessage = '请输入用户名和密码';
        notifyListeners();
        return LoginResult(
          success: false,
          errorCode: 'invalid-input',
        );
      }

      final normalizedUsername = username.trim();
      final bool isEmail = normalizedUsername.contains('@');
      final localUserId = isEmail
          ? 'local_email_${normalizedUsername.toLowerCase()}'
          : 'local_name_${normalizedUsername.toLowerCase()}';

      final user = User(
        id: localUserId,
        username: normalizedUsername,
        email: isEmail
            ? normalizedUsername
            : '${normalizedUsername}_local@example.com',
        isFirstLogin: true,
      );

      _currentUser = user;
      _isLoading = false;
      _errorMessage = null;
      notifyListeners();

      final prefs = PreferenceManager();
      await prefs.setUserId(user.id);
      await prefs.setAuthUser(jsonEncode(user.toJson()));

      return LoginResult(success: true, user: user);
    } catch (e) {
      _isLoading = false;
      _errorMessage = '登录失败: $e';
      notifyListeners();
      return LoginResult(success: false, errorCode: 'network-error');
    }
  }

  /// 注册方法（本地模拟注册）
  Future<bool> register(String username, String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await Future.delayed(const Duration(milliseconds: 700));

      if (username.trim().isEmpty || email.trim().isEmpty || password.isEmpty) {
        _isLoading = false;
        _errorMessage = '请填写完整信息';
        notifyListeners();
        return false;
      }
      if (password.length < 6) {
        _isLoading = false;
        _errorMessage = '密码至少需要6位';
        notifyListeners();
        return false;
      }

      _isLoading = false;
      _errorMessage = null;
      notifyListeners();
      return true;
    } catch (e) {
      _isLoading = false;
      _errorMessage = '注册失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 完成首次设置（本地标记）
  Future<bool> completeFirstTimeSetup() async {
    if (_currentUser == null) return false;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await Future.delayed(const Duration(milliseconds: 500));

      _currentUser = User(
        id: _currentUser!.id,
        username: _currentUser!.username,
        email: _currentUser!.email,
        isFirstLogin: false,
      );

      await PreferenceManager().setAuthUser(
        jsonEncode(_currentUser!.toJson()),
      );

      _isLoading = false;
      _errorMessage = null;
      notifyListeners();
      return true;
    } catch (e) {
      _isLoading = false;
      _errorMessage = '设置保存失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 登出
  Future<void> logout() async {
    _currentUser = null;
    _errorMessage = null;
    _isLoading = false;
    notifyListeners();

    final prefs = PreferenceManager();
    await prefs.clearAuthUser();
    await prefs.setUserId('');
  }

  /// 从本地恢复会话（只执行一次）
  Future<void> restoreSession() async {
    if (_hasRestored) return;
    _hasRestored = true;

    final prefs = PreferenceManager();
    final stored = prefs.getAuthUser();
    if (stored.isEmpty) return;

    try {
      final jsonMap = jsonDecode(stored) as Map<String, dynamic>;
      final user = User.fromJson(jsonMap);
      _currentUser = user;

      final currentUserId = prefs.getUserId();
      if (currentUserId.trim().isEmpty || currentUserId.trim() != user.id) {
        await prefs.setUserId(user.id);
      }

      notifyListeners();
    } catch (_) {
      // 忽略解析失败
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
