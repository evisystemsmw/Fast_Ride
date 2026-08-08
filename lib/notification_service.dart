import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'auth_persistence.dart';
import 'db.dart';
import 'firebase_options.dart';

final _localNotif = FlutterLocalNotificationsPlugin();

const _channel = AndroidNotificationChannel(
  'fast_ride_channel',
  'Fast Ride Notifications',
  description: 'Ride and broadcast notifications',
  importance: Importance.high,
);

const _rideRequestChannel = AndroidNotificationChannel(
  'ride_request_channel',
  'Ride Requests',
  description: 'Incoming ride request notifications',
  importance: Importance.max,
  sound: RawResourceAndroidNotificationSound('ride_request_ringtone'),
  playSound: true,
);

// Must be top-level for background FCM messages
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}

  // Background isolate has no init() — must bootstrap notifications here
  final androidPlugin = _localNotif
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await androidPlugin?.createNotificationChannel(_rideRequestChannel);
  await androidPlugin?.createNotificationChannel(_channel);
  await _localNotif.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  final title = message.notification?.title ?? message.data['title'] ?? '';
  final body = message.notification?.body ?? message.data['body'] ?? '';
  await AuthPersistence.savePendingNotification({
    'id': '${message.messageId ?? DateTime.now().microsecondsSinceEpoch}',
    'title': title,
    'body': body,
    'source': 'fcm',
  });
  await _showBanner(title, body, id: message.hashCode);
}

Future<void> _showBanner(String title, String body, {int id = 0}) async {
  if (title.isEmpty && body.isEmpty) return;
  final isRideRequest = title.toLowerCase().contains('ride request');
  final channel = isRideRequest ? _rideRequestChannel : _channel;
  try {
    await _localNotif.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: Priority.high,
          icon: '@drawable/ic_notification',
          sound: isRideRequest
              ? const RawResourceAndroidNotificationSound(
                  'ride_request_ringtone',
                )
              : null,
          playSound: true,
        ),
      ),
    );
  } catch (e) {
    debugPrint('[RideReq] _showBanner error: $e');
  }
}

class NotificationService {
  static StreamSubscription? _firestoreSub;
  static StreamSubscription? _ridesSub;
  static String? _listeningUid;

  static Future<String?> getCurrentFcmToken() async {
    try {
      return FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  static Future<void> init() async {

    // create notification channels
    final androidPlugin = _localNotif
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_channel);
    await androidPlugin?.createNotificationChannel(_rideRequestChannel);

    await _localNotif.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    // request permission
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // foreground FCM messages
    FirebaseMessaging.onMessage.listen((msg) async {
      final title = msg.notification?.title ?? msg.data['title'] ?? '';
      final body = msg.notification?.body ?? msg.data['body'] ?? '';
      await AuthPersistence.savePendingNotification({
        'id': '${msg.messageId ?? DateTime.now().microsecondsSinceEpoch}',
        'title': title,
        'body': body,
        'source': 'foreground',
      });
      _showBanner(title, body, id: msg.hashCode);
    });

    // persist a token even before auth is fully restored
    final cachedUid =
        FirebaseAuth.instance.currentUser?.uid ??
        await AuthPersistence.loadUid();
    final initialToken = await getCurrentFcmToken();
    if (initialToken != null) {
      await AuthPersistence.saveSession(
        uid: cachedUid ?? '',
        fcmToken: initialToken,
      );
      if (cachedUid != null && cachedUid.isNotEmpty) {
        await _saveFcmToken(cachedUid, token: initialToken);
      }
    }

    await flushPendingNotifications();

    // listen to auth changes to start/stop Firestore listener
    bool _authFired = false;
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      _firestoreSub?.cancel();
      _ridesSub?.cancel();
      _listeningUid = null;
      if (user != null) {
        if (_listeningUid == user.uid) return;
        _listeningUid = user.uid;
        _authFired = true;
        await _saveFcmToken(user.uid);
        await _listenFirestore(user.uid);
        _listenRideRequests(user.uid);
      }
    });

    // Fallback: if Firebase auth never fires (session restore failed offline),
    // still save FCM token and start listeners using the cached uid
    Future.delayed(const Duration(seconds: 10), () async {
      if (_authFired) return;
      final uid = FirebaseAuth.instance.currentUser?.uid
          ?? await AuthPersistence.loadUid();
      if (uid == null || uid.isEmpty) return;
      if (_listeningUid == uid) return;
      final token = await getCurrentFcmToken();
      if (token != null) await _saveFcmToken(uid, token: token);
      if (_firestoreSub == null) await _listenFirestore(uid);
      if (_ridesSub == null) _listenRideRequests(uid);
    });

