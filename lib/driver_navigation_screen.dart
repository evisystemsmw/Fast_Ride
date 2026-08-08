import 'dart:async';
import 'dart:convert';
import 'dart:math' show cos, sin, sqrt, atan2, pi;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'map_service.dart';
import 'db.dart';
import 'wakelock_wrapper.dart';

const _navy = Color(0xFF143B58);

class _NavStep {
  final LatLng endLocation;
  final double distanceM;
  final String instruction;
  final String maneuver;
  const _NavStep({
    required this.endLocation,
    required this.distanceM,
    required this.instruction,
    required this.maneuver,
  });
}

IconData _maneuverIcon(String m) {
  if (m.contains('left')) return Icons.turn_left_rounded;
  if (m.contains('right')) return Icons.turn_right_rounded;
  if (m.contains('uturn')) return Icons.u_turn_left_rounded;
  if (m.contains('roundabout')) return Icons.roundabout_left_rounded;
  if (m.contains('merge') || m.contains('ramp')) return Icons.merge_rounded;
  return Icons.straight_rounded;
}

double _bearingBetween(LatLng a, LatLng b) {
  final lat1 = a.latitude * pi / 180;
  final lat2 = b.latitude * pi / 180;
  final dLng = (b.longitude - a.longitude) * pi / 180;
  final y = sin(dLng) * cos(lat2);
  final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

double _distMBetween(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * pi / 180;
  final dLng = (b.longitude - a.longitude) * pi / 180;
  final s =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(a.latitude * pi / 180) *
          cos(b.latitude * pi / 180) *
          sin(dLng / 2) *
          sin(dLng / 2);
  return r * 2 * atan2(sqrt(s), sqrt(1 - s));
}

class DriverNavigationScreen extends StatefulWidget {
  final VoidCallback? onRideAccepted;
  final Map<String, dynamic> rideData;
  const DriverNavigationScreen({super.key, this.onRideAccepted, this.rideData = const {}});

  @override
  State<DriverNavigationScreen> createState() => _DriverNavigationScreenState();
}

class _DriverNavigationScreenState extends State<DriverNavigationScreen> {
  final Completer<GoogleMapController> _mapController = Completer();

  Position? _currentPosition;
  StreamSubscription<({Position smoothed, Position raw})>? _locationSub;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  Map<String, dynamic>? _activeRide;
  String? _activeRideId;
  Map<String, dynamic>? _pendingRide;
  String? _pendingRideId;
  // trip phase: null | 'en_route' | 'in_trip' | 'completed'
  String? _tripPhase;

  // Malawi bounded search
  static const _defaultTarget = LatLng(-13.9626, 33.7741);

  // search state
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _suggestions = [];
  bool _searching = false;
  LatLng? _selectedDestination;
  String _selectedDescription = '';
  bool _selfNavigating = false;
  bool _bookingForCustomer = false;
  bool _bookingLoading = false;
  final _passengerNameCtrl = TextEditingController();
  final _passengerPhoneCtrl = TextEditingController();
  double _distanceKm = 0;
  String _nextInstruction = '';
  String _nextManeuver = '';
  int _etaSeconds = 0;
  Timer? _etaTimer;
  List<_NavStep> _steps = [];
  int _stepIndex = 0;
  LatLng? _lastDriverLatLng;
  LatLng? _lastRawLatLng; // raw GPS used for snapToRoads path (not smoothed)
  bool _isNavigating = false; // true when a route is active
  double _currentSpeedKmh = 0;
  double _currentHeading = 0;
  final double _cardOffset = 0;
  bool _cardMinimized = false;
  // fare config
  double _baseFee = 2500;
  double _pricePerKm = 2500;
  double _shortDistanceFee = 10000;
  double _shortDistanceThresholdKm = 2.8;
  double _subscriptionRate = 0; // cached at load, used as offline fallback
  // in_trip tracking
  double _tripDistanceKm = 0;
  Position? _lastTripPosition;
  LatLng? _lastTripLatLng;
  // network resilience
  List<LatLng> _lastGoodPolyline = [];
  Timer? _routeRefreshTimer;
  Timer? _distanceSyncTimer;
  bool _routeDrawing = false;
  bool _distanceDirty = false;
  bool _completing = false;
  final FlutterTts _tts = FlutterTts();
  String _lastSpokenInstruction = '';
  bool _voiceEnabled =
      true; // true when local distance ahead of last Firestore write

  // ── Road snapping / off-road detection ───────────────────────────────────
  int _offRoadCount = 0; // consecutive fixes off the polyline
  bool _showOffRoadWarning = false;
  static const _snapThresholdM = 30.0; // snap to road if within 30 m
  static const _offRoadThresholdM = 50.0; // flag as off-road beyond 50 m
  static const _offRoadConsecutive = 3; // fixes needed to confirm off-road

  // ── Arrival auto-detection ───────────────────────────────────────────────
  bool _arrivedAtPickup = false; // guard: en_route → arrived fired once
  bool _arrivedAtDest = false; // guard: in_trip destination reached
  bool _showDestArrivalBanner = false;

  // ── Car marker ───────────────────────────────────────────────────────────
  Marker? _carMarker;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _etaTimer?.cancel();
    _routeRefreshTimer?.cancel();
    _distanceSyncTimer?.cancel();
    _searchController.dispose();
    _passengerNameCtrl.dispose();
    _passengerPhoneCtrl.dispose();
    MapService.resetSmoothing();
    _tts.stop();
    if (_mapController.isCompleted) {
      _mapController.future.then((c) => c.dispose()).catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    _listenActiveRide();
    _loadFareConfig();
    final position = await MapService.getCurrentPosition();
    if (position != null && mounted) {
      setState(() => _currentPosition = position);
      // Only start tracking here if _listenActiveRide() hasn't already
      // started continuous tracking for an in_trip restore.
      if (_tripPhase != 'in_trip') {
        _startTracking(continuous: false);
      }
      _animateToPosition(position);
      // Always draw route once GPS is ready — covers the case where
      // Firestore resolved before GPS (activeRide set, position was null).
      if (_activeRide != null) {
        _drawRouteForPhase(position);
      }
    }
  }

  void _drawRouteForPhase(Position position) {
    if (_activeRide == null) return;
    final origin = LatLng(position.latitude, position.longitude);
    if (_tripPhase == 'in_trip') {
      final destGeo = _activeRide!['destinationLocation'] as GeoPoint?;
      if (destGeo != null) {
        _drawRoute(origin, LatLng(destGeo.latitude, destGeo.longitude));
      } else {
        // geocode from string fallback
        final destStr = _activeRide!['destination'] as String? ?? '';
        if (destStr.isNotEmpty) {
          http
              .get(
                Uri.parse(
                  'https://maps.googleapis.com/maps/api/geocode/json'
                  '?address=${Uri.encodeComponent(destStr)}'
                  '&key=$geocodingApiKey',
                ),
              )
              .then((res) {
                final data = jsonDecode(res.body);
                final loc = data['results']?[0]?['geometry']?['location'];
                if (loc != null) {
                  _drawRoute(
                    origin,
                    LatLng(
                      (loc['lat'] as num).toDouble(),
                      (loc['lng'] as num).toDouble(),
                    ),
                  );
                }
              })
              .catchError((_) {});
        }
      }
    } else {
      final pickupGeo = _activeRide!['pickupLocation'] as GeoPoint?;
      final pickupLat = (_activeRide!['pickupLat'] as num?)?.toDouble();
      final pickupLng = (_activeRide!['pickupLng'] as num?)?.toDouble();
      if (pickupGeo != null) {
        _drawRoute(origin, LatLng(pickupGeo.latitude, pickupGeo.longitude));
      } else if (pickupLat != null && pickupLng != null) {
        _drawRoute(origin, LatLng(pickupLat, pickupLng));
      }
    }
  }

  Future<void> _loadFareConfig() async {
    try {
      final doc = await db.collection('settings').doc('fare').get();
      final data = doc.data() ?? {};
      if (mounted) {
        setState(() {
          _baseFee = (data['baseFee'] as num?)?.toDouble() ?? 2500;
          _pricePerKm = (data['pricePerKm'] as num?)?.toDouble() ?? 2500;
          _shortDistanceFee =
              (data['shortDistanceFee'] as num?)?.toDouble() ?? 10000;
          _shortDistanceThresholdKm =
              (data['shortDistanceThresholdKm'] as num?)?.toDouble() ?? 2.8;
          _subscriptionRate =
              (data['subscriptionRate'] as num?)?.toDouble() ?? 0;
        });
        debugPrint(
          '[FARE_CONFIG] baseFee=$_baseFee pricePerKm=$_pricePerKm shortDistanceFee=$_shortDistanceFee shortDistanceThresholdKm=$_shortDistanceThresholdKm subscriptionRate=$_subscriptionRate%',
        );
      }
    } catch (_) {}
  }

  void _startTracking({bool continuous = false}) {
    _locationSub?.cancel();
    _locationSub = MapService.trackLocation(continuous: continuous).listen((
      fix,
    ) async {
      if (!mounted) return;
      final position = fix.smoothed;
      final rawPosition = fix.raw;
      final latLng = LatLng(position.latitude, position.longitude);
      final rawLatLng = LatLng(rawPosition.latitude, rawPosition.longitude);
      final heading = position.heading >= 0
          ? position.heading
          : _currentHeading;
      // capture raw GPS before any smoothing is applied to snap calls
      // position here is already Kalman-smoothed by trackLocation()
      // we need the original raw coords — use the smoothed as proxy but
      // track separately so snap path uses consistent last-raw baseline
      
      // ── Arrival auto-detection ────────────────────────────────────────────
      if (_tripPhase == 'en_route' &&
          !_arrivedAtPickup &&
          _activeRide != null) {
        final pickupGeo = _activeRide!['pickupLocation'] as GeoPoint?;
        if (pickupGeo != null) {
          final distToPickup = _distMBetween(
            latLng,
            LatLng(pickupGeo.latitude, pickupGeo.longitude),
          );
          if (distToPickup <= 50) {
            _arrivedAtPickup = true;
            _speak('You have arrived at the pickup location.');
            await db.collection('rides').doc(_activeRideId).update({
              'tripPhase': 'arrived',
            });
            if (mounted)
              setState(() {
                _tripPhase = 'arrived';
                _cardMinimized = false;
              });
          }
        }
      }

      if (_tripPhase == 'in_trip' && !_arrivedAtDest && _activeRide != null) {
        final destGeo = _activeRide!['destinationLocation'] as GeoPoint?;
        if (destGeo != null) {
          final distToDest = _distMBetween(
            latLng,
            LatLng(destGeo.latitude, destGeo.longitude),
          );
          if (distToDest <= 50) {
            _arrivedAtDest = true;
            _speak('You have arrived at the destination.');
            if (mounted)
              setState(() {
                _showDestArrivalBanner = true;
                _cardMinimized = false;
              });
          }
        }
      }

      // ── Off-road detection (in_trip only) ──────────────────────────────────
      if (_tripPhase == 'in_trip' && _lastGoodPolyline.isNotEmpty) {
        final snap = _snapToPolyline(rawLatLng, _lastGoodPolyline);
        if (snap.distM <= _snapThresholdM) {
          _offRoadCount = 0;
          try {
            debugPrint(
              '[OFFROAD] on-route snap.distM=${snap.distM.toStringAsFixed(1)}m',
            );
          } catch (_) {}
          if (_showOffRoadWarning && mounted)
            setState(() => _showOffRoadWarning = false);
        } else if (snap.distM > _offRoadThresholdM) {
          try {
            debugPrint(
              '[OFFROAD] off-route snap.distM=${snap.distM.toStringAsFixed(1)}m count=${_offRoadCount + 1}',
            );
          } catch (_) {}
          _offRoadCount++;
          if (_offRoadCount >= _offRoadConsecutive &&
              !_showOffRoadWarning &&
              mounted) {
            setState(() => _showOffRoadWarning = true);
            _speak('You appear to be off the route.');
          }
        }
      }

      // ── Snap to road + update car marker ─────────────────────────────────
      LatLng snapped;
      if (position.accuracy <= 80) {
        // During in_trip: snap strictly to the active route polyline so the
        // car never jumps to a nearby parallel road.
        if (_tripPhase == 'in_trip' && _lastGoodPolyline.isNotEmpty) {
          final polySnap = _snapToPolyline(rawLatLng, _lastGoodPolyline);
          snapped = polySnap.distM <= 80 ? polySnap.snapped : rawLatLng;
        } else {
          // Outside in_trip: use Roads API (nearest road is fine)
          final skipSnap = _lastRawLatLng != null &&
              MapService.distanceKm(
                    _lastRawLatLng!.latitude,
                    _lastRawLatLng!.longitude,
                    rawLatLng.latitude,
                    rawLatLng.longitude,
                  ) *
                  1000 <
              3.0;
          if (skipSnap) {
            snapped = _lastDriverLatLng ?? rawLatLng;
          } else if (_lastRawLatLng != null) {
            try {
              snapped = await MapService.snapToRoads([
                _lastRawLatLng!,
                rawLatLng,
              ]);
            } catch (_) {
              snapped = await MapService.snapToRoad(rawLatLng);
            }
          } else {
            snapped = await MapService.snapToRoad(rawLatLng);
          }
        }
      } else {
        // Poor accuracy — keep car on last known road position to avoid
        // jumping off-road. Only fall back to raw latLng on first fix.
        snapped = _lastDriverLatLng ?? latLng;
      }
      final carIcon = await MapService.carMarker(heading);
      if (!mounted) return;
      final newCarMarker = Marker(
        markerId: const MarkerId('car'),
        position: snapped,
        icon: carIcon,
        flat: true,
        anchor: const Offset(0.5, 0.5),
        zIndex: 3,
      );

      setState(() {
        _currentPosition = position;
        _currentSpeedKmh = (rawPosition.speed * 3.6).clamp(0, 300);
        _currentHeading = heading;
        _lastDriverLatLng = snapped;
        _lastRawLatLng = rawLatLng;
        _carMarker = newCarMarker;
      });
      await MapService.updateDriverLocation(
        rawPosition,
        minDistanceMeters: _tripPhase == 'in_trip' ? 2 : 5,
        minMillis: _tripPhase == 'in_trip' ? 500 : 1000,
      );

      // accumulate distance during in_trip
      debugPrint(
        '[STATUS] phase=$_tripPhase | activeRide=$_activeRideId | speed=${(rawPosition.speed * 3.6).toStringAsFixed(1)}km/h | acc=${rawPosition.accuracy.toStringAsFixed(1)}m | pos=(${rawPosition.latitude.toStringAsFixed(6)},${rawPosition.longitude.toStringAsFixed(6)})',
      );
      if (_tripPhase == 'in_trip') {
        if (_lastTripPosition == null) {
          // first fix — anchor baseline to raw GPS
          _lastTripPosition = rawPosition;
          _lastTripLatLng = rawLatLng;
          debugPrint(
            '[TRIP] Baseline anchored at (${rawPosition.latitude.toStringAsFixed(6)}, ${rawPosition.longitude.toStringAsFixed(6)})',
          );
        } else if (rawPosition.accuracy <= 80) {
          // Always measure from true raw GPS — Kalman smoothing causes lag/undercounting
          final prev = _lastTripLatLng ?? rawLatLng;
          final delta = MapService.distanceKm(
            prev.latitude,
            prev.longitude,
            rawLatLng.latitude,
            rawLatLng.longitude,
          );
          final capped = delta.clamp(0.0, 0.3);
          final speedKmh = rawPosition.speed * 3.6;
          final meters = capped * 1000;
          debugPrint(
            '[MOVE] raw=${(delta * 1000).toStringAsFixed(1)}m capped=${meters.toStringAsFixed(1)}m speed=${speedKmh.toStringAsFixed(1)}km/h acc=${rawPosition.accuracy.toStringAsFixed(1)}m',
          );
          final jumpLimit = rawPosition.accuracy > 50 ? 0.08 : 0.12;
          if ((delta > 0.5 && speedKmh < 20) ||
              (delta > jumpLimit && speedKmh < 5)) {
            debugPrint(
              '[MOVE] REJECTED — probable GPS jump: delta=${(delta * 1000).toStringAsFixed(1)}m speed=${speedKmh.toStringAsFixed(1)}km/h',
            );
            return;
          }
          if (meters > 5) {
            final before = _tripDistanceKm;
            setState(() {
              _tripDistanceKm += capped;
              _distanceDirty = true;
            });
            _lastTripPosition = rawPosition;
            _lastTripLatLng = rawLatLng;
            final liveFare = _tripDistanceKm <= _shortDistanceThresholdKm
                ? _shortDistanceFee
                : _baseFee + _tripDistanceKm * _pricePerKm;
            debugPrint(
              '[DIST] +${meters.toStringAsFixed(1)}m | ${before.toStringAsFixed(3)}km → ${_tripDistanceKm.toStringAsFixed(3)}km | liveFare=MWK${liveFare.toStringAsFixed(0)}',
            );
          } else {
            debugPrint(
              '[MOVE] REJECTED — delta≤5m | delta=${meters.toStringAsFixed(1)}m',
            );
          }
        } else {
          debugPrint(
            '[MOVE] REJECTED — acc=${rawPosition.accuracy.toStringAsFixed(1)}m > 80m',
          );
        }
      }

      // ── Trim polyline to remaining route ahead ────────────────────────────
      if (_isNavigating && _lastGoodPolyline.isNotEmpty) {
        final trimmed = _trimPolyline(snapped, _lastGoodPolyline);
        if (trimmed.length >= 2) {
          setState(() {
            _polylines = {
              Polyline(
                polylineId: const PolylineId('route'),
                points: trimmed,
                color: _navy,
                width: 5,
              ),
            };
          });
        }
      }

      // ── Camera always follows driver position ────────────────────────────
      if (_mapController.isCompleted) {
        // When accuracy is poor the car marker is frozen at last snapped pos,
        // but the camera should still follow the real GPS movement.
        final cameraTarget = position.accuracy <= 80 ? snapped : latLng;
        try {
          final c = await _mapController.future;
          await c.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: cameraTarget,
                zoom: _isNavigating ? 17.5 : 16.0,
                tilt: _isNavigating ? 60 : 0,
                bearing: _isNavigating ? heading : 0,
              ),
            ),
          );
        } catch (_) {}
      }

      // ── advance steps ───────────────────────────────────────────────────
      if (_isNavigating && _steps.isNotEmpty && _stepIndex < _steps.length) {
        final step = _steps[_stepIndex];
        final distToStepEnd = _distMBetween(snapped, step.endLocation);

        // advance when within 25m of the step end-point
        if (distToStepEnd < 25) {
          if (_stepIndex + 1 < _steps.length) {
            _stepIndex++;
            final next = _steps[_stepIndex];
            setState(() {
              _nextInstruction = next.instruction;
              _nextManeuver = next.maneuver;
            });
            final key = 'step:$_stepIndex';
            if (_lastSpokenInstruction != key) {
              _lastSpokenInstruction = key;
              _speak(next.instruction);
            }
          }
        }

        // remaining distance = dist to current step end + all subsequent steps
        double rem = distToStepEnd;
        for (int i = _stepIndex + 1; i < _steps.length; i++) {
          rem += _steps[i].distanceM;
        }
        if (mounted) setState(() => _distanceKm = rem / 1000);

        // announce upcoming turn at ~300m and ~100m
        final announceKey300 = '300:$_stepIndex';
        final announceKey100 = '100:$_stepIndex';
        if (_lastSpokenInstruction != announceKey300 &&
            distToStepEnd < 320 &&
            distToStepEnd > 250) {
          _lastSpokenInstruction = announceKey300;
          _speak('In ${_distanceText(distToStepEnd)}, ${step.instruction}');
        } else if (_lastSpokenInstruction != announceKey100 &&
            distToStepEnd < 120 &&
            distToStepEnd > 60) {
          _lastSpokenInstruction = announceKey100;
          _speak('${_distanceText(distToStepEnd)}, ${step.instruction}');
        }

        // reroute if off-route: snap distance > 80m and moving
        if (_lastGoodPolyline.isNotEmpty && _currentSpeedKmh > 5 && !_routeDrawing) {
          final snapDist = _snapToPolyline(snapped, _lastGoodPolyline).distM;
          if (snapDist > 80) {
            _drawRouteForPhase(position);
          }
        }
      } else if (_isNavigating &&
          _steps.isEmpty &&
          _currentPosition != null &&
          !_routeDrawing) {
        // steps not loaded yet — redraw route
        _drawRouteForPhase(position);
      }
    });
  }

  void _listenActiveRide() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // listen for requested (pending) rides booked by this driver
    db
        .collection('rides')
        .where('driverId', isEqualTo: uid)
        .where('status', isEqualTo: 'requested')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          if (snap.docs.isNotEmpty) {
            final doc = snap.docs.first;
            setState(() {
              _pendingRide = doc.data();
              _pendingRideId = doc.id;
            });
          } else {
            setState(() {
              _pendingRide = null;
              _pendingRideId = null;
            });
          }
        });

    // listen for accepted/in_trip rides
    db
        .collection('rides')
        .where('driverId', isEqualTo: uid)
        .where('status', whereIn: ['accepted', 'in_trip'])
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          if (snap.docs.isNotEmpty) {
            final doc = snap.docs.first;
            final data = doc.data();
            final wasNull = _activeRide == null;
            final savedPhase = data['tripPhase'] as String?;
            final savedDistanceKm =
                (data['tripDistanceKm'] as num?)?.toDouble() ?? 0;
            setState(() {
              _activeRide = data;
              _activeRideId = doc.id;
              // Never let Firestore snapshots overwrite a locally-driven phase
              // Only set phase from Firestore on first load
              if (wasNull) {
                _tripPhase = savedPhase ?? 'en_route';
                _tripDistanceKm = savedDistanceKm;
                _lastTripPosition =
                    null; // anchor on first live GPS fix, not stale position
                _arrivedAtPickup =
                    savedPhase == 'arrived' || savedPhase == 'in_trip';
                _arrivedAtDest = false;
              }
            });
            if (wasNull) {
              if (_tripPhase != 'in_trip') widget.onRideAccepted?.call();
              _addRideMarkers(data);
              if (_tripPhase == 'in_trip') {
                try {
                  enableWakelock();
                  debugPrint('[Wakelock] enabled (resume in_trip)');
                } catch (_) {}
                _startTracking(continuous: true);
                _startRouteRefreshTimer();
              }
              // Draw route now if position is ready, otherwise _init() will
              // call _drawRouteForPhase once GPS resolves.
              if (_currentPosition != null) {
                _drawRouteForPhase(_currentPosition!);
              }
            }
          } else {
            setState(() {
              _activeRide = null;
              _activeRideId = null;
              _tripPhase = null;
              _tripDistanceKm = 0;
              _lastTripPosition = null;
              _markers = {};
              _polylines = {};
            });
          }
        });
  }

  void _addRideMarkers(Map<String, dynamic> ride) {
    final pickupGeo = ride['pickupLocation'] as GeoPoint?;
    final destLat = (ride['destinationLat'] as num?)?.toDouble();
    final destLng = (ride['destinationLng'] as num?)?.toDouble();

    final newMarkers = <Marker>{};

    if (pickupGeo != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: LatLng(pickupGeo.latitude, pickupGeo.longitude),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
          infoWindow: InfoWindow(title: 'Pickup: ${ride['pickup'] ?? ''}'),
        ),
      );
    }

    if (destLat != null && destLng != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: LatLng(destLat, destLng),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Destination: ${ride['destination'] ?? ''}',
          ),
        ),
      );
    }

    setState(() => _markers = newMarkers);
  }

  Future<void> _drawRoute(
    LatLng origin,
    LatLng destination, {
    int attempt = 0,
  }) async {
    if (_routeDrawing) return;
    _routeDrawing = true;
    try {
      debugPrint(
        '[ROUTE] draw start ${origin.latitude.toStringAsFixed(6)},${origin.longitude.toStringAsFixed(6)} -> ${destination.latitude.toStringAsFixed(6)},${destination.longitude.toStringAsFixed(6)} attempt=$attempt',
      );
    } catch (_) {}
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&mode=driving'
        '&key=$directionsApiKey',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body);
      final status = data['status'] as String? ?? 'UNKNOWN';
      if (status != 'OK') throw Exception('Directions API: $status');
      if ((data['routes'] as List).isEmpty) throw Exception('No routes');

      final leg = data['routes'][0]['legs'][0];
      final distanceM = (leg['distance']['value'] as num).toDouble();
      final durationS = (leg['duration']['value'] as num).toInt();
      try {
        debugPrint(
          '[ROUTE] legs distance=${distanceM.toStringAsFixed(0)}m duration=${durationS}s steps=${(leg['steps'] as List).length}',
        );
      } catch (_) {}

      final stepsList = (leg['steps'] as List).map((s) {
        final eLoc = s['end_location'];
        return _NavStep(
          endLocation: LatLng(eLoc['lat'], eLoc['lng']),
          distanceM: (s['distance']['value'] as num).toDouble(),
          instruction: (s['html_instructions'] as String).replaceAll(
            RegExp(r'<[^>]*>'),
            '',
          ),
          maneuver: s['maneuver'] ?? '',
        );
      }).toList();

      final points = data['routes'][0]['overview_polyline']['points'] as String;
      final decoded = _decodePolyline(points);
      _lastGoodPolyline = decoded; // cache for network failures

      if (mounted) {
        setState(() {
          _distanceKm = distanceM / 1000;
          _etaSeconds = durationS;
          _steps = stepsList;
          _stepIndex = 0;
          _nextInstruction = stepsList.isNotEmpty
              ? stepsList.first.instruction
              : '';
          _nextManeuver = stepsList.isNotEmpty ? stepsList.first.maneuver : '';
          _isNavigating = true;
          // Always announce the first step (including on reroute)
          if (stepsList.isNotEmpty) {
            final isFirstDraw = !_isNavigating;
            _lastSpokenInstruction = 'step:0';
            Future.delayed(
              const Duration(milliseconds: 800),
              () => _speak(
                isFirstDraw
                    ? 'Navigation started. ${stepsList.first.instruction}'
                    : 'Rerouting. ${stepsList.first.instruction}',
              ),
            );
          }
          _polylines = {
            Polyline(
              polylineId: const PolylineId('route'),
              points: decoded,
              color: _navy,
              width: 5,
            ),
          };
        });
        _etaTimer?.cancel();
        _etaTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted && _etaSeconds > 0) setState(() => _etaSeconds--);
        });
        // only snap camera to route overview when NOT actively navigating
        if (_mapController.isCompleted && !_isNavigating) {
          try {
            final c = await _mapController.future;
            await c.animateCamera(CameraUpdate.newLatLngZoom(destination, 14));
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('_drawRoute error: $e');
      // restore last good polyline so map doesn't go blank
      if (mounted && _lastGoodPolyline.isNotEmpty && _polylines.isEmpty) {
        setState(() {
          _polylines = {
            Polyline(
              polylineId: const PolylineId('route'),
              points: _lastGoodPolyline,
              color: _navy.withValues(alpha: 0.5),
              width: 5,
            ),
          };
        });
      }
      if (attempt < 3 && mounted) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        _routeDrawing = false;
        _drawRoute(origin, destination, attempt: attempt + 1);
        return;
      }
    } finally {
      _routeDrawing = false;
    }
  }

  void _startRouteRefreshTimer() {
    _routeRefreshTimer?.cancel();
    // every 90 s during in_trip, refresh route if polyline is empty
    _routeRefreshTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (!mounted || _tripPhase != 'in_trip' || _currentPosition == null)
        return;
      if (_polylines.isEmpty || _steps.isEmpty) {
        _drawRouteForPhase(_currentPosition!);
      }
    });
    // every 10 s, flush accumulated distance to Firestore if dirty
    _distanceSyncTimer?.cancel();
    _distanceSyncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted || _tripPhase != 'in_trip' || !_distanceDirty) return;
      if (_activeRideId == null) return;
      try {
        await db.collection('rides').doc(_activeRideId).update({
          'tripDistanceKm': _tripDistanceKm,
        });
        debugPrint(
          '[SYNC] Firestore updated tripDistanceKm=${_tripDistanceKm.toStringAsFixed(3)}km',
        );
        if (mounted) setState(() => _distanceDirty = false);
      } catch (e) {
        debugPrint('[SYNC] Firestore write failed: $e');
      }
    });
  }

  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0;
    int lat = 0, lng = 0;
    while (index < encoded.length) {
      int shift = 0, result = 0, b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  Future<void> _searchPlaces(String query) async {
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    setState(() => _searching = true);
    final url = Uri.parse(
      'https://places.googleapis.com/v1/places:autocomplete',
    );
    try {
      final res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': placesApiKey,
        },
        body: jsonEncode({
          'input': query,
          'includedRegionCodes': ['mw'],
        }),
      );
      final data = jsonDecode(res.body);
      if (mounted) {
        final suggestions = (data['suggestions'] as List? ?? [])
            .map(
              (s) => {
                'placeId': s['placePrediction']['placeId'] as String,
                'description': s['placePrediction']['text']['text'] as String,
              },
            )
            .toList()
            .cast<Map<String, dynamic>>();
        setState(() {
          _suggestions = suggestions;
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _selectPlace(String placeId, String description) async {
    _searchController.text = description;
    setState(() => _suggestions = []);
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json'
      '?place_id=$placeId'
      '&key=$geocodingApiKey',
    );
    final res = await http.get(url);
    final data = jsonDecode(res.body);
    final loc = data['results']?[0]?['geometry']?['location'];
    if (loc == null) return;
    final target = LatLng(loc['lat'], loc['lng']);
    setState(() {
      _selectedDestination = target;
      _selectedDescription = description;
      _markers = {
        ..._markers.where(
          (m) => m.markerId.value != 'search' && m.markerId.value != 'driver',
        ),
        Marker(
          markerId: const MarkerId('search'),
          position: target,
          infoWindow: InfoWindow(title: description),
        ),
      };
    });
    if (_mapController.isCompleted) {
      try {
        final c = await _mapController.future;
        await c.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
      } catch (_) {}
    }
    // draw route from current position
    if (_currentPosition != null) {
      await _drawRoute(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        target,
      );
    }
    // show options bottom sheet
    if (mounted) _showTravelOptions(target, description);
  }

  void _clearSearchState() {
    _etaTimer?.cancel();
    setState(() {
      _selectedDestination = null;
      _selectedDescription = '';
      _searchController.clear();
      _suggestions = [];
      _isNavigating = false;
      _polylines = {};
      _distanceKm = 0;
      _nextInstruction = '';
      _nextManeuver = '';
      _etaSeconds = 0;
      _steps = [];
      _stepIndex = 0;
      _lastGoodPolyline = [];
      _markers = _markers
          .where((m) => m.markerId.value != 'search')
          .toSet();
    });
  }

  void _showTravelOptions(LatLng destination, String description) {
    bool optionChosen = false;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.location_on_rounded, color: _navy, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    description,
                    style: const TextStyle(
                      color: _navy,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _OptionButton(
                    icon: Icons.drive_eta_rounded,
                    label: 'Self Travel',
                    subtitle: 'Navigate for yourself',
                    color: _navy,
                    onTap: () {
                      optionChosen = true;
                      Navigator.pop(context);
                      setState(() => _selfNavigating = true);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _OptionButton(
                    icon: Icons.person_add_rounded,
                    label: 'Book Customer',
                    subtitle: 'Create a ride request',
                    color: const Color(0xFF2E7D32),
                    onTap: () {
                      optionChosen = true;
                      Navigator.pop(context);
                      setState(() => _bookingForCustomer = true);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ).then((_) {
      // dismissed without choosing — clean up search state
      if (!optionChosen && mounted) _clearSearchState();
    });
  }

  Future<void> _bookForCustomer(
    LatLng destination,
    String description, {
    required String name,
    required String phone,
  }) async {
    if (_currentPosition == null) return;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    await db.collection('rides').add({
      'status': 'requested',
      'driverId': uid,
      'destination': description,
      'destinationLocation': GeoPoint(
        destination.latitude,
        destination.longitude,
      ),
      'pickup': 'Driver current location',
      'pickupLocation': GeoPoint(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      ),
      'passengerName': name,
      'passengerPhone': phone,
      'passengerId': '',
      'bookedByDriver': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _cancelWithFee() async {
    final rideId = _activeRideId;
    if (rideId == null) return;
    double cancellationFee = 0;
    double subscriptionRate = 0;
    try {
      final fareDoc = await db.collection('settings').doc('fare').get();
      cancellationFee =
          (fareDoc.data()?['cancellationFee'] as num?)?.toDouble() ?? 0;
      subscriptionRate =
          (fareDoc.data()?['subscriptionRate'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
    if (!mounted) return;
    final confirmed = await _showCancelFeeSheet(cancellationFee);
    if (confirmed != true) return;
    final subFee = cancellationFee * (subscriptionRate / 100);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await db.collection('rides').doc(rideId).update({
      'status': 'cancelled',
      'cancelledByPassenger': false,
      'cancellationFee': cancellationFee,
      'subscriptionFeeCharged': subFee,
    });
    if (uid != null && subFee > 0) {
      try {
        await db.collection('drivers').doc(uid).update({
          'subscriptionBalance': FieldValue.increment(subFee),
        });
      } catch (_) {}
    }
    _resetTripState();
  }

  Future<bool?> _showCancelFeeSheet(double fee) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(context).padding.bottom + 20,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFD32F2F).withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cancel_outlined,
                color: Color(0xFFD32F2F),
                size: 36,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Cancel Ride?',
              style: TextStyle(
                color: _navy,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              fee > 0
                  ? 'A cancellation fee will be added to your subscription balance.'
                  : 'Are you sure you want to cancel this ride?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _navy.withValues(alpha: 0.55),
                fontSize: 13,
              ),
            ),
            if (fee > 0) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFD32F2F).withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0xFFD32F2F).withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Cancellation Fee',
                      style: TextStyle(
                        color: _navy,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'MWK ${fee.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Color(0xFFD32F2F),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: _navy.withValues(alpha: 0.3)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Go Back',
                      style: TextStyle(color: _navy),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD32F2F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Yes, Cancel',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _speak(String text) async {
    if (!_voiceEnabled || text.isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  String _distanceText(double meters) {
    if (meters < 50) return 'now';
    if (meters < 200) return 'in ${meters.toInt()} meters';
    if (meters < 1000) return 'in ${(meters / 100).round() * 100} meters';
    return 'in ${(meters / 1000).toStringAsFixed(1)} kilometers';
  }

  /// Returns the closest point on [polyline] to [point], and the distance to it.
  ({LatLng snapped, double distM}) _snapToPolyline(
    LatLng point,
    List<LatLng> polyline,
  ) {
    if (polyline.isEmpty) return (snapped: point, distM: 0);
    LatLng best = polyline.first;
    double bestDist = _distMBetween(point, polyline.first);
    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];
      // project point onto segment a→b
      final ax = b.latitude - a.latitude;
      final ay = b.longitude - a.longitude;
      final len2 = ax * ax + ay * ay;
      if (len2 == 0) continue;
      final t =
          ((point.latitude - a.latitude) * ax +
              (point.longitude - a.longitude) * ay) /
          len2;
      final tc = t.clamp(0.0, 1.0);
      final proj = LatLng(a.latitude + tc * ax, a.longitude + tc * ay);
      final d = _distMBetween(point, proj);
      if (d < bestDist) {
        bestDist = d;
        best = proj;
      }
    }
    return (snapped: best, distM: bestDist);
  }

  /// Returns the polyline from the closest point to [pos] forward.
  List<LatLng> _trimPolyline(LatLng pos, List<LatLng> polyline) {
    if (polyline.length < 2) return polyline;
    int bestSegment = 0;
    double bestDist = double.infinity;
    double bestT = 0;
    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];
      final ax = b.latitude - a.latitude;
      final ay = b.longitude - a.longitude;
      final len2 = ax * ax + ay * ay;
      if (len2 == 0) continue;
      final t =
          ((pos.latitude - a.latitude) * ax +
              (pos.longitude - a.longitude) * ay) /
          len2;
      final tc = t.clamp(0.0, 1.0);
      final proj = LatLng(a.latitude + tc * ax, a.longitude + tc * ay);
      final d = _distMBetween(pos, proj);
      if (d < bestDist) {
        bestDist = d;
        bestSegment = i;
        bestT = tc;
      }
    }
    // Only trim if we're reasonably close to the route (within 80m)
    if (bestDist > 80) return polyline;
    final a = polyline[bestSegment];
    final b = polyline[bestSegment + 1];
    final splitPoint = LatLng(
      a.latitude + bestT * (b.latitude - a.latitude),
      a.longitude + bestT * (b.longitude - a.longitude),
    );
    return [splitPoint, ...polyline.sublist(bestSegment + 1)];
  }

  void _resetTripState() {
    _etaTimer?.cancel();
    _routeRefreshTimer?.cancel();
    _distanceSyncTimer?.cancel();
    _startTracking(); // back to normal 5m filter
    // allow device to sleep again
    try {
      disableWakelock();
      debugPrint('[Wakelock] disabled (trip reset)');
    } catch (_) {}
    setState(() {
      _tripPhase = null;
      _activeRide = null;
      _activeRideId = null;
      _tripDistanceKm = 0;
      _lastTripPosition = null;
      _polylines = {};
      _distanceKm = 0;
      _nextInstruction = '';
      _nextManeuver = '';
      _etaSeconds = 0;
      _steps = [];
      _stepIndex = 0;
      _isNavigating = false;
      _offRoadCount = 0;
      _showOffRoadWarning = false;
      _arrivedAtPickup = false;
      _arrivedAtDest = false;
      _showDestArrivalBanner = false;
      _markers = _markers.where((m) => m.markerId.value != 'driver').toSet();
    });
  }

  void _showCompletionSheet(
    Map<String, dynamic> ride,
    double distKm,
    double fare,
    double subscriptionFee,
  ) {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(context).padding.bottom + 20,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Colors.green,
                size: 48,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Trip Completed!',
              style: TextStyle(
                color: _navy,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Please collect payment from passenger',
              style: TextStyle(
                color: _navy.withValues(alpha: 0.5),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            // Big fare display
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: _navy,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Text(
                    'Amount to Collect',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    distKm <= _shortDistanceThresholdKm
                        ? 'MWK ${_shortDistanceFee.toStringAsFixed(0)}'
                        : 'MWK ${fare.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 36,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    distKm <= _shortDistanceThresholdKm
                        ? 'Flat rate'
                        : '${distKm.toStringAsFixed(2)} km',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Subscription fee row
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _navy.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.receipt_outlined, color: _navy, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'Subscription fee',
                    style: TextStyle(
                      color: _navy.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'MWK ${subscriptionFee.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: _navy,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _RideInfoRow(
              icon: Icons.person_outline,
              label: 'Passenger',
              value: ride['passengerName'] ?? '',
            ),
            const SizedBox(height: 8),
            _RideInfoRow(
              icon: Icons.location_on_outlined,
              label: 'Destination',
              value: ride['destination'] ?? '',
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: const Icon(Icons.payments_rounded, size: 20),
                label: const Text(
                  'Payment Received',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSearchSheet() {
    _searchController.clear();
    setState(() => _suggestions = []);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setModalState) {
          void safeSetModal(VoidCallback fn) {
            if (ctx.mounted) setModalState(fn);
          }

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: _navy.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      onChanged: (q) async {
                        await _searchPlaces(q);
                        safeSetModal(() {});
                      },
                      style: const TextStyle(color: _navy, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search location in Malawi...',
                        hintStyle: TextStyle(
                          color: _navy.withValues(alpha: 0.4),
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: _navy,
                        ),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _navy,
                                  ),
                                ),
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  if (_suggestions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _suggestions.length > 5
                          ? 5
                          : _suggestions.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: _navy.withValues(alpha: 0.08),
                      ),
                      itemBuilder: (_, i) {
                        final s = _suggestions[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.location_on_outlined,
                            color: _navy,
                            size: 18,
                          ),
                          title: Text(
                            s['description'],
                            style: const TextStyle(color: _navy, fontSize: 13),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _selectPlace(s['placeId'], s['description']);
                          },
                        );
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _animateToPosition(Position position) async {
    if (!_mapController.isCompleted) return;
    try {
      final controller = await _mapController.future;
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 15,
            tilt: 0,
            bearing: 0,
          ),
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentPosition != null
                  ? LatLng(
                      _currentPosition!.latitude,
                      _currentPosition!.longitude,
                    )
                  : _defaultTarget,
              zoom: 15,
            ),
            onMapCreated: (controller) {
              if (!_mapController.isCompleted) {
                _mapController.complete(controller);
              }
            },
            markers: {..._markers, ?_carMarker},
            polylines: _polylines,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapType: MapType.normal,
            padding: EdgeInsets.zero,
          ),
          // ── Google Maps-style instruction banner ─────────────────────────────
          if (!_selfNavigating)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // turn instruction
                    if (_isNavigating && _nextInstruction.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: _navy,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                _maneuverIcon(_nextManeuver),
                                color: Colors.white,
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _nextInstruction,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (_stepIndex + 1 < _steps.length)
                                    Text(
                                      'Then: ${_steps[_stepIndex + 1].instruction}',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.55,
                                        ),
                                        fontSize: 11,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    // destination arrival banner
                    if (_showDestArrivalBanner)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.flag_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Arrived at destination — tap Complete Trip',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () => setState(
                                () => _showDestArrivalBanner = false,
                              ),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // off-road warning banner
                    if (_showOffRoadWarning)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD32F2F),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Off route — please return to the road',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _showOffRoadWarning = false),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // ETA / distance / speed strip
                    if (_isNavigating)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _StripStat(
                              label: 'ETA',
                              value: _etaSeconds >= 3600
                                  ? '${_etaSeconds ~/ 3600}h ${(_etaSeconds % 3600) ~/ 60}m'
                                  : '${_etaSeconds ~/ 60} min',
                              color: _navy,
                            ),
                            Container(
                              width: 1,
                              height: 28,
                              color: Colors.grey.shade200,
                            ),
                            _StripStat(
                              label: 'Remaining',
                              value: _distanceKm >= 1
                                  ? '${_distanceKm.toStringAsFixed(1)} km'
                                  : '${(_distanceKm * 1000).toStringAsFixed(0)} m',
                              color: _navy,
                            ),
                            Container(
                              width: 1,
                              height: 28,
                              color: Colors.grey.shade200,
                            ),
                            _StripStat(
                              label: 'Speed',
                              value:
                                  '${_currentSpeedKmh.toStringAsFixed(0)} km/h',
                              color: _currentSpeedKmh > 80 ? Colors.red : _navy,
                            ),
                            // approaching destination chip
                            if (_tripPhase == 'in_trip' &&
                                _distanceKm > 0 &&
                                _distanceKm < 0.5) ...[
                              Container(
                                width: 1,
                                height: 28,
                                color: Colors.grey.shade200,
                              ),
                              _StripStat(
                                label: 'Arriving',
                                value: _etaSeconds < 60
                                    ? '<1 min'
                                    : '${_etaSeconds ~/ 60} min',
                                color: Colors.green,
                              ),
                            ],
                            GestureDetector(
                              onTap: _showSearchSheet,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: _navy.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.search_rounded,
                                  color: _navy,
                                  size: 18,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () => setState(
                                () => _voiceEnabled = !_voiceEnabled,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: _voiceEnabled
                                      ? Colors.green.withValues(alpha: 0.12)
                                      : _navy.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  _voiceEnabled
                                      ? Icons.volume_up_rounded
                                      : Icons.volume_off_rounded,
                                  color: _voiceEnabled
                                      ? Colors.green
                                      : _navy.withValues(alpha: 0.4),
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    // idle (no active nav)
                    if (!_isNavigating)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: _navy,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.navigation_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Navigation Assistant',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            _NavPill(
                              icon: Icons.speed_rounded,
                              value:
                                  '${_currentSpeedKmh.toStringAsFixed(0)} km/h',
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: _showSearchSheet,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.2),
                                  ),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(
                                      Icons.search_rounded,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      'Search',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () {
                                if (_currentPosition != null) {
                                  _animateToPosition(_currentPosition!);
                                }
                              },
                              child: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.my_location_rounded,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          // recenter button (always visible during navigation)
          if (_isNavigating)
            Positioned(
              bottom: 220,
              right: 16,
              child: GestureDetector(
                onTap: () {
                  if (_currentPosition != null) {
                    _mapController.future.then(
                      (c) => c.animateCamera(
                        CameraUpdate.newCameraPosition(
                          CameraPosition(
                            target: LatLng(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                            ),
                            zoom: 17.5,
                            tilt: 60,
                            bearing: _currentHeading,
                          ),
                        ),
                      ),
                    );
                  }
                },
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.navigation_rounded,
                    color: _navy,
                    size: 22,
                  ),
                ),
              ),
            ),
          // Self travel bottom card
          if (_selfNavigating)
            Positioned(
              bottom: 100,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on_rounded,
                          color: _navy,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _selectedDescription,
                            style: const TextStyle(
                              color: _navy,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _NavStat(
                            icon: Icons.straighten_rounded,
                            label: 'Distance',
                            value: _distanceKm >= 1
                                ? '${_distanceKm.toStringAsFixed(1)} km'
                                : '${(_distanceKm * 1000).toStringAsFixed(0)} m',
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 36,
                          color: _navy.withValues(alpha: 0.1),
                        ),
                        Expanded(
                          child: _NavStat(
                            icon: Icons.speed_rounded,
                            label: 'Speed',
                            value:
                                '${_currentSpeedKmh.toStringAsFixed(0)} km/h',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          _etaTimer?.cancel();
                          setState(() {
                            _selfNavigating = false;
                            _selectedDestination = null;
                            _selectedDescription = '';
                            _distanceKm = 0;
                            _nextInstruction = '';
                            _nextManeuver = '';
                            _etaSeconds = 0;
                            _steps = [];
                            _stepIndex = 0;
                            _isNavigating = false;
                            _polylines = {};
                            _searchController.clear();
                            _markers = _markers
                                .where((m) => m.markerId.value == 'driver')
                                .toSet();
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text(
                          'Cancel Navigation',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Book for customer — passenger details form
          if (_bookingForCustomer)
            Positioned(
              bottom: 100,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF2E7D32,
                            ).withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.person_add_rounded,
                            color: Color(0xFF2E7D32),
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _selectedDescription,
                            style: const TextStyle(
                              color: _navy,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: _navy, size: 18),
                          onPressed: () => setState(() {
                            _bookingForCustomer = false;
                            _passengerNameCtrl.clear();
                            _passengerPhoneCtrl.clear();
                          }),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // distance stat
                    Row(
                      children: [
                        const Icon(
                          Icons.straighten_rounded,
                          color: _navy,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _distanceKm >= 1
                              ? '${_distanceKm.toStringAsFixed(1)} km to destination'
                              : '${(_distanceKm * 1000).toStringAsFixed(0)} m to destination',
                          style: TextStyle(
                            color: _navy.withValues(alpha: 0.6),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // passenger name
                    TextField(
                      controller: _passengerNameCtrl,
                      style: const TextStyle(color: _navy, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Passenger name',
                        hintStyle: TextStyle(
                          color: _navy.withValues(alpha: 0.35),
                        ),
                        prefixIcon: const Icon(
                          Icons.person_outline,
                          color: _navy,
                          size: 18,
                        ),
                        filled: true,
                        fillColor: _navy.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // passenger phone
                    TextField(
                      controller: _passengerPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(color: _navy, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Passenger phone number',
                        hintStyle: TextStyle(
                          color: _navy.withValues(alpha: 0.35),
                        ),
                        prefixIcon: const Icon(
                          Icons.phone_outlined,
                          color: _navy,
                          size: 18,
                        ),
                        filled: true,
                        fillColor: _navy.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _bookingLoading
                            ? null
                            : () async {
                                final name = _passengerNameCtrl.text.trim();
                                final phone = _passengerPhoneCtrl.text.trim();
                                if (name.isEmpty || phone.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Enter passenger name and phone',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                setState(() => _bookingLoading = true);
                                await _bookForCustomer(
                                  _selectedDestination!,
                                  _selectedDescription,
                                  name: name,
                                  phone: phone,
                                );
                                if (mounted) {
                                  setState(() {
                                    _bookingLoading = false;
                                    _bookingForCustomer = false;
                                    _passengerNameCtrl.clear();
                                    _passengerPhoneCtrl.clear();
                                  });
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _bookingLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Book Ride',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Pending ride request card
          if (_pendingRide != null && _activeRide == null)
            Positioned(
              bottom: 100,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.schedule_rounded,
                            color: Colors.orange,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Ride Request',
                          style: TextStyle(
                            color: _navy,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Pending',
                            style: TextStyle(
                              color: Colors.orange,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // passenger info
                    _RideInfoRow(
                      icon: Icons.person_outline,
                      label: 'Passenger',
                      value: _pendingRide!['passengerName'] ?? '',
                    ),
                    const SizedBox(height: 8),
                    _CallRow(phone: _pendingRide!['passengerPhone'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                      icon: Icons.location_on_outlined,
                      label: 'Destination',
                      value: _pendingRide!['destination'] ?? '',
                    ),
                    const SizedBox(height: 16),
                    // accept / decline
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await db
                                  .collection('rides')
                                  .doc(_pendingRideId)
                                  .update({'status': 'cancelled'});
                              setState(() {
                                _pendingRide = null;
                                _pendingRideId = null;
                                _polylines = {};
                                _searchController.clear();
                                _selectedDestination = null;
                                _selectedDescription = '';
                                _markers = {};
                              });
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFD32F2F),
                              side: const BorderSide(color: Color(0xFFD32F2F)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: const Icon(Icons.close_rounded, size: 16),
                            label: const Text('Decline'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              await db
                                  .collection('rides')
                                  .doc(_pendingRideId)
                                  .update({'status': 'accepted'});
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2E7D32),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: const Icon(Icons.check_rounded, size: 16),
                            label: const Text(
                              'Accept',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          // Active ride card — en_route phase
          if (_activeRide != null && _tripPhase == 'en_route')
            Positioned(
              bottom: 100,
              right: 16,
              left: _cardMinimized ? null : 16,
              child: _cardMinimized
                  ? GestureDetector(
                      onTap: () => setState(() => _cardMinimized = false),
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: _navy,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.directions_car_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    )
                  : Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: _navy.withValues(alpha: 0.08),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.directions_car_rounded,
                                  color: _navy,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                'En Route to Pickup',
                                style: TextStyle(
                                  color: _navy,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  'Active',
                                  style: TextStyle(
                                    color: Colors.blue,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _cardMinimized = true),
                                child: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: _navy,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _RideInfoRow(
                            icon: Icons.person_outline,
                            label: 'Passenger',
                            value: _activeRide!['passengerName'] ?? '',
                          ),
                          const SizedBox(height: 8),
                          _CallRow(phone: _activeRide!['passengerPhone'] ?? ''),
                          const SizedBox(height: 8),
                          _RideInfoRow(
                            icon: Icons.straighten_rounded,
                            label: 'Distance',
                            value: _distanceKm >= 1
                                ? '${_distanceKm.toStringAsFixed(1)} km to pickup'
                                : '${(_distanceKm * 1000).toStringAsFixed(0)} m to pickup',
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                await db
                                    .collection('rides')
                                    .doc(_activeRideId)
                                    .update({'tripPhase': 'arrived'});
                                setState(() {
                                  _tripPhase = 'arrived';
                                  _cardMinimized = false;
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _navy,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                              ),
                              icon: const Icon(
                                Icons.location_on_rounded,
                                size: 18,
                              ),
                              label: const Text(
                                'Arrived at Customer',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _cancelWithFee,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFD32F2F),
                                side: const BorderSide(
                                  color: Color(0xFFD32F2F),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                              icon: const Icon(Icons.cancel_outlined, size: 16),
                              label: const Text('Cancel Ride'),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),

          // arrived phase card
          if (_activeRide != null && _tripPhase == 'arrived')
            Positioned(
              bottom: 100,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.person_pin_circle_rounded,
                            color: Colors.orange,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Arrived at Pickup',
                          style: TextStyle(
                            color: _navy,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Waiting',
                            style: TextStyle(
                              color: Colors.orange,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _RideInfoRow(
                      icon: Icons.person_outline,
                      label: 'Passenger',
                      value: _activeRide!['passengerName'] ?? '',
                    ),
                    const SizedBox(height: 8),
                    _CallRow(phone: _activeRide!['passengerPhone'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                      icon: Icons.location_on_outlined,
                      label: 'Destination',
                      value: _activeRide!['destination'] ?? '',
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          // Always get a fresh fix when starting the trip
                          Position? pos = await MapService.getCurrentPosition();
                          pos ??= _currentPosition;
                          if (pos == null || !mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Location not available. Please wait...',
                                ),
                              ),
                            );
                            return;
                          }

                          final destGeo =
                              _activeRide!['destinationLocation'] as GeoPoint?;
                          double? destLat = destGeo?.latitude;
                          double? destLng = destGeo?.longitude;

                          if (destLat == null || destLng == null) {
                            final destStr =
                                _activeRide!['destination'] as String? ?? '';
                            if (destStr.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Destination not set.'),
                                ),
                              );
                              return;
                            }
                            try {
                              final res = await http.get(
                                Uri.parse(
                                  'https://maps.googleapis.com/maps/api/geocode/json'
                                  '?address=${Uri.encodeComponent(destStr)}'
                                  '&key=$geocodingApiKey',
                                ),
                              );
                              final data = jsonDecode(res.body);
                              final loc =
                                  data['results']?[0]?['geometry']?['location'];
                              if (loc == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Could not find destination location.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              destLat = (loc['lat'] as num).toDouble();
                              destLng = (loc['lng'] as num).toDouble();
                            } catch (e) {
                              return;
                            }
                          }

                          final dest = LatLng(destLat, destLng);
                          final origin = LatLng(pos.latitude, pos.longitude);

                          setState(() {
                            _currentPosition = pos;
                            _tripPhase = 'in_trip';
                            _tripDistanceKm = 0;
                            _lastTripPosition =
                                null; // set on first GPS update to avoid false jump
                            _steps = [];
                            _stepIndex = 0;
                            _isNavigating = false;
                            _lastGoodPolyline = [];
                            _arrivedAtDest = false;
                            _showDestArrivalBanner = false;
                          });
                          MapService.resetSmoothing();
                          // keep device awake for trip duration
                          try {
                            enableWakelock();
                            debugPrint('[Wakelock] enabled (trip started)');
                          } catch (_) {}
                          _speak('Trip started. Navigating to destination.');
                          _startTracking(continuous: true);
                          await db
                              .collection('rides')
                              .doc(_activeRideId)
                              .update({
                                'status': 'in_trip',
                                'tripPhase': 'in_trip',
                                'tripDistanceKm': 0,
                              });
                          await _drawRoute(origin, dest);
                          _startRouteRefreshTimer();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.navigation_rounded, size: 18),
                        label: const Text(
                          'Start Trip',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _cancelWithFee,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFD32F2F),
                          side: const BorderSide(color: Color(0xFFD32F2F)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.cancel_outlined, size: 16),
                        label: const Text('Cancel Ride'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // in_trip phase card
          if (_activeRide != null && _tripPhase == 'in_trip')
            Positioned(
              bottom: 100,
              right: 16,
              left: _cardMinimized ? null : 16,
              child: _cardMinimized
                  ? GestureDetector(
                      onTap: () => setState(() => _cardMinimized = false),
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.navigation_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                            Text(
                              _tripDistanceKm <= _shortDistanceThresholdKm
                                  ? '${(_shortDistanceFee / 1000).toStringAsFixed(0)}K'
                                  : '${((_baseFee + _tripDistanceKm * _pricePerKm) / 1000).toStringAsFixed(0)}K',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.navigation_rounded,
                                  color: Colors.green,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                'Trip in Progress',
                                style: TextStyle(
                                  color: _navy,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  'On Trip',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _cardMinimized = true),
                                child: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: _navy,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _RideInfoRow(
                            icon: Icons.person_outline,
                            label: 'Passenger',
                            value: _activeRide!['passengerName'] ?? '',
                          ),
                          const SizedBox(height: 8),
                          _RideInfoRow(
                            icon: Icons.location_on_outlined,
                            label: 'Destination',
                            value: _activeRide!['destination'] ?? '',
                          ),
                          const SizedBox(height: 8),
                          _RideInfoRow(
                            icon: Icons.straighten_rounded,
                            label: 'Distance',
                            value: _distanceKm >= 1
                                ? '${_distanceKm.toStringAsFixed(1)} km remaining'
                                : '${(_distanceKm * 1000).toStringAsFixed(0)} m remaining',
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: Colors.green.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.payments_rounded,
                                  color: Colors.green,
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Live Fare: ',
                                  style: TextStyle(
                                    color: _navy.withValues(alpha: 0.6),
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  _tripDistanceKm <= _shortDistanceThresholdKm
                                      ? 'MWK ${_shortDistanceFee.toStringAsFixed(0)} (flat)'
                                      : 'MWK ${(_baseFee + _tripDistanceKm * _pricePerKm).toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${_tripDistanceKm.toStringAsFixed(2)} km',
                                  style: TextStyle(
                                    color: _navy.withValues(alpha: 0.5),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _completing
                                  ? null
                                  : () async {
                                      if (_completing) return;
                                      setState(() => _completing = true);
                                      final rideId = _activeRideId;
                                      final ride = Map<String, dynamic>.from(
                                        _activeRide ?? {},
                                      );
                                      final dist = _tripDistanceKm;
                                      final fare =
                                          dist <= _shortDistanceThresholdKm
                                          ? _shortDistanceFee
                                          : _baseFee + dist * _pricePerKm;

                                      final uid = FirebaseAuth
                                          .instance
                                          .currentUser
                                          ?.uid;
                                      // subscriptionFee shown in the completion sheet only
                                      // (actual balance write is done by onRideCompleted CF)
                                      double subscriptionRate =
                                          _subscriptionRate;
                                      try {
                                        final fareDoc = await db
                                            .collection('settings')
                                            .doc('fare')
                                            .get();
                                        subscriptionRate =
                                            (fareDoc.data()?['subscriptionRate']
                                                    as num?)
                                                ?.toDouble() ??
                                            _subscriptionRate;
                                      } catch (_) {}

                                      final subscriptionFee =
                                          fare * (subscriptionRate / 100);
                                      debugPrint(
                                        '[COMPLETE] dist=${dist.toStringAsFixed(3)}km fare=${fare.toStringAsFixed(0)} subRate=$subscriptionRate% subFee=${subscriptionFee.toStringAsFixed(0)}',
                                      );

                                      if (rideId != null) {
                                        await db
                                            .collection('rides')
                                            .doc(rideId)
                                            .update({
                                              'status': 'completed',
                                              'finalFare': fare,
                                              'distanceKm': dist,
                                              'tripDistanceKm': dist,
                                              'subscriptionFeeCharged':
                                                  subscriptionFee,
                                            });
                                      }

                                      // subscriptionBalance is incremented by the
                                      // onRideCompleted Cloud Function — do NOT also
                                      // increment here or the fee doubles.
                                      if (uid != null) {
                                        try {
                                          await db
                                              .collection('drivers')
                                              .doc(uid)
                                              .update({
                                                'subscriptionKm':
                                                    FieldValue.increment(dist),
                                                'subscriptionBalance':
                                                    FieldValue.increment(
                                                      subscriptionFee,
                                                    ),
                                              });
                                        } catch (_) {}
                                      }

                                      _resetTripState();
                                      if (mounted)
                                        setState(() => _completing = false);
                                      _speak(
                                        'Trip completed. Please collect payment.',
                                      );
                                      if (mounted) {
                                        _showCompletionSheet(
                                          ride,
                                          dist,
                                          fare,
                                          subscriptionFee,
                                        );
                                      }
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                              ),
                              icon: const Icon(Icons.flag_rounded, size: 18),
                              label: const Text(
                                'Complete Trip',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

class _CallRow extends StatelessWidget {
  final String phone;
  const _CallRow({required this.phone});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.phone_outlined,
          color: _navy.withValues(alpha: 0.5),
          size: 16,
        ),
        const SizedBox(width: 8),
        Text(
          'Phone: ',
          style: TextStyle(color: _navy.withValues(alpha: 0.5), fontSize: 12),
        ),
        Expanded(
          child: Text(
            phone.isNotEmpty ? phone : '—',
            style: const TextStyle(
              color: _navy,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (phone.isNotEmpty)
          GestureDetector(
            onTap: () => launchUrl(Uri.parse('tel:$phone')),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.phone_rounded,
                color: Colors.green,
                size: 16,
              ),
            ),
          ),
      ],
    );
  }
}

class _StripStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StripStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        Text(
          label,
          style: TextStyle(color: color.withValues(alpha: 0.5), fontSize: 10),
        ),
      ],
    );
  }
}

class _NavPill extends StatelessWidget {
  final IconData icon;
  final String value;
  const _NavPill({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 5),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _OptionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color.withValues(alpha: 0.6),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _NavStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: _navy, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: _navy,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        Text(
          label,
          style: TextStyle(color: _navy.withValues(alpha: 0.5), fontSize: 11),
        ),
      ],
    );
  }
}

class _RideInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _RideInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: _navy.withValues(alpha: 0.5), size: 16),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(color: _navy.withValues(alpha: 0.5), fontSize: 12),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: _navy,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
