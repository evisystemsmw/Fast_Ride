const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

// Sends FCM push to a uid — checks drivers then users collection for fcmToken
async function sendPush(uid, title, body) {
  const db = getFirestore();
  let snap = await db.collection('drivers').doc(uid).get();
  if (!snap.exists) snap = await db.collection('users').doc(uid).get();
  const token = snap.data()?.fcmToken;
  if (!token) {
    console.warn(`[sendPush] No fcmToken for uid=${uid} — notification not sent`);
    return;
  }
  try {
    await getMessaging().send({
      token,
      notification: { title, body },
      data: { title, body },
      android: { priority: 'high' },
    });
    console.log(`[sendPush] Sent to uid=${uid}`);
  } catch (e) {
    console.error(`[sendPush] Failed for uid=${uid} token=${token}: ${e.message}`);
    // Clear stale token so we don't keep retrying it
    if (e.code === 'messaging/invalid-registration-token' ||
        e.code === 'messaging/registration-token-not-registered') {
      await snap.ref.update({ fcmToken: null });
      console.warn(`[sendPush] Cleared stale token for uid=${uid}`);
    }
  }
}

// ── Admin broadcast/personal notification → send FCM push ───────────────────
exports.onNotificationCreated = onDocumentCreated(
  'notifications/{notifId}',
  async (event) => {
    const db = getFirestore();
    const data = event.data?.data();
    if (!data) return;

    const title = data.title || '';
    const body = data.body || '';
    if (!title && !body) return;

    const type = (data.type || '').toLowerCase().trim();
    if (type === 'ride_request') return;
    if (type && type !== 'notification' && type !== 'ticket_reply') return;

    // Personal notification — send to specific uid
    const uid = data.uid || data.userId;
    if (uid) {
      await sendPush(uid, title, body);
      return;
    }

    // Broadcast notification — send to all matching role users
    const target = (data.target || '').toLowerCase().trim();
    if (!target) return;

    const isAll = target === 'all';
    const isDrivers = target === 'drivers' || target === 'driver';
    const isPassengers = target === 'passengers' || target === 'passenger';
    const isStaff = target === 'staff';

    if (isAll || isDrivers) {
      const snap = await db.collection('drivers').get();
      await Promise.all(snap.docs.map(doc => {
        const token = doc.data().fcmToken;
        if (!token) return Promise.resolve();
        return getMessaging().send({
          token,
          notification: { title, body },
          data: { title, body },
          android: { priority: 'high' },
        }).catch(e => console.warn(`[broadcast] driver ${doc.id}: ${e.message}`));
      }));
    }

    if (isAll || isPassengers || isStaff) {
      const roleFilter = isAll ? null : (isPassengers ? 'passenger' : 'staff');
      let query = db.collection('users');
      if (roleFilter) query = query.where('role', '==', roleFilter);
      const snap = await query.get();
      await Promise.all(snap.docs.map(doc => {
        const token = doc.data().fcmToken;
        if (!token) return Promise.resolve();
        return getMessaging().send({
          token,
          notification: { title, body },
          data: { title, body },
          android: { priority: 'high' },
        }).catch(e => console.warn(`[broadcast] user ${doc.id}: ${e.message}`));
      }));
    }

    console.log(`[onNotificationCreated] broadcast done target=${target}`);
  }
);


exports.onRideRequestCreated = onDocumentCreated(
  'rides/{rideId}',
  async (event) => {
    const ride = event.data?.data();
    if (!ride || ride.status !== 'requested' || !ride.driverId) {
      console.log(`[onRideRequestCreated] skipped — status=${ride?.status} driverId=${ride?.driverId}`);
      return;
    }
    const name = (ride.passengerName || '').trim();
    const pickup = ride.pickup || '';
    const dest = ride.destination || '';
    await sendPush(
      ride.driverId,
      '🚗 New Ride Request',
      `${name || 'A passenger'} needs a ride\n📍 ${pickup} → ${dest}`,
    );
    console.log(`[FCM] ride request sent to driver ${ride.driverId}`);
  }
);

// ── Ride status changes → notify passenger or driver ─────────────────────────
exports.onRideUpdated = onDocumentUpdated(
  'rides/{rideId}',
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    const status = after.status;
    const prevStatus = before.status;

    // Old passenger app: creates ride as 'pending' then updates to 'requested' with driverId
    if (status === 'requested' && prevStatus !== 'requested' && after.driverId) {
      const name = (after.passengerName || '').trim();
      const pickup = after.pickup || '';
      const dest = after.destination || '';
      await sendPush(
        after.driverId,
        '🚗 New Ride Request',
        `${name || 'A passenger'} needs a ride\n📍 ${pickup} → ${dest}`,
      );
      console.log(`[FCM] ride request (via update) sent to driver ${after.driverId}`);
      return;
    }

    if (prevStatus === status) return;

    if (status === 'accepted' && after.passengerId) {
      await sendPush(
        after.passengerId,
        '✅ Ride Accepted',
        `${after.driverName || 'Your driver'} accepted your ride.`,
      );
    } else if (status === 'cancelled') {
      // Always notify driver when ride is cancelled (passenger cancelled)
      if (after.driverId && !after.cancelledByDriver) {
        await sendPush(
          after.driverId,
          '❌ Ride Cancelled',
          `${after.passengerName || 'The passenger'} cancelled the ride.`,
        );
      }
      // Notify passenger if driver cancelled
      if (after.passengerId && after.cancelledByDriver === true) {
        await sendPush(after.passengerId, '❌ Ride Cancelled', 'Your driver cancelled the ride.');
      }
    } else if (status === 'completed' && after.passengerId) {
      await sendPush(after.passengerId, '🏁 Ride Completed', 'Your ride is complete. Thank you for using Fast Ride!');
    }
  }
);

