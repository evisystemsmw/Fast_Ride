import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthPersistence {
  static const _uidKey = 'auth_uid';
  static const _roleKey = 'auth_role';
  static const _profileKey = 'auth_profile';

  static Future<bool> hasInternetConnection() async {
    final results = await Connectivity().checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  static Stream<bool> connectionStatusStream() {
    return Connectivity().onConnectivityChanged.map(
      (results) => results.any((r) => r != ConnectivityResult.none),
    );
  }

  static Future<void> saveSession({
    required String uid,
    String? role,
    String? fcmToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uidKey, uid);
    if (role != null) await prefs.setString(_roleKey, role);
  }

  static Future<String?> loadUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_uidKey);
  }

  static Future<String?> loadRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_roleKey);
  }

  static Future<void> saveProfileSnapshot(Map<String, dynamic> profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, jsonEncode(profile));
  }

  static Future<Map<String, dynamic>?> loadProfileSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profileKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await FirebaseAuth.instance.signOut();
  }

  static Future<void> signOut() => clearCredentials();

  static const _pendingNotifsKey = 'pending_notifications';

  static Future<void> savePendingNotification(Map<String, dynamic> notif) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingNotifsKey);
    final list = raw != null ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    list.add(notif);
    await prefs.setString(_pendingNotifsKey, jsonEncode(list));
  }

  static Future<List<Map<String, dynamic>>> loadPendingNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingNotifsKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearPendingNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingNotifsKey);
  }
}
