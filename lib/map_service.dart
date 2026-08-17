import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'db.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

export 'map_service.dart';

const String googleMapsApiKey = 'AIzaSyDHtA496iglb6kibnug_Y_Du4m7G9duNQE';
const String placesApiKey = 'AIzaSyAICLVJjDA9SKkHwQlZ9AQdRor-B3bb4FQ';
const String geocodingApiKey = 'AIzaSyBWd9K3iVIe756pfvqa9HII-4XRtRBVsgE';
const String directionsApiKey = 'AIzaSyAbKzwmb1sG2eIOgO-Isw9SdLu8KELGM1A';

class MapService {
  static const double nearbyRadiusKm = 10.0;

  // ── Kalman smoother state ──────────────────────────────
  static double? _kLat;
  static double? _kLng;
  static double _kVariance = -1; // negative = uninitialised

  /// Simple 1-D Kalman filter applied to lat & lng independently.
  /// [accuracy] is the GPS reported accuracy in metres.
  static Position _smooth(Position pos) {
    const processNoise = 3e-10; // ~0.03m/s² in degrees² — tracks real movement
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
    _kLat = _kLat! + k * (pos.latitude - _kLat!);
    _kLng = _kLng! + k * (pos.longitude - _kLng!);
    _kVariance = (1 - k) * _kVariance;

    // Return a Position with the smoothed coords
    return Position(
      latitude: _kLat!,
      longitude: _kLng!,
      accuracy: pos.accuracy,
      altitude: pos.altitude,
      altitudeAccuracy: pos.altitudeAccuracy,
      heading: pos.heading,
      headingAccuracy: pos.headingAccuracy,
      speed: pos.speed,
      speedAccuracy: pos.speedAccuracy,
      timestamp: pos.timestamp,
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

    // Try getting a fresh fix from the stream (more reliable on Android)
    try {
      final pos =
          await Geolocator.getPositionStream(
                locationSettings: const LocationSettings(
                  accuracy: LocationAccuracy.high,
                ),
              )
              .firstWhere((p) => p.accuracy <= 50)
              .timeout(const Duration(seconds: 15));
      resetSmoothing();
      return _smooth(pos);
    } catch (_) {}

    // Fallback: last known position
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return _smooth(last);
    } catch (_) {}

    return null;
  }

