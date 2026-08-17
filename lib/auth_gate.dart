import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'login_screen.dart';
import 'driver_home_screen.dart';
import 'passenger_home_screen.dart';
import 'driver_status_screen.dart';
import 'splash_screen.dart';
import 'db.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.initialUser});
  final User? initialUser;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _permissionsRequested = false;
  bool _minDelayDone = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _minDelayDone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (!_permissionsRequested) {
          _permissionsRequested = true;
          [Permission.location, Permission.locationWhenInUse, Permission.notification].request();
        }

        if (authSnap.connectionState == ConnectionState.waiting || !_minDelayDone) {
          return const SplashScreen();
        }

        final user = authSnap.data;
        if (user == null) return const LoginScreen();

        // Real-time listener on driver doc
        return StreamBuilder<DocumentSnapshot>(
          stream: db.collection('drivers').doc(user.uid).snapshots(),
          builder: (context, driverSnap) {
            if (driverSnap.connectionState == ConnectionState.waiting) {
              return const SplashScreen();
            }

            final driverDoc = driverSnap.data;
            final isDriver = driverDoc?.exists == true;

            if (isDriver) {
              final data = driverDoc!.data() as Map<String, dynamic>?;
              final status = (data?['status'] as String?)?.toLowerCase();
              final isVerified = data?['isVerified'] as bool? ?? true;
              final isBlocked = data?['isBlocked'] as bool? ??
                  data?['blocked'] as bool? ?? false;
              final isActive = data?['isActive'] as bool? ?? true;

              // Update FCM token once
              FirebaseMessaging.instance.getToken().then((token) {
                if (token == null) return;
                db.collection('drivers').doc(user.uid)
                    .update({'fcmToken': token}).catchError((_) {});
              });

              final blocked = isBlocked || !isActive ||
                  status == 'blocked' || status == 'suspended' || status == 'pending';

              if (blocked || !isVerified) {
                String effectiveStatus;
                if (status == 'suspended') {
                  effectiveStatus = 'suspended';
                } else if (isBlocked || !isActive || status == 'blocked') {
                  effectiveStatus = 'blocked';
                } else {
                  effectiveStatus = 'pending';
                }
                return DriverStatusScreen(status: effectiveStatus);
              }

              return const DriverHomeScreen();
            }

            // Not a driver — check passenger status in real-time
            return StreamBuilder<DocumentSnapshot>(
              stream: db.collection('users').doc(user.uid).snapshots(),
              builder: (context, userSnap) {
                if (userSnap.connectionState == ConnectionState.waiting) {
                  return const SplashScreen();
                }

                final userData = userSnap.data?.data() as Map<String, dynamic>?;
                final passengerStatus = (userData?['status'] as String?)?.toLowerCase();
                final passengerBlocked = userData?['isBlocked'] as bool? ??
                    userData?['blocked'] as bool? ?? false;
                final passengerActive = userData?['isActive'] as bool? ?? true;

                // Update FCM token once
                FirebaseMessaging.instance.getToken().then((token) {
                  if (token == null) return;
                  db.collection('users').doc(user.uid)
                      .update({'fcmToken': token}).catchError((_) {});
                });

                if (passengerBlocked || !passengerActive ||
                    passengerStatus == 'blocked' || passengerStatus == 'suspended') {
                  final effectiveStatus = passengerStatus == 'suspended'
                      ? 'suspended'
                      : 'blocked';
                  return DriverStatusScreen(status: effectiveStatus);
                }

                return const PassengerHomeScreen();
              },
            );
          },
        );
      },
    );
  }
}