// ── Ride completed → add commission to driver's subscription balance ──────────
exports.onRideCompleted = onDocumentUpdated(
  'rides/{rideId}',
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;
    if (before.status === 'completed' || after.status !== 'completed') return;
    if (!after.driverId || !after.finalFare) return;

    const db = getFirestore();
    const fareDoc = await db.collection('settings').doc('fare').get();
    const rate = ((fareDoc.data()?.subscriptionRate) ?? 8) / 100;
    const commission = Math.round(after.finalFare * rate);

    await db.collection('drivers').doc(after.driverId).update({
      subscriptionBalance: FieldValue.increment(commission),
    });
  }
);

// ── Scheduled ride reminders → 50 min and 10 min before trip ────────────────
async function sendRideReminder(db, doc, ride, label, passengerTitle, passengerBody, driverTitle, driverBody, flagField) {
  const { passengerId, driverId } = ride;
  if (passengerId) {
    await sendPush(passengerId, passengerTitle, passengerBody);
    await db.collection('notifications').add({
      uid: passengerId, title: passengerTitle, body: passengerBody,
      type: 'notification', isRead: false, createdAt: Timestamp.now(),
    });
  }
  if (driverId) {
    await sendPush(driverId, driverTitle, driverBody);
    await db.collection('notifications').add({
      uid: driverId, title: driverTitle, body: driverBody,
      type: 'notification', isRead: false, createdAt: Timestamp.now(),
    });
  }
  await doc.ref.update({ [flagField]: true });
  console.log(`[scheduledRideReminder] ${label} reminder sent for ride ${doc.id}`);
}

exports.scheduledRideReminder = onSchedule('every 5 minutes', async () => {
  const db = getFirestore();
  const now = new Date();

  const inWindow = (scheduledAt, minOffset, maxOffset) => {
    const t = scheduledAt?.toDate?.()?.getTime();
    if (!t) return false;
    return t >= now.getTime() + minOffset * 60000 && t <= now.getTime() + maxOffset * 60000;
  };

  // fetch all scheduled rides where either reminder hasn't been sent yet
  const snap = await db.collection('rides')
    .where('status', '==', 'scheduled')
    .get();

  console.log(`[scheduledRideReminder] checking ${snap.size} scheduled rides`);

  for (const doc of snap.docs) {
    const ride = doc.data();
    const scheduledAt = ride.scheduledAt;
    const timeStr = scheduledAt?.toDate
      ? scheduledAt.toDate().toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
      : 'soon';

    // 50-min reminder
    if (!ride.reminder50Sent && inWindow(scheduledAt, 45, 55)) {
      await sendRideReminder(db, doc, ride,
        '50-min',
        '⏰ Upcoming Ride Reminder',
        `Your ride to ${ride.destination || 'your destination'} is at ${timeStr}. Please be ready.`,
        '⏰ Scheduled Ride in 50 min',
        `Reminder: pickup ${ride.passengerName || 'passenger'} at ${timeStr} from ${ride.pickup || 'pickup location'}.`,
        'reminder50Sent',
      );
    }

    // 10-min reminder
    if (!ride.reminder10Sent && inWindow(scheduledAt, 5, 15)) {
      await sendRideReminder(db, doc, ride,
        '10-min',
        '🚨 Your Ride is in 10 Minutes!',
        `Your ride to ${ride.destination || 'your destination'} departs at ${timeStr}. Your driver is on the way!`,
        '🚨 Pickup in 10 Minutes!',
        `Head to pickup now — ${ride.passengerName || 'passenger'} at ${ride.pickup || 'pickup location'} at ${timeStr}.`,
        'reminder10Sent',
      );
    }

    // Auto-start: flip to 'requested' when scheduledAt - 10 min has passed
    const t = scheduledAt?.toDate?.()?.getTime();
    if (t && now.getTime() >= t - 10 * 60000) {
      // Skip if driver is already on an active ride
      if (ride.driverId) {
        const busySnap = await db.collection('rides')
          .where('driverId', '==', ride.driverId)
          .where('status', 'in', ['accepted', 'in_trip'])
          .limit(1)
          .get();
        if (!busySnap.empty) {
          console.log(`[scheduledRideReminder] skipped auto-start for ride ${doc.id} — driver ${ride.driverId} is busy`);
          continue;
        }
      }
      await doc.ref.update({ status: 'requested' });
      console.log(`[scheduledRideReminder] auto-started ride ${doc.id}`);
    }
  }
});

// ── Rating submitted → update driver's average rating ────────────────────────
exports.onRatingSubmitted = onDocumentUpdated(
  'rides/{rideId}',
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;
    if (before.driverRating === after.driverRating || !after.driverRating || !after.driverId) return;

    const db = getFirestore();
    const snap = await db
      .collection('rides')
      .where('driverId', '==', after.driverId)
      .where('status', '==', 'completed')
      .get();

    let sum = 0, count = 0;
    for (const doc of snap.docs) {
      const r = doc.data().driverRating;
      if (r > 0) { sum += r; count++; }
    }
    if (count === 0) return;

    await db.collection('drivers').doc(after.driverId).update({
      averageRating: sum / count,
      ratingCount: count,
    });
  }
);
