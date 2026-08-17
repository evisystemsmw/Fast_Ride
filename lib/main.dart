import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'auth_gate.dart';
import 'notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
  final user = FirebaseAuth.instance.currentUser;
  runApp(MyApp(initialUser: user));
  await NotificationService.init();
}

Future<void> _requestPermissions() async {
  await [Permission.location, Permission.locationWhenInUse].request();
}


class MyApp extends StatelessWidget {
  const MyApp({super.key, this.initialUser});
  final User? initialUser;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fast Ride',
      debugShowCheckedModeBanner: false,
      home: AuthGate(initialUser: initialUser),
    );
  }
}
