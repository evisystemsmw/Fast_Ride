import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'login_screen.dart';
import 'driver_home_screen.dart';
import 'passenger_home_screen.dart';
import 'driver_status_screen.dart';
import 'splash_screen.dart';
import 'db.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key, this.initialUser});
  final User? initialUser;

  Future<Widget> _resolveHome(User user) async {
    final results = await Future.wait([
      FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
      FirebaseFirestore.instance.collection('drivers').doc(user.uid).get(),
    ]);
    final userDoc = results[0];
    final driverDoc = results[1];

    final role = (userDoc.data()?['role'] as String?)?.toLowerCase();
    final isDriver = role == 'driver' || (role == null && driverDoc.exists);

    FirebaseMessaging.instance.getToken().then((token) {
      if (token == null) return;
      db.collection(isDriver ? 'drivers' : 'users')
          .doc(user.uid)
          .update({'fcmToken': token})
          .catchError((_) {});
    });

    if (isDriver) {
      final status = (driverDoc.data()?['status'] as String?)?.toLowerCase();
      if (status == 'pending' || status == 'suspended' || status == 'blocked') {
        return DriverStatusScreen(status: status!);
      }
      return const DriverHomeScreen();
    }

    return const PassengerHomeScreen();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data ?? initialUser;

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }

        if (user == null) return const LoginScreen();

        return FutureBuilder<Widget>(
          future: _resolveHome(user),
          builder: (context, snap) {
            if (!snap.hasData) return const SplashScreen();
            return snap.data!;
          },
        );
      },
    );
  }
}