  static Stream<({Position smoothed, Position raw})> trackLocation({
    bool continuous = false,
  }) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: continuous ? 0 : 5,
        timeLimit: continuous ? const Duration(seconds: 2) : null,
      ),
    ).map((p) {
      final s = _smooth(p);
      try {
        debugPrint(
          '[MapService] raw=${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)} acc=${p.accuracy.toStringAsFixed(1)} -> smoothed=${s.latitude.toStringAsFixed(6)},${s.longitude.toStringAsFixed(6)}',
        );
      } catch (_) {}
      return (smoothed: s, raw: p);
    });
  }

  // ── Throttled Firestore writes ─────────────────────────
  static DateTime? _lastWrite;
  static double? _lastWriteLat;
  static double? _lastWriteLng;
  // last position that failed to write — flushed on next success
  static Position? _pendingPosition;
  static bool _writing = false;

  /// Write to Firestore only if ≥1 s has passed AND driver moved ≥5 m.
  /// Buffers the latest position when offline and flushes it when back online.
  static Future<void> updateDriverLocation(
    Position position, {
    double minDistanceMeters = 5,
    int minMillis = 1000,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      debugPrint(
        '[MapService] updateDriverLocation called uid=$uid lat=${position.latitude.toStringAsFixed(6)} lng=${position.longitude.toStringAsFixed(6)} acc=${position.accuracy.toStringAsFixed(1)} minDist=${minDistanceMeters}ms minMillis=$minMillis',
      );
    } catch (_) {}

    final now = DateTime.now();
    final movedEnough =
        _lastWriteLat == null ||
        distanceKm(
                  _lastWriteLat!,
                  _lastWriteLng!,
                  position.latitude,
                  position.longitude,
                ) *
                1000 >=
            minDistanceMeters;
    final timeOk =
        _lastWrite == null ||
        now.difference(_lastWrite!).inMilliseconds >= minMillis;

    if (!movedEnough || !timeOk) {
      try {
        debugPrint(
          '[MapService] SKIP write movedEnough=$movedEnough timeOk=$timeOk',
        );
      } catch (_) {}
      return;
    }
    if (_writing) {
      _pendingPosition = position;
      return;
    }

    _writing = true;
    try {
      await db.collection('drivers').doc(uid).update({
        'lat': position.latitude,
        'lng': position.longitude,
        'location': GeoPoint(position.latitude, position.longitude),
        'heading': position.heading,
        'locationUpdatedAt': FieldValue.serverTimestamp(),
      });
      _lastWrite = now;
      _lastWriteLat = position.latitude;
      _lastWriteLng = position.longitude;
      try {
        debugPrint(
          '[MapService] wrote drivers/$uid ${position.latitude.toStringAsFixed(6)},${position.longitude.toStringAsFixed(6)}',
        );
      } catch (_) {}
      // flush buffered position if it differs from what we just wrote
      final pending = _pendingPosition;
      _pendingPosition = null;
      if (pending != null &&
          (pending.latitude != position.latitude ||
              pending.longitude != position.longitude)) {
        _writing = false;
        await updateDriverLocation(pending);
        return;
      }
    } catch (e) {
      // network down — buffer latest position for next attempt
      try {
        debugPrint('[MapService] write failed: $e — buffering position');
      } catch (_) {}
      _pendingPosition = position;
    } finally {
      _writing = false;
    }
  }

  /// Haversine distance in km
  static double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  static double _rad(double deg) => deg * pi / 180;

  // ── Car marker bitmap ──────────────────────────────────
  // Cache bitmaps keyed by heading rounded to nearest 5°
  static final Map<int, BitmapDescriptor> _carBitmapCache = {};
  static ui.Image? _carSrcImage;

  /// Returns a rotated car icon as a BitmapDescriptor.
  /// [heading] is degrees clockwise from north (0–360).
  /// Bitmaps are cached per 5° bucket to avoid re-rendering every fix.
  static Future<BitmapDescriptor> carMarker(double heading) async {
    final bucket = ((heading / 5).round() * 5) % 360;
    if (_carBitmapCache.containsKey(bucket)) return _carBitmapCache[bucket]!;

    // Load source image once
    _carSrcImage ??= await () async {
      final byteData = await rootBundle.load('assets/car model.png');
      final codec = await ui.instantiateImageCodec(
        byteData.buffer.asUint8List(),
        targetWidth: 160,
        targetHeight: 107,
      );
      return (await codec.getNextFrame()).image;
    }();

    const outSize = 96.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, outSize, outSize));
    canvas.translate(outSize / 2, outSize / 2);
    canvas.rotate((bucket + 90) * pi / 180);
    canvas.translate(-outSize / 2, -outSize / 2);
    canvas.drawImageRect(
      _carSrcImage!,
      Rect.fromLTWH(0, 0, _carSrcImage!.width.toDouble(), _carSrcImage!.height.toDouble()),
      Rect.fromLTWH(0, 0, outSize, outSize),
      Paint()..filterQuality = FilterQuality.high,
    );
    final img = await recorder.endRecording().toImage(outSize.toInt(), outSize.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final descriptor = BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
    _carBitmapCache[bucket] = descriptor;
    return descriptor;
  }

  // ── Roads API snap-to-road ─────────────────────────────
  /// Snaps [pos] to the nearest road using the Roads API.
  /// Returns the snapped LatLng, or the original if the call fails.
  static Future<LatLng> snapToRoad(LatLng pos) async {
    try {
      debugPrint(
        '[MapService] snapToRoad request ${pos.latitude.toStringAsFixed(6)},${pos.longitude.toStringAsFixed(6)}',
      );
      final url = Uri.parse(
        'https://roads.googleapis.com/v1/nearestRoads'
        '?points=${pos.latitude},${pos.longitude}'
        '&key=$googleMapsApiKey',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) {
        debugPrint('[MapService] snapToRoad HTTP ${res.statusCode}');
        return pos;
      }
      final data = jsonDecode(res.body);
      final snapped = (data['snappedPoints'] as List?)?.firstOrNull;
      if (snapped == null) {
        debugPrint('[MapService] snapToRoad no snappedPoints');
        return pos;
      }
      final loc = snapped['location'];
      final snappedLat = (loc['latitude'] as num).toDouble();
      final snappedLng = (loc['longitude'] as num).toDouble();
      debugPrint(
        '[MapService] snapToRoad result ${snappedLat.toStringAsFixed(6)},${snappedLng.toStringAsFixed(6)}',
      );
      return LatLng(snappedLat, snappedLng);
    } catch (e) {
      debugPrint('[MapService] snapToRoad error: $e');
      return pos;
    }
  }

  /// Snaps a small sequence of points to the road using the Roads API
  /// with `interpolate=true`. Returns the snapped location corresponding to
  /// the last input point (or the last snapped point if mapping is unclear).
  static Future<LatLng> snapToRoads(List<LatLng> points) async {
    if (points.isEmpty) throw ArgumentError('points must not be empty');
    try {
      final path = points.map((p) => '${p.latitude},${p.longitude}').join('|');
      debugPrint('[MapService] snapToRoads request path=$path');
      final url = Uri.parse(
        'https://roads.googleapis.com/v1/snapToRoads'
        '?path=$path&interpolate=true&key=$googleMapsApiKey',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        debugPrint('[MapService] snapToRoads HTTP ${res.statusCode}');
        return points.last;
      }
      final data = jsonDecode(res.body);
      final snappedPoints = (data['snappedPoints'] as List?) ?? [];
      if (snappedPoints.isEmpty) {
        debugPrint('[MapService] snapToRoads no snappedPoints');
        return points.last;
      }
      // Try to find the snapped point that corresponds to the final original
      // input point. The API may include an `originalIndex` for exact matches.
      final lastOriginalIndex = points.length - 1;
      Map<String, dynamic>? match;
      for (final sp in snappedPoints) {
        if (sp is Map && sp.containsKey('originalIndex')) {
          if (sp['originalIndex'] == lastOriginalIndex) {
            match = sp as Map<String, dynamic>;
            break;
          }
        }
      }
      final chosen = match ?? (snappedPoints.last as Map<String, dynamic>);
      final loc = chosen['location'] as Map<String, dynamic>?;
      if (loc == null) return points.last;
      final snappedLat = (loc['latitude'] as num).toDouble();
      final snappedLng = (loc['longitude'] as num).toDouble();
      debugPrint(
        '[MapService] snapToRoads result ${snappedLat.toStringAsFixed(6)},${snappedLng.toStringAsFixed(6)}',
      );
      return LatLng(snappedLat, snappedLng);
    } catch (e) {
      debugPrint('[MapService] snapToRoads error: $e');
      return points.last;
    }
  }
}
