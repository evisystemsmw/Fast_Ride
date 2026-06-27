import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'db.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

export 'map_service.dart';

const String googleMapsApiKey = 'AIzaSyAbKzwmb1sG2eIOgO-Isw9SdLu8KELGM1A';
const String placesApiKey = 'AIzaSyAICLVJjDA9SKkHwQlZ9AQdRor-B3bb4FQ';
const String geocodingApiKey = 'AIzaSyBWd9K3iVIe756pfvqa9HII-4XRtRBVsgE';

class MapService {
  static const double nearbyRadiusKm = 10.0;

  // ── Kalman smoother state ──────────────────────────────
  static double? _kLat;
  static double? _kLng;
  static double _kVariance = -1; // negative = uninitialised

  /// Simple 1-D Kalman filter applied to lat & lng independently.
  /// [accuracy] is the GPS reported accuracy in metres.
  static Position _smooth(Position pos) {
    const processNoise = 0.0001; // how much we trust motion over time
    final measNoise = max(pos.accuracy, 1.0);

    if (_kVariance < 0) {
      // first fix — initialise
      _kLat = pos.latitude;
      _kLng = pos.longitude;
      _kVariance = measNoise * measNoise;
      return pos;
    }

    // Predict
    _kVariance += processNoise;

    // Update (Kalman gain)
    final k = _kVariance / (_kVariance + measNoise * measNoise);
    _kLat = _kLat! + k * (pos.latitude  - _kLat!);
    _kLng = _kLng! + k * (pos.longitude - _kLng!);
    _kVariance = (1 - k) * _kVariance;

    // Return a Position with the smoothed coords
    return Position(
      latitude:          _kLat!,
      longitude:         _kLng!,
      accuracy:          pos.accuracy,
      altitude:          pos.altitude,
      altitudeAccuracy:  pos.altitudeAccuracy,
      heading:           pos.heading,
      headingAccuracy:   pos.headingAccuracy,
      speed:             pos.speed,
      speedAccuracy:     pos.speedAccuracy,
      timestamp:         pos.timestamp,
    );
  }

  static void resetSmoothing() {
    _kLat = null;
    _kLng = null;
    _kVariance = -1;
  }

  /// Request permission and return best current position
  static Future<Position?> getCurrentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) return null;
    }
    if (perm == LocationPermission.deniedForever) return null;

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      resetSmoothing(); // reset so first real fix initialises the filter cleanly
      return _smooth(pos);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      return last != null ? _smooth(last) : null;
    }
  }

  static Stream<Position> trackLocation() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).map(_smooth);
  }

  // ── Throttled Firestore writes ─────────────────────────
  static DateTime? _lastWrite;
  static double? _lastWriteLat;
  static double? _lastWriteLng;

  /// Write to Firestore only if ≥1 s has passed AND driver moved ≥5 m.
  static Future<void> updateDriverLocation(Position position) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final now = DateTime.now();
    final movedEnough = _lastWriteLat == null ||
        distanceKm(_lastWriteLat!, _lastWriteLng!,
                position.latitude, position.longitude) * 1000 >= 5;
    final timeOk = _lastWrite == null ||
        now.difference(_lastWrite!).inMilliseconds >= 1000;

    if (!movedEnough || !timeOk) return;

    _lastWrite    = now;
    _lastWriteLat = position.latitude;
    _lastWriteLng = position.longitude;

    await db.collection('drivers').doc(uid).update({
      'lat':               position.latitude,
      'lng':               position.longitude,
      'location':          GeoPoint(position.latitude, position.longitude),
      'heading':           position.heading,
      'locationUpdatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Haversine distance in km
  static double distanceKm(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) *
            sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  static double _rad(double deg) => deg * pi / 180;
}
