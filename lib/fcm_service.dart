import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'db.dart';
import 'firebase_options.dart';

final _localNotifications = FlutterLocalNotificationsPlugin();

// ── Channels ──────────────────────────────────────────
const _generalChannel = AndroidNotificationChannel(
  'fastrider_channel',
  'FastRider Notifications',
  description: 'Ride and app notifications',
  importance: Importance.high,
);

const _rideRequestChannel = AndroidNotificationChannel(
  'ride_request_channel',
  'Ride Requests',
  description: 'Incoming ride request ringtone',
  importance: Importance.max,
  sound: RawResourceAndroidNotificationSound('ride_request_ringtone'),
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

// Set this from DriverHomeScreen to handle navigation on tap
typedef OnRideRequestTap = void Function(String rideId);
OnRideRequestTap? onRideRequestTap;

// Holds a rideId that arrived before DriverHomeScreen was built
String? _pendingRideId;

// Read by DriverHomeScreen on init to consume a launch-time rideId
String? get pendingRideId => _pendingRideId;
void consumePendingRideId() => _pendingRideId = null;

void _dispatch(String rideId) {
  if (onRideRequestTap != null) {
    onRideRequestTap!(rideId);
    _pendingRideId = null;
  } else {
    _pendingRideId = rideId; // consumed later when callback is registered
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }
  if (message.data['type'] != 'ride_request') return;

  final title  = message.data['title']  as String? ?? 'New Ride Request 🚗';
  final body   = message.data['body']   as String? ?? 'Tap to view';
  final rideId = message.data['rideId'] as String? ?? '';

  await _localNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  await _localNotifications.show(
    rideId.hashCode,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'ride_request_channel',
        'Ride Requests',
        importance: Importance.max,
        priority: Priority.max,
        sound: RawResourceAndroidNotificationSound('ride_request_ringtone'),
        playSound: true,
        fullScreenIntent: true,
        icon: '@mipmap/ic_launcher',
      ),
    ),
    payload: rideId,
  );
}

Future<void> initFCM() async {
  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(alert: true, badge: true, sound: true);

  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _localNotifications.initialize(
    const InitializationSettings(android: androidSettings),
    onDidReceiveNotificationResponse: (details) {
      final rideId = details.payload;
      if (rideId != null && rideId.isNotEmpty) {
        _dispatch(rideId);
      }
    },
  );

  final androidPlugin = _localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  // Delete old cached channels so Android picks up the new sound
  await androidPlugin?.deleteNotificationChannel('ride_request_channel');
  await androidPlugin?.createNotificationChannel(_generalChannel);
  await androidPlugin?.createNotificationChannel(_rideRequestChannel);

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Background tap (app was in background, driver taps notification)
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    final rideId = message.data['rideId'] as String?;
    if (rideId != null && rideId.isNotEmpty) {
      _dispatch(rideId);
    }
  });

  // Terminated state tap (app was closed, driver taps notification)
  final initial = await FirebaseMessaging.instance.getInitialMessage();
  if (initial != null) {
    final rideId = initial.data['rideId'] as String?;
    if (rideId != null && rideId.isNotEmpty) {
      _dispatch(rideId); // stored in _pendingRideId until callback registers
    }
  }

  // Foreground message — pure data, so message.notification is null
  FirebaseMessaging.onMessage.listen((message) {
    final isRideRequest = message.data['type'] == 'ride_request';
    final rideId  = message.data['rideId']  as String? ?? '';
    final title   = message.data['title']   as String? ?? 'New Ride Request 🚗';
    final body    = message.data['body']    as String? ?? 'Tap to view';

    _localNotifications.show(
      rideId.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          isRideRequest ? _rideRequestChannel.id : _generalChannel.id,
          isRideRequest ? _rideRequestChannel.name : _generalChannel.name,
          importance: Importance.max,
          priority: Priority.max,
          sound: isRideRequest
              ? const RawResourceAndroidNotificationSound('ride_request_ringtone')
              : null,
          playSound: true,
          icon: '@mipmap/ic_launcher',
          fullScreenIntent: isRideRequest,
        ),
      ),
      payload: isRideRequest ? rideId : null,
    );
  });

  FirebaseAuth.instance.authStateChanges().listen((user) {
    if (user != null) {
      _saveFcmToken();
      messaging.onTokenRefresh.listen(_saveToken);
    }
  });
}

Future<void> _saveFcmToken() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;
  final token = await FirebaseMessaging.instance.getToken();
  if (token != null) await _saveToken(token);
}

Future<void> _saveToken(String token) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;
  final data = {
    'fcmToken': token,
    'fcmUpdatedAt': FieldValue.serverTimestamp(),
  };
  final driverDoc = await db.collection('drivers').doc(uid).get();
  if (driverDoc.exists) {
    await db.collection('drivers').doc(uid).update(data);
  } else {
    await db.collection('users').doc(uid).update(data);
  }
}
