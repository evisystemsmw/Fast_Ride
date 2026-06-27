const { setGlobalOptions } = require('firebase-functions');
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { onCall } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const { getFirestore } = require('firebase-admin/firestore');

initializeApp();
setGlobalOptions({ maxInstances: 10 });

exports.deleteAuthUser = onCall(async (request) => {});
exports.sendPaymentReceiptEmail = onCall(async (request) => {});

async function sendRideNotification(rideId, data) {
  const db        = getFirestore();
  const messaging = getMessaging();

  const driverId = data.driverId;
  const title    = 'New Ride Request 🚗';
  const body     = `${data.passengerName || 'Passenger'}: ${data.pickup || ''} → ${data.destination || ''}`;

  const makePayload = (token) => ({
    token,
    data: {
      type:        'ride_request',
      rideId:      rideId,
      pickup:      data.pickup        || '',
      destination: data.destination   || '',
      passenger:   data.passengerName || '',
      title,
      body,
    },
    notification: { title, body },
    android: {
      priority: 'high',
      ttl: 30000,
      notification: {
        channelId: 'ride_request_channel',
        sound: 'ride_request_ringtone',
        priority: 'max',
        defaultVibrateTimings: true,
      },
    },
    apns: {
      headers: { 'apns-priority': '10', 'apns-push-type': 'alert' },
      payload: { aps: { sound: 'default', badge: 1, 'content-available': 1 } },
    },
  });

  if (driverId) {
    // Notify a specific pre-booked driver
    console.log(`[onRide] rideId=${rideId} → specific driverId=${driverId}`);
    const driverDoc = await db.collection('drivers').doc(driverId).get();
    const token = driverDoc.data()?.fcmToken;
    if (!token) {
      console.warn(`[onRide] No FCM token for driver ${driverId}`);
      return;
    }
    try {
      const result = await messaging.send(makePayload(token));
      console.log(`[onRide] FCM sent to specific driver: ${result}`);
    } catch (err) {
      console.error(`[onRide] FCM send error: ${err.message}`, err);
    }
  } else {
    // Broadcast to ALL online drivers
    console.log(`[onRide] rideId=${rideId} → broadcasting to all online drivers`);
    const driversSnap = await db.collection('drivers')
      .where('isOnline', '==', true)
      .get();

    const tokens = driversSnap.docs
      .map(d => d.data().fcmToken)
      .filter(Boolean);

    console.log(`[onRide] Found ${tokens.length} online driver(s) with FCM tokens`);
    if (tokens.length === 0) return;

    const results = await messaging.sendEachForMulticast({
      tokens,
      data: {
        type:        'ride_request',
        rideId:      rideId,
        pickup:      data.pickup        || '',
        destination: data.destination   || '',
        passenger:   data.passengerName || '',
        title,
        body,
      },
      notification: { title, body },
      android: {
        priority: 'high',
        ttl: 30000,
        notification: {
          channelId: 'ride_request_channel',
          sound: 'ride_request_ringtone',
          priority: 'max',
          defaultVibrateTimings: true,
        },
      },
      apns: {
        headers: { 'apns-priority': '10', 'apns-push-type': 'alert' },
        payload: { aps: { sound: 'default', badge: 1, 'content-available': 1 } },
      },
    });
    console.log(`[onRide] Broadcast results: successCount=${results.successCount} failureCount=${results.failureCount}`);
  }
}

// Fires when a ride is created already in 'requested' state (driver-booked rides)
exports.onRideRequestCreated = onDocumentCreated(
  'rides/{rideId}',
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    // Only notify if ride was created directly as 'requested' with a specific driver
    if (data.status !== 'requested' || !data.driverId) {
      console.log(`[onRideRequestCreated] skipped — status=${data.status} driverId=${data.driverId}`);
      return;
    }
    console.log(`[onRideRequestCreated] triggered rideId=${event.params.rideId}`);
    await sendRideNotification(event.params.rideId, data);
  }
);

// Fires when passenger selects a driver and status changes pending → requested
exports.onRideUpdated = onDocumentUpdated(
  'rides/{rideId}',
  async (event) => {
    const before = event.data?.before?.data();
    const after  = event.data?.after?.data();
    if (!before || !after) return;

    const justRequested = before.status !== 'requested' && after.status === 'requested' && !!after.driverId;

    if (!justRequested) {
      console.log(`[onRideUpdated] skipped — before.status=${before.status} after.status=${after.status}`);
      return;
    }

    console.log(`[onRideUpdated] rideId=${event.params.rideId} → notifying driverId=${after.driverId}`);
    await sendRideNotification(event.params.rideId, after);
  }
);

// ── Send push notification on new notification doc ─────
exports.onNotificationCreated = onDocumentCreated(
  'notifications/{notifId}',
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const title  = data.title  || 'FastRider';
    const body   = data.body   || '';
    const target = data.target;
    const uid    = data.uid;

    const db        = getFirestore();
    const messaging = getMessaging();

    if (target === 'all') {
      const usersSnap = await db
        .collection('users')
        .where('fcmToken', '!=', null)
        .get();

      const tokens = usersSnap.docs
        .map((d) => d.data().fcmToken)
        .filter(Boolean);

      if (tokens.length === 0) return;

      for (let i = 0; i < tokens.length; i += 500) {
        await messaging.sendEachForMulticast({
          tokens: tokens.slice(i, i + 500),
          notification: { title, body },
          android: {
            priority: 'high',
            notification: { channelId: 'fastrider_channel', sound: 'default' },
          },
          apns: {
            payload: { aps: { sound: 'default', badge: 1 } },
          },
        });
      }
    } else if (uid) {
      const userDoc = await db.collection('users').doc(uid).get();
      const token   = userDoc.data()?.fcmToken;
      if (!token) return;

      await messaging.send({
        token,
        notification: { title, body },
        android: {
          priority: 'high',
          notification: { channelId: 'fastrider_channel', sound: 'default' },
        },
        apns: {
          payload: { aps: { sound: 'default', badge: 1 } },
        },
      });
    }
  }
);
