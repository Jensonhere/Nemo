import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:voicegpt/core/models/conversation_history_turn.dart';
import 'package:voicegpt/core/models/login_result.dart';
import 'package:voicegpt/core/models/private_agent_profile.dart';
import 'package:voicegpt/core/storage/database_factory_configurator.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const _databaseName = 'voicegpt.db';
  static const _databaseVersion = 1;
  static const _activeSessionId = 'active_session';
  static const _migrationKey = 'db_migration_v1_complete';
  static const _legacyPasswordSalt = 'legacy-no-password';

  Database? _db;
  bool _migrated = false;

  Future<void> init() async {
    if (_db != null) return;
    await configureDatabaseFactory();
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, _databaseName);
    _db = await openDatabase(
      dbPath,
      version: _databaseVersion,
      onCreate: _createSchema,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
    await _migrateSharedPreferencesIfNeeded();
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL UNIQUE COLLATE NOCASE,
        email TEXT NOT NULL UNIQUE COLLATE NOCASE,
        password_hash TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        is_first_login INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE app_session (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE private_agent_profiles (
        user_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        persona TEXT NOT NULL,
        style TEXT NOT NULL,
        voice TEXT,
        avatar_type TEXT,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE conversation_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        user_text TEXT NOT NULL,
        assistant_text TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_conversation_history_user_time '
      'ON conversation_history(user_id, created_at DESC)',
    );
  }

  Database get _database {
    final database = _db;
    if (database == null) {
      throw StateError('AppDatabase.init() must be called before use');
    }
    return database;
  }

  Future<User?> getActiveUser() async {
    final rows = await _database.rawQuery('''
      SELECT u.*
      FROM app_session s
      JOIN users u ON u.id = s.user_id
      WHERE s.id = ?
      LIMIT 1
    ''', [_activeSessionId]);
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  Future<void> setActiveUser(String? userId) async {
    await _database.insert(
      'app_session',
      {
        'id': _activeSessionId,
        'user_id': userId,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<LoginResult> login(String account, String password) async {
    final normalized = account.trim();
    if (normalized.isEmpty || password.isEmpty) {
      return LoginResult(success: false, errorCode: 'invalid-input');
    }

    final rows = await _database.query(
      'users',
      where: 'LOWER(username) = ? OR LOWER(email) = ?',
      whereArgs: [
        normalized.toLowerCase(),
        normalized.toLowerCase(),
      ],
      limit: 1,
    );
    if (rows.isEmpty) {
      return LoginResult(success: false, errorCode: 'user-not-found');
    }

    final row = rows.first;
    final salt = row['password_salt'] as String;
    final storedHash = row['password_hash'] as String;
    final inputHash = _derivePasswordHash(password, salt);
    if (inputHash != storedHash) {
      return LoginResult(success: false, errorCode: 'wrong-password');
    }

    final user = _userFromRow(row);
    await setActiveUser(user.id);
    return LoginResult(success: true, user: user);
  }

  Future<LoginResult> register({
    required String username,
    required String email,
    required String password,
  }) async {
    final cleanUsername = username.trim();
    final cleanEmail = email.trim();
    if (cleanUsername.isEmpty || cleanEmail.isEmpty || password.isEmpty) {
      return LoginResult(success: false, errorCode: 'invalid-input');
    }
    if (password.length < 6) {
      return LoginResult(success: false, errorCode: 'weak-password');
    }
    if (!cleanEmail.contains('@')) {
      return LoginResult(success: false, errorCode: 'invalid-email');
    }

    final now = DateTime.now().toIso8601String();
    final salt = _randomSalt();
    final hash = _derivePasswordHash(password, salt);
    final duplicate = await _database.query(
      'users',
      where: 'LOWER(username) = ? OR LOWER(email) = ?',
      whereArgs: [
        cleanUsername.toLowerCase(),
        cleanEmail.toLowerCase(),
      ],
      limit: 1,
    );
    if (duplicate.isNotEmpty) {
      final row = duplicate.first;
      final sameUsername = row['username'].toString().toLowerCase() ==
          cleanUsername.toLowerCase();
      final sameEmail =
          row['email'].toString().toLowerCase() == cleanEmail.toLowerCase();
      if (sameUsername &&
          sameEmail &&
          row['password_salt'] == _legacyPasswordSalt) {
        await _database.update(
          'users',
          {
            'password_hash': hash,
            'password_salt': salt,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        return LoginResult(success: true, user: _userFromRow(row));
      }
      return LoginResult(
        success: false,
        errorCode:
            sameUsername ? 'username-already-in-use' : 'email-already-in-use',
      );
    }

    final id = _buildUserId(cleanUsername, cleanEmail);
    final user = User(
      id: id,
      username: cleanUsername,
      email: cleanEmail,
      isFirstLogin: true,
    );

    await _database.insert('users', {
      'id': id,
      'username': cleanUsername,
      'email': cleanEmail,
      'password_hash': hash,
      'password_salt': salt,
      'is_first_login': 1,
      'created_at': now,
      'updated_at': now,
    });
    return LoginResult(success: true, user: user);
  }

  Future<void> updateFirstLogin(String userId, bool isFirstLogin) async {
    await _database.update(
      'users',
      {
        'is_first_login': isFirstLogin ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  Future<PrivateAgentProfile?> getPrivateAgentProfile(String userId) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return null;
    final rows = await _database.query(
      'private_agent_profiles',
      where: 'user_id = ?',
      whereArgs: [normalizedUserId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return PrivateAgentProfile(
      userId: row['user_id'] as String,
      name: row['name'] as String,
      persona: row['persona'] as String,
      style: row['style'] as String,
      voice: row['voice'] as String?,
      avatarType: row['avatar_type'] as String?,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  Future<bool> upsertPrivateAgentProfile(PrivateAgentProfile profile) async {
    if (profile.userId.trim().isEmpty || !profile.isValid) return false;
    await _database.insert(
      'private_agent_profiles',
      {
        'user_id': profile.userId.trim(),
        'name': profile.name.trim(),
        'persona': profile.persona.trim(),
        'style': profile.style.trim(),
        'voice': profile.voice,
        'avatar_type': profile.avatarType,
        'updated_at': profile.updatedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<List<ConversationHistoryTurn>> getConversationHistory(
    String userId, {
    int limit = 80,
  }) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return const [];
    final rows = await _database.query(
      'conversation_history',
      where: 'user_id = ?',
      whereArgs: [normalizedUserId],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_historyFromRow).where((turn) => turn.isValid).toList();
  }

  Future<void> addConversationHistoryTurn(
    String userId,
    ConversationHistoryTurn turn, {
    int maxTurns = 80,
  }) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty || !turn.isValid) return;
    await _database.insert('conversation_history', {
      'user_id': normalizedUserId,
      'user_text': turn.userText.trim(),
      'assistant_text': turn.assistantText.trim(),
      'created_at': turn.createdAt.toIso8601String(),
    });
    await _database.rawDelete(
      '''
      DELETE FROM conversation_history
      WHERE user_id = ?
        AND id NOT IN (
          SELECT id
          FROM conversation_history
          WHERE user_id = ?
          ORDER BY created_at DESC, id DESC
          LIMIT ?
        )
      ''',
      [normalizedUserId, normalizedUserId, maxTurns],
    );
  }

  Future<void> clearConversationHistory(String userId) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return;
    await _database.delete(
      'conversation_history',
      where: 'user_id = ?',
      whereArgs: [normalizedUserId],
    );
  }

  Future<void> _migrateSharedPreferencesIfNeeded() async {
    if (_migrated) return;
    _migrated = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationKey) == true) return;

    final authUserJson = prefs.getString('auth_user') ?? '';
    if (authUserJson.isNotEmpty) {
      try {
        final jsonMap = jsonDecode(authUserJson) as Map<String, dynamic>;
        final user = User.fromJson(jsonMap);
        await _upsertLegacyUser(user);
        await setActiveUser(user.id);
        await _migrateLegacyPrivateAgent(prefs, user.id);
        await _migrateLegacyHistory(prefs, user.id);
      } catch (_) {}
    }

    await prefs.setBool(_migrationKey, true);
  }

  Future<void> _upsertLegacyUser(User user) async {
    final now = DateTime.now().toIso8601String();
    final placeholderHash =
        _derivePasswordHash(_randomSalt(), _legacyPasswordSalt);
    await _database.insert(
      'users',
      {
        'id': user.id,
        'username': user.username,
        'email': user.email,
        'password_hash': placeholderHash,
        'password_salt': _legacyPasswordSalt,
        'is_first_login': user.isFirstLogin ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _migrateLegacyPrivateAgent(
    SharedPreferences prefs,
    String userId,
  ) async {
    final jsonStr = prefs.getString('private_agent_profile_$userId');
    if (jsonStr == null || jsonStr.isEmpty) return;
    try {
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final profile = PrivateAgentProfile.fromJson(jsonMap);
      await upsertPrivateAgentProfile(profile);
    } catch (_) {}
  }

  Future<void> _migrateLegacyHistory(
    SharedPreferences prefs,
    String userId,
  ) async {
    final jsonStr = prefs.getString('conversation_history_$userId');
    if (jsonStr == null || jsonStr.isEmpty) return;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! List) return;
      for (final item in decoded.reversed) {
        if (item is! Map) continue;
        final turn = ConversationHistoryTurn.fromJson(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
        await addConversationHistoryTurn(userId, turn);
      }
    } catch (_) {}
  }

  User _userFromRow(Map<String, Object?> row) {
    return User(
      id: row['id'] as String,
      username: row['username'] as String,
      email: row['email'] as String,
      isFirstLogin: (row['is_first_login'] as int? ?? 1) == 1,
    );
  }

  ConversationHistoryTurn _historyFromRow(Map<String, Object?> row) {
    return ConversationHistoryTurn(
      userText: row['user_text'] as String,
      assistantText: row['assistant_text'] as String,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  String _buildUserId(String username, String email) {
    final input =
        '${username.trim().toLowerCase()}|${email.trim().toLowerCase()}';
    final digest = sha256.convert(utf8.encode(input)).toString();
    return 'user_${digest.substring(0, 24)}';
  }

  String _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String _derivePasswordHash(String password, String salt) {
    var bytes = utf8.encode('$salt:$password');
    for (var i = 0; i < 12000; i++) {
      bytes = Hmac(sha256, utf8.encode(salt)).convert(bytes).bytes;
    }
    return base64UrlEncode(bytes);
  }
}
