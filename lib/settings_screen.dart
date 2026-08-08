import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'db.dart';
import 'policy_screen.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushNotifications = true;
  bool _rideUpdates = true;
  bool _alwaysUseLocation = true;
  String _language = 'English';
  bool _loading = true;

  static const _languages = ['English', 'Arabic', 'French', 'Spanish'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc = await db.collection('users').doc(uid).get();
    if (doc.exists && mounted) {
      final s = doc.data()?['settings'] as Map<String, dynamic>? ?? {};
      setState(() {
        _pushNotifications = s['pushNotifications'] ?? true;
        _rideUpdates = s['rideUpdates'] ?? true;
        _alwaysUseLocation = s['alwaysUseLocation'] ?? true;
        _language = s['language'] ?? 'English';
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _updateBool(String key, bool value) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await db.collection('users').doc(uid).update({'settings.$key': value});
  }

  Future<void> _updateString(String key, String value) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await db.collection('users').doc(uid).update({'settings.$key': value});
  }

  Future<void> _sendPasswordReset() async {
    final email = FirebaseAuth.instance.currentUser?.email;
    if (email == null) return;
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Password reset email sent to $email'),
          backgroundColor: _navy,
        ),
      );
    }
  }

  void _showLanguagePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _cream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select Language',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _navy),
            ),
            const SizedBox(height: 16),
            ..._languages.map(
              (lang) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(lang, style: const TextStyle(color: _navy, fontSize: 15)),
                trailing: _language == lang
                    ? const Icon(Icons.check_circle, color: _red)
                    : Icon(Icons.circle_outlined, color: _navy.withOpacity(0.3)),
                onTap: () {
                  setState(() => _language = lang);
                  _updateString('language', lang);
                  Navigator.pop(context);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteAccount() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Account', style: TextStyle(color: _navy, fontWeight: FontWeight.bold)),
        content: const Text(
          'This will permanently delete your account and all data. This cannot be undone.',
          style: TextStyle(color: _navy),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: _navy.withOpacity(0.6))),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                final uid = FirebaseAuth.instance.currentUser?.uid;
                if (uid != null) await db.collection('users').doc(uid).delete();
                await FirebaseAuth.instance.currentUser?.delete();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please re-login and try again.'),
                      backgroundColor: _red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _cream,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _navy),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Settings', style: TextStyle(color: _navy, fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _navy))
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              children: [
                _sectionLabel('Notifications'),
                const SizedBox(height: 8),
                _toggleTile(
                  icon: Icons.notifications_outlined,
                  title: 'Push Notifications',
                  subtitle: 'Receive app notifications',
                  value: _pushNotifications,
                  onChanged: (v) {
                    setState(() => _pushNotifications = v);
                    _updateBool('pushNotifications', v);
                  },
                ),
                const SizedBox(height: 10),
                _toggleTile(
                  icon: Icons.directions_car_outlined,
                  title: 'Ride Updates',
                  subtitle: 'Alerts for ride status changes',
                  value: _rideUpdates,
                  onChanged: (v) {
                    setState(() => _rideUpdates = v);
                    _updateBool('rideUpdates', v);
                  },
                ),

                const SizedBox(height: 24),
                _sectionLabel('Privacy'),
                const SizedBox(height: 8),
                _toggleTile(
                  icon: Icons.location_on_outlined,
                  title: 'Always Use Location',
                  subtitle: 'Allow location access in background',
                  value: _alwaysUseLocation,
                  onChanged: (v) {
                    setState(() => _alwaysUseLocation = v);
                    _updateBool('alwaysUseLocation', v);
                  },
                ),
                const SizedBox(height: 10),
                _actionTile(
                  icon: Icons.privacy_tip_outlined,
                  title: 'Privacy Policy',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PolicyScreen(title: 'Privacy Policy', docId: 'privacy_policy'),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _actionTile(
                  icon: Icons.description_outlined,
                  title: 'Terms of Service',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PolicyScreen(title: 'Terms of Service', docId: 'terms_of_service'),
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                _sectionLabel('Account'),
                const SizedBox(height: 8),
                _actionTile(
                  icon: Icons.lock_outline,
                  title: 'Change Password',
                  subtitle: 'Send a password reset email',
                  onTap: _sendPasswordReset,
                ),
                const SizedBox(height: 10),
                _actionTile(
                  icon: Icons.language_outlined,
                  title: 'Language',
                  subtitle: _language,
                  onTap: _showLanguagePicker,
                ),
                const SizedBox(height: 10),
                _actionTile(
                  icon: Icons.delete_outline,
                  title: 'Delete Account',
                  iconColor: _red,
                  titleColor: _red,
                  onTap: _confirmDeleteAccount,
                ),

                const SizedBox(height: 40),
              ],
            ),
    );
  }

  Widget _sectionLabel(String label) => Text(
    label,
    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _navy.withOpacity(0.5), letterSpacing: 0.5),
  );

  Widget _toggleTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          _iconBox(icon, _navy),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: _navy, fontWeight: FontWeight.w600, fontSize: 15)),
                Text(subtitle, style: TextStyle(color: _navy.withOpacity(0.5), fontSize: 12)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged, activeThumbColor: _red),
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    Color iconColor = _navy,
    Color titleColor = _navy,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            _iconBox(icon, iconColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: titleColor, fontWeight: FontWeight.w600, fontSize: 15)),
                  if (subtitle != null)
                    Text(subtitle, style: TextStyle(color: _navy.withOpacity(0.5), fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: _navy.withOpacity(0.3), size: 16),
          ],
        ),
      ),
    );
  }

  Widget _iconBox(IconData icon, Color color) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(color: color.withOpacity(0.08), shape: BoxShape.circle),
    child: Icon(icon, color: color, size: 20),
  );
}
