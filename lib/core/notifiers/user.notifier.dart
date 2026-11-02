import 'package:flutter/material.dart';
import 'package:voicegpt/core/models/login_result.dart';
import 'package:voicegpt/core/storage/app_database.dart';

/// 用户状态管理通知器
/// 负责数据库登录/注册/会话恢复与私人智能体配置所需的用户 ID
class UserNotifier with ChangeNotifier {
  User? _currentUser;
  bool _isLoading = false;
  String? _errorMessage;
  bool _hasRestored = false;

  User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isLoggedIn => _currentUser != null;

  Future<LoginResult> login(String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await AppDatabase.instance.login(username, password);
      if (!result.success || result.user == null) {
        _isLoading = false;
        _errorMessage = _messageForLoginError(result.errorCode);
        notifyListeners();
        return result;
      }

      _currentUser = result.user;
      _isLoading = false;
      _errorMessage = null;
      notifyListeners();
      return result;
    } catch (e) {
      _isLoading = false;
      _errorMessage = '登录失败: $e';
      notifyListeners();
      return LoginResult(success: false, errorCode: 'database-error');
    }
  }

  Future<bool> register(String username, String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await AppDatabase.instance.register(
        username: username,
        email: email,
        password: password,
      );
      _isLoading = false;
      _errorMessage =
          result.success ? null : _messageForRegisterError(result.errorCode);
      notifyListeners();
      return result.success;
    } catch (e) {
      _isLoading = false;
      _errorMessage = '注册失败: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> completeFirstTimeSetup() async {
    if (_currentUser == null) return false;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await AppDatabase.instance.updateFirstLogin(_currentUser!.id, false);
      _currentUser = User(
        id: _currentUser!.id,
        username: _currentUser!.username,
        email: _currentUser!.email,
        isFirstLogin: false,
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

  Future<void> logout() async {
    _currentUser = null;
    _errorMessage = null;
    _isLoading = false;
    notifyListeners();

    await AppDatabase.instance.setActiveUser(null);
  }

  Future<void> restoreSession() async {
    if (_hasRestored) return;
    _hasRestored = true;

    try {
      _currentUser = await AppDatabase.instance.getActiveUser();
      if (_currentUser != null) notifyListeners();
    } catch (_) {}
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  String _messageForLoginError(String? code) {
    switch (code) {
      case 'invalid-input':
        return '请输入用户名/邮箱和密码';
      case 'user-not-found':
        return '账号不存在，请先注册';
      case 'wrong-password':
        return '密码不正确';
      default:
        return '登录失败';
    }
  }

  String _messageForRegisterError(String? code) {
    switch (code) {
      case 'invalid-input':
        return '请填写完整信息';
      case 'invalid-email':
        return '邮箱格式不正确';
      case 'weak-password':
        return '密码至少需要6位';
      case 'username-already-in-use':
        return '用户名已被注册';
      case 'email-already-in-use':
        return '邮箱已被注册';
      default:
        return '注册失败';
    }
  }
}
