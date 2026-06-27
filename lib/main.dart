import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'splash_screen.dart';
import 'passenger_home_screen.dart';
import 'driver_home_screen.dart';
import 'driver_status_screen.dart';
import 'fcm_service.dart';
import 'permission_service.dart';
import 'db.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }
  await initFCM();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fast Ride',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const _AuthGate(),
    );
  }
}

/// Resolves whether a uid belongs to a passenger or driver (used once to
/// decide which stream to set up).
Future<String> _resolveBaseRole(String uid) async {
  try {
    final doc = await db.collection('drivers').doc(uid).get();
    if (doc.exists) return 'driver';
  } catch (_) {}
  try {
    final doc = await db.collection('users').doc(uid).get();
    final role = (doc.data() as Map<String, dynamic>?)?['role'] as String?;
    if (role == 'driver') return 'driver';
  } catch (_) {}
  return 'passenger';
}

/// Maps a driver Firestore document to a screen key.
String _driverScreenKey(Map<String, dynamic>? data) {
  if (data == null) return 'pending';
  final status      = data['status']      as String?;
  final isVerified  = data['isVerified']  as bool?;
  final isSuspended = data['isSuspended'] as bool?;
  if (isSuspended == true || status == 'suspended') return 'suspended';
  if (isVerified == true  || status == 'approved' || status == 'active') return 'driver';
  return 'pending';
}

Future<void> _handleForceLogout(String uid, String collection) async {
  try { await db.collection(collection).doc(uid).update({'forceLogout': false}); } catch (_) {}
  await FirebaseAuth.instance.signOut();
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) requestAppPermissions(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }
        final user = authSnap.data;
        if (user == null) return const SplashScreen();

        // Determine base role first, then stream driver doc if needed
        return FutureBuilder<String>(
          future: _resolveBaseRole(user.uid),
          builder: (context, roleSnap) {
            if (roleSnap.connectionState == ConnectionState.waiting) {
              return const SplashScreen();
            }
            if (roleSnap.data != 'driver') return const PassengerHomeScreen();

            // ── Driver: stream their doc for real-time status changes ──
            return StreamBuilder<DocumentSnapshot>(
              stream: db.collection('drivers').doc(user.uid).snapshots(),
              builder: (context, driverSnap) {
                // fall back to users collection if not in drivers
                if (driverSnap.hasData && !driverSnap.data!.exists) {
                  return StreamBuilder<DocumentSnapshot>(
                    stream: db.collection('users').doc(user.uid).snapshots(),
                    builder: (context, userSnap) {
                      if (userSnap.connectionState == ConnectionState.waiting) {
                        return const SplashScreen();
                      }
                      final data = userSnap.data?.data() as Map<String, dynamic>?;
                      if (data?['forceLogout'] == true) {
                        WidgetsBinding.instance.addPostFrameCallback((_) =>
                            _handleForceLogout(user.uid, 'users'));
                        return const SplashScreen();
                      }
                      return _buildDriverScreen(_driverScreenKey(data));
                    },
                  );
                }
                if (driverSnap.connectionState == ConnectionState.waiting) {
                  return const SplashScreen();
                }
                final data = driverSnap.data?.data() as Map<String, dynamic>?;
                if (data?['forceLogout'] == true) {
                  WidgetsBinding.instance.addPostFrameCallback((_) =>
                      _handleForceLogout(user.uid, 'drivers'));
                  return const SplashScreen();
                }
                return _buildDriverScreen(_driverScreenKey(data));
              },
            );
          },
        );
      },
    );
  }

  Widget _buildDriverScreen(String key) {
    switch (key) {
      case 'driver':    return const DriverHomeScreen();
      case 'suspended': return const DriverStatusScreen(status: 'suspended');
      default:          return const DriverStatusScreen(status: 'pending');
    }
  }
}