    // refresh token if it rotates
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      final uid =
          FirebaseAuth.instance.currentUser?.uid ??
          await AuthPersistence.loadUid();
      await AuthPersistence.saveSession(uid: uid ?? '', fcmToken: token);
      if (uid != null && uid.isNotEmpty) {
        await _saveFcmToken(uid, token: token);
      }
    });

  }

  static Future<void> flushPendingNotifications() async {
    final pending = await AuthPersistence.loadPendingNotifications();
    if (pending.isEmpty) return;

    for (final entry in pending) {
      final title = (entry['title'] ?? '').toString();
      final body = (entry['body'] ?? '').toString();
      if (title.isEmpty && body.isEmpty) continue;
      await _showBanner(title, body, id: title.hashCode + body.hashCode);
    }

    await AuthPersistence.clearPendingNotifications();
  }

  static Future<void> _saveFcmToken(String uid, {String? token}) async {
    final resolvedToken = token ?? await FirebaseMessaging.instance.getToken();
    if (resolvedToken == null) return;

    await AuthPersistence.saveSession(uid: uid, fcmToken: resolvedToken);

    final driverDoc = await db.collection('drivers').doc(uid).get();
    final collection = driverDoc.exists ? 'drivers' : 'users';
    await db.collection(collection).doc(uid).set({
      'fcmToken': resolvedToken,
    }, SetOptions(merge: true));
  }

  // Listen to rides collection for new requests assigned to this driver
  static void _listenRideRequests(String uid) {
    _ridesSub?.cancel();
    bool initialLoad = true;
    debugPrint('[RideReq] _listenRideRequests started uid=$uid');

    _ridesSub = db
        .collection('rides')
        .where('driverId', isEqualTo: uid)
        .where('status', isEqualTo: 'requested')
        .snapshots()
        .listen((snap) async {
          debugPrint('[RideReq] snapshot docChanges=${snap.docChanges.length} initialLoad=$initialLoad');
          if (initialLoad) {
            initialLoad = false;
            return;
          }
          for (final change in snap.docChanges) {
            debugPrint('[RideReq] change type=${change.type} docId=${change.doc.id}');
            if (change.type != DocumentChangeType.added) continue;
            final data = change.doc.data();
            if (data == null) continue;

            final pickup = data['pickup'] ?? '';
            final destination = data['destination'] ?? '';
            final passengerName = (data['passengerName'] as String? ?? '').trim();

            final title = '🚗 New Ride Request';
            final body =
                "${passengerName.isNotEmpty ? passengerName : 'A passenger'} needs a ride\n📍 $pickup → $destination";
            debugPrint('[RideReq] showing banner: $title | $body');
            await AuthPersistence.savePendingNotification({
              'id': change.doc.id,
              'title': title,
              'body': body,
              'source': 'ride_request_listener',
            });
            await _showBanner(title, body, id: change.doc.id.hashCode);
            debugPrint('[RideReq] banner shown');
          }
        }, onError: (e) => debugPrint('[RideReq] ERROR: $e'));
  }

  static Future<void> _listenFirestore(String uid) async {
    final userDoc = await db.collection('users').doc(uid).get();
    final role = (userDoc.data()?['role'] as String?)?.toLowerCase();
    final driverDoc = await db.collection('drivers').doc(uid).get();
    final isDriver = role == 'driver' || driverDoc.exists;
    final isStaff = !isDriver && role == 'staff';

    final broadcastTargets = isDriver
        ? ['all', 'drivers', 'driver']
        : isStaff
        ? ['all', 'staff']
        : ['all', 'passengers', 'passenger'];

    final since = DateTime.now();

    _firestoreSub = db
        .collection('notifications')
        .where('uid', isEqualTo: uid)
        .snapshots()
        .listen((snap) async {
          for (final change in snap.docChanges) {
            if (change.type != DocumentChangeType.added) continue;
            final data = change.doc.data();
            if (data == null) continue;

            // skip old docs — createdAt may be null if server hasn't resolved yet,
            // treat null as "just now" so we don't miss it
            final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
            if (createdAt != null && createdAt.isBefore(since)) continue;

            final docUid = data['uid'] as String?;
            final docUserId = data['userId'] as String?;
            final target = (data['target'] as String? ?? '').toLowerCase();
            final isForUser = docUid == uid || docUserId == uid;
            final isBroadcast = broadcastTargets.contains(target);

            if (!isForUser && !isBroadcast) continue;

            final type = (data['type'] as String?)?.toLowerCase().trim() ?? '';
            if (type == 'ride_request') continue;
            const allowedTypes = {'notification', 'ticket_reply'};
            if (type.isNotEmpty && !allowedTypes.contains(type)) continue;

            final title = (data['title'] ?? '') as String;
            final body = (data['body'] ?? '') as String;
            await AuthPersistence.savePendingNotification({
              'id': change.doc.id,
              'title': title,
              'body': body,
              'source': 'firestore_notification',
            });
            _showBanner(title, body, id: change.doc.id.hashCode);
          }
        }, onError: (_) {});
  }

  static void dispose() {
    _firestoreSub?.cancel();
    _ridesSub?.cancel();
  }
}
