/// 登录结果模型
class LoginResult {
  /// 是否登录成功
  final bool success;

  /// 错误码（如果登录失败）
  final String? errorCode;

  /// 用户信息（如果登录成功）
  final User? user;

  LoginResult({
    required this.success,
    this.errorCode,
    this.user,
  });
}

/// 用户模型（简化版，用于本地登录/注册与状态恢复）
class User {
  final String id;
  final String username;
  final String email;
  final bool isFirstLogin;

  const User({
    required this.id,
    required this.username,
    required this.email,
    this.isFirstLogin = true,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      username: json['username'] as String,
      email: json['email'] as String,
      isFirstLogin: (json['isFirstLogin'] as bool?) ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'isFirstLogin': isFirstLogin,
    };
  }
}
