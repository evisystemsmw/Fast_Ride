import 'dart:async';
import 'dart:convert';
import 'dart:math' show cos, sin, sqrt, atan2, pi;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'map_service.dart';
import 'db.dart';

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
  final s = sin(dLat / 2) * sin(dLat / 2) +
      cos(a.latitude * pi / 180) * cos(b.latitude * pi / 180) *
          sin(dLng / 2) * sin(dLng / 2);
  return r * 2 * atan2(sqrt(s), sqrt(1 - s));
}

class DriverNavigationScreen extends StatefulWidget {
  final VoidCallback? onRideAccepted;
  const DriverNavigationScreen({super.key, this.onRideAccepted});

  @override
  State<DriverNavigationScreen> createState() => _DriverNavigationScreenState();
}

class _DriverNavigationScreenState extends State<DriverNavigationScreen> {
  final Completer<GoogleMapController> _mapController = Completer();

  Position? _currentPosition;
  StreamSubscription<Position>? _locationSub;
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
  bool _isNavigating = false; // true when a route is active
  double _currentSpeedKmh = 0;
  double _currentHeading = 0;
  double _cardOffset = 0;
  bool _cardMinimized = false;
  // fare config
  double _baseFee = 2500;
  double _pricePerKm = 2500;
  double _shortDistanceFee = 10000;
  double _shortDistanceThresholdKm = 2.8;
  // in_trip tracking
  double _tripDistanceKm = 0;
  Position? _lastTripPosition;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _etaTimer?.cancel();
    _searchController.dispose();
    _passengerNameCtrl.dispose();
    _passengerPhoneCtrl.dispose();
    MapService.resetSmoothing();
    if (_mapController.isCompleted) {
      _mapController.future.then((c) => c.dispose()).catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _init() async {
    _listenActiveRide();
    _loadFareConfig();
    final position = await MapService.getCurrentPosition();
    if (position != null && mounted) {
      setState(() => _currentPosition = position);
      _startTracking();
      _animateToPosition(position);
      // If a ride was already loaded before position was available, draw its route now
      if (_activeRide != null) {
        _drawRouteForPhase(position);
      }
    }
  }

  void _drawRouteForPhase(Position position) {
    if (_activeRide == null) return;
    final origin = LatLng(position.latitude, position.longitude);
    if (_tripPhase == 'in_trip') {
      final destLat = (_activeRide!['destinationLat'] as num?)?.toDouble();
      final destLng = (_activeRide!['destinationLng'] as num?)?.toDouble();
      if (destLat != null && destLng != null) {
        _drawRoute(origin, LatLng(destLat, destLng));
      } else {
        // geocode from string
        final destStr = _activeRide!['destination'] as String? ?? '';
        if (destStr.isNotEmpty) {
          http.get(Uri.parse(
            'https://maps.googleapis.com/maps/api/geocode/json'
            '?address=${Uri.encodeComponent(destStr)}'
            '&key=$geocodingApiKey',
          )).then((res) {
            final data = jsonDecode(res.body);
            final loc = data['results']?[0]?['geometry']?['location'];
            if (loc != null) {
              _drawRoute(origin, LatLng(
                (loc['lat'] as num).toDouble(),
                (loc['lng'] as num).toDouble(),
              ));
            }
          }).catchError((_) {});
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
      if (mounted) setState(() {
        _baseFee = (data['baseFee'] as num?)?.toDouble() ?? 2500;
        _pricePerKm = (data['pricePerKm'] as num?)?.toDouble() ?? 2500;
        _shortDistanceFee = (data['shortDistanceFee'] as num?)?.toDouble() ?? 10000;
        _shortDistanceThresholdKm = (data['shortDistanceThresholdKm'] as num?)?.toDouble() ?? 2.8;
      });
    } catch (_) {}
  }

  void _startTracking() {
    _locationSub = MapService.trackLocation().listen((position) async {
      if (!mounted) return;
      final latLng = LatLng(position.latitude, position.longitude);
      final heading = position.heading >= 0 ? position.heading : _currentHeading;
      setState(() {
        _currentPosition = position;
        _currentSpeedKmh = (position.speed * 3.6).clamp(0, 300);
        _currentHeading = heading;
        _lastDriverLatLng = latLng;
        _markers = {
          ..._markers.where((m) => m.markerId.value != 'driver'),
          Marker(
            markerId: const MarkerId('driver'),
            position: latLng,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
            anchor: const Offset(0.5, 0.5),
            rotation: heading,
            flat: true,
            infoWindow: const InfoWindow(title: 'You'),
          ),
        };
      });
      await MapService.updateDriverLocation(position);

      // accumulate distance during in_trip
      if (_tripPhase == 'in_trip' && _lastTripPosition != null) {
        final delta = MapService.distanceKm(
          _lastTripPosition!.latitude, _lastTripPosition!.longitude,
          position.latitude, position.longitude,
        );
        // only count if moved more than 10 meters and speed > 2 km/h
        if (delta * 1000 > 10 && (position.speed * 3.6) > 2) {
          setState(() => _tripDistanceKm += delta);
          if (_activeRideId != null) {
            db.collection('rides').doc(_activeRideId).update({'tripDistanceKm': _tripDistanceKm});
          }
        }
      }
      if (_tripPhase == 'in_trip') _lastTripPosition = position;

      // ── Google Maps-style camera: tilt + heading ───────────────────────────────
      if (_isNavigating && _mapController.isCompleted) {
        try {
          final c = await _mapController.future;
          await c.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(
            target: latLng,
            zoom: 17.5,
            tilt: 60,
            bearing: heading,
          )));
        } catch (_) {}
      }
      // do NOT call _animateToPosition during active navigation

      // ── advance steps ───────────────────────────────────────────────────
      if (_isNavigating && _steps.isNotEmpty && _stepIndex < _steps.length) {
        final step = _steps[_stepIndex];
        final distToStep = _distMBetween(latLng, step.endLocation);
        if (distToStep < 30) {
          // reached this step's end — advance
          if (_stepIndex + 1 < _steps.length) {
            setState(() {
              _stepIndex++;
              _nextInstruction = _steps[_stepIndex].instruction;
              _nextManeuver = _steps[_stepIndex].maneuver;
            });
          }
        }
        // always update remaining distance from current position
        double rem = distToStep;
        for (int i = _stepIndex + 1; i < _steps.length; i++) {
          rem += _steps[i].distanceM;
        }
        if (mounted) setState(() => _distanceKm = rem / 1000);

        // reroute only if significantly off route and moving
        if (distToStep > 200 && _currentSpeedKmh > 5) {
          _drawRouteForPhase(position);
        }
      } else if (_isNavigating && _steps.isEmpty && _currentPosition != null) {
        // steps not loaded yet — redraw route
        _drawRouteForPhase(position);
      }
    });
  }

  void _listenActiveRide() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // listen for requested (pending) rides booked by this driver
    db.collection('rides')
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
    db.collection('rides')
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
        final savedDistanceKm = (data['tripDistanceKm'] as num?)?.toDouble() ?? 0;
        setState(() {
          _activeRide = data;
          _activeRideId = doc.id;
          // Never let Firestore snapshots overwrite a locally-driven phase
          // Only set phase from Firestore on first load
          if (wasNull) {
            _tripPhase = savedPhase ?? 'en_route';
            _tripDistanceKm = savedDistanceKm;
            _lastTripPosition = _currentPosition;
          }
        });
        if (wasNull) {
          if (_tripPhase != 'in_trip') widget.onRideAccepted?.call();
          _addRideMarkers(data);
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
          _markers = _markers.where((m) => m.markerId.value == 'driver').toSet();
          _polylines = {};
        });
      }
    });
  }

  void _addRideMarkers(Map<String, dynamic> ride) {
    final pickupGeo = ride['pickupLocation'] as GeoPoint?;
    final destLat = (ride['destinationLat'] as num?)?.toDouble();
    final destLng = (ride['destinationLng'] as num?)?.toDouble();

    final newMarkers = <Marker>{
      ..._markers.where((m) => m.markerId.value == 'driver'),
    };

    if (pickupGeo != null) {
      newMarkers.add(Marker(
        markerId: const MarkerId('pickup'),
        position: LatLng(pickupGeo.latitude, pickupGeo.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: 'Pickup: ${ride['pickup'] ?? ''}'),
      ));
    }

    if (destLat != null && destLng != null) {
      newMarkers.add(Marker(
        markerId: const MarkerId('destination'),
        position: LatLng(destLat, destLng),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: 'Destination: ${ride['destination'] ?? ''}'),
      ));
    }

    setState(() => _markers = newMarkers);
  }

  Future<void> _drawRoute(LatLng origin, LatLng destination) async {
    try {
      print('🛣️ _drawRoute called: $origin -> $destination');
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&mode=driving'
        '&key=$googleMapsApiKey',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 10));
      print('🛣️ Directions API status: ${res.statusCode}');
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body);
      print('🛣️ Routes count: ${(data["routes"] as List).length}');
      print('🛣️ API status field: ${data["status"]}');
      if ((data['routes'] as List).isEmpty) return;

      final leg = data['routes'][0]['legs'][0];
      final distanceM = (leg['distance']['value'] as num).toDouble();
      final durationS = (leg['duration']['value'] as num).toInt();

      final stepsList = (leg['steps'] as List).map((s) {
        final eLoc = s['end_location'];
        return _NavStep(
          endLocation: LatLng(eLoc['lat'], eLoc['lng']),
          distanceM: (s['distance']['value'] as num).toDouble(),
          instruction: (s['html_instructions'] as String).replaceAll(RegExp(r'<[^>]*>'), ''),
          maneuver: s['maneuver'] ?? '',
        );
      }).toList();

      final points = data['routes'][0]['overview_polyline']['points'] as String;
      final decoded = _decodePolyline(points);

      if (mounted) {
        setState(() {
          _distanceKm = distanceM / 1000;
          _etaSeconds = durationS;
          _steps = stepsList;
          _stepIndex = 0;
          _nextInstruction = stepsList.isNotEmpty ? stepsList.first.instruction : '';
          _nextManeuver = stepsList.isNotEmpty ? stepsList.first.maneuver : '';
          _isNavigating = true;
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
          if (_etaSeconds > 0 && mounted) setState(() => _etaSeconds--);
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Route error: $e')),
        );
      }
    }
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
    final url = Uri.parse('https://places.googleapis.com/v1/places:autocomplete');
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
            .map((s) => {
                  'placeId': s['placePrediction']['placeId'] as String,
                  'description': s['placePrediction']['text']['text'] as String,
                })
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
        ..._markers.where((m) => m.markerId.value != 'search'),
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

  void _showTravelOptions(LatLng destination, String description) {
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
                        color: _navy, fontWeight: FontWeight.bold, fontSize: 14),
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
    );
  }

  Future<void> _bookForCustomer(LatLng destination, String description,
      {required String name, required String phone}) async {
    if (_currentPosition == null) return;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    await db.collection('rides').add({
      'status': 'requested',
      'driverId': uid,
      'destination': description,
      'destinationLocation': GeoPoint(destination.latitude, destination.longitude),
      'pickup': 'Driver current location',
      'pickupLocation': GeoPoint(_currentPosition!.latitude, _currentPosition!.longitude),
      'passengerName': name,
      'passengerPhone': phone,
      'passengerId': '',
      'bookedByDriver': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  void _resetTripState() {
    _etaTimer?.cancel();
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
      _markers = _markers.where((m) => m.markerId.value == 'driver').toSet();
    });
  }

  void _showCompletionSheet(Map<String, dynamic> ride, double distKm, double fare, double subscriptionFee) {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).padding.bottom + 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 48),
            ),
            const SizedBox(height: 12),
            const Text('Trip Completed!',
                style: TextStyle(color: _navy, fontWeight: FontWeight.bold, fontSize: 20)),
            const SizedBox(height: 4),
            Text('Please collect payment from passenger',
                style: TextStyle(color: _navy.withValues(alpha: 0.5), fontSize: 13)),
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
                  Text('Amount to Collect',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13)),
                  const SizedBox(height: 8),
                  Text(
                    distKm <= _shortDistanceThresholdKm
                        ? 'MWK ${_shortDistanceFee.toStringAsFixed(0)}'
                        : 'MWK ${fare.toStringAsFixed(0)}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 36),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    distKm <= _shortDistanceThresholdKm ? 'Flat rate' : '${distKm.toStringAsFixed(2)} km',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
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
                  Text('Subscription fee',
                      style: TextStyle(color: _navy.withValues(alpha: 0.6), fontSize: 13)),
                  const Spacer(),
                  Text('MWK ${subscriptionFee.toStringAsFixed(0)}',
                      style: const TextStyle(color: _navy, fontWeight: FontWeight.bold, fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _RideInfoRow(icon: Icons.person_outline, label: 'Passenger', value: ride['passengerName'] ?? ''),
            const SizedBox(height: 8),
            _RideInfoRow(icon: Icons.location_on_outlined, label: 'Destination', value: ride['destination'] ?? ''),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: const Icon(Icons.payments_rounded, size: 20),
                label: const Text('Payment Received', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
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
                      setModalState(() {});
                    },
                    style: const TextStyle(color: _navy, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search location in Malawi...',
                      hintStyle: TextStyle(color: _navy.withValues(alpha: 0.4)),
                      prefixIcon: const Icon(Icons.search_rounded, color: _navy),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: _navy)),
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_suggestions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _suggestions.length > 5 ? 5 : _suggestions.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: _navy.withValues(alpha: 0.08)),
                    itemBuilder: (_, i) {
                      final s = _suggestions[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.location_on_outlined, color: _navy, size: 18),
                        title: Text(s['description'], style: const TextStyle(color: _navy, fontSize: 13)),
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
        ),
      ),
    );
  }

  Future<void> _animateToPosition(Position position) async {
    if (!_mapController.isCompleted) return;
    try {
      final controller = await _mapController.future;
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(
          target: LatLng(position.latitude, position.longitude),
          zoom: 15,
          tilt: 0,
          bearing: 0,
        )),
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
                  ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
                  : _defaultTarget,
              zoom: 15,
            ),
            onMapCreated: (controller) {
              if (!_mapController.isCompleted) {
                _mapController.complete(controller);
              }
            },
            markers: _markers,
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
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: _navy,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 4)),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(_maneuverIcon(_nextManeuver), color: Colors.white, size: 26),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _nextInstruction,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (_stepIndex + 1 < _steps.length)
                                    Text(
                                      'Then: ${_steps[_stepIndex + 1].instruction}',
                                      style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 11),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    // ETA / distance / speed strip
                    if (_isNavigating)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 6, offset: const Offset(0, 2)),
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
                            Container(width: 1, height: 28, color: Colors.grey.shade200),
                            _StripStat(
                              label: 'Remaining',
                              value: _distanceKm >= 1
                                  ? '${_distanceKm.toStringAsFixed(1)} km'
                                  : '${(_distanceKm * 1000).toStringAsFixed(0)} m',
                              color: _navy,
                            ),
                            Container(width: 1, height: 28, color: Colors.grey.shade200),
                            _StripStat(
                              label: 'Speed',
                              value: '${_currentSpeedKmh.toStringAsFixed(0)} km/h',
                              color: _currentSpeedKmh > 80 ? Colors.red : _navy,
                            ),
                            GestureDetector(
                              onTap: _showSearchSheet,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _navy.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(Icons.search_rounded, color: _navy, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                    // idle (no active nav)
                    if (!_isNavigating)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: _navy,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(0, 3)),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.navigation_rounded, color: Colors.white, size: 20),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text('Navigation Assistant',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                            ),
                            _NavPill(icon: Icons.speed_rounded, value: '${_currentSpeedKmh.toStringAsFixed(0)} km/h'),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: _showSearchSheet,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.search_rounded, color: Colors.white, size: 16),
                                    SizedBox(width: 4),
                                    Text('Search', style: TextStyle(color: Colors.white, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () { if (_currentPosition != null) _animateToPosition(_currentPosition!); },
                              child: Container(
                                width: 34, height: 34,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.my_location_rounded, color: Colors.white, size: 18),
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
                onTap: () { if (_currentPosition != null) {
                  _mapController.future.then((c) => c.animateCamera(
                    CameraUpdate.newCameraPosition(CameraPosition(
                      target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                      zoom: 17.5, tilt: 60, bearing: _currentHeading,
                    )),
                  ));
                }},
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 6, offset: const Offset(0, 2))],
                  ),
                  child: const Icon(Icons.navigation_rounded, color: _navy, size: 22),
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
                        const Icon(Icons.location_on_rounded, color: _navy, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _selectedDescription,
                            style: const TextStyle(
                                color: _navy,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
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
                        Container(width: 1, height: 36, color: _navy.withValues(alpha: 0.1)),
                        Expanded(
                          child: _NavStat(
                            icon: Icons.speed_rounded,
                            label: 'Speed',
                            value: '${_currentSpeedKmh.toStringAsFixed(0)} km/h',
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
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text('Cancel Navigation',
                            style: TextStyle(fontWeight: FontWeight.bold)),
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
                            color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.person_add_rounded,
                              color: Color(0xFF2E7D32), size: 16),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _selectedDescription,
                            style: const TextStyle(
                                color: _navy,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
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
                        const Icon(Icons.straighten_rounded, color: _navy, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          _distanceKm >= 1
                              ? '${_distanceKm.toStringAsFixed(1)} km to destination'
                              : '${(_distanceKm * 1000).toStringAsFixed(0)} m to destination',
                          style: TextStyle(
                              color: _navy.withValues(alpha: 0.6), fontSize: 12),
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
                        hintStyle: TextStyle(color: _navy.withValues(alpha: 0.35)),
                        prefixIcon: const Icon(Icons.person_outline, color: _navy, size: 18),
                        filled: true,
                        fillColor: _navy.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
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
                        hintStyle: TextStyle(color: _navy.withValues(alpha: 0.35)),
                        prefixIcon: const Icon(Icons.phone_outlined, color: _navy, size: 18),
                        filled: true,
                        fillColor: _navy.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
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
                                        content: Text('Enter passenger name and phone')),
                                  );
                                  return;
                                }
                                setState(() => _bookingLoading = true);
                                await _bookForCustomer(
                                    _selectedDestination!, _selectedDescription,
                                    name: name, phone: phone);
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
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _bookingLoading
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Book Ride',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
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
                          child: const Icon(Icons.schedule_rounded,
                              color: Colors.orange, size: 18),
                        ),
                        const SizedBox(width: 10),
                        const Text('Ride Request',
                            style: TextStyle(
                                color: _navy,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('Pending',
                              style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // passenger info
                    _RideInfoRow(
                        icon: Icons.person_outline,
                        label: 'Passenger',
                        value: _pendingRide!['passengerName'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                        icon: Icons.phone_outlined,
                        label: 'Phone',
                        value: _pendingRide!['passengerPhone'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                        icon: Icons.location_on_outlined,
                        label: 'Destination',
                        value: _pendingRide!['destination'] ?? ''),
                    const SizedBox(height: 16),
                    // accept / decline
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await db.collection('rides')
                                  .doc(_pendingRideId)
                                  .update({'status': 'cancelled'});
                              setState(() {
                                _pendingRide = null;
                                _pendingRideId = null;
                                _polylines = {};
                                _searchController.clear();
                                _selectedDestination = null;
                                _selectedDescription = '';
                                _markers = _markers
                                    .where((m) => m.markerId.value == 'driver')
                                    .toSet();
                              });
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFD32F2F),
                              side: const BorderSide(color: Color(0xFFD32F2F)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
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
                              await db.collection('rides')
                                  .doc(_pendingRideId)
                                  .update({'status': 'accepted'});
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2E7D32),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: const Icon(Icons.check_rounded, size: 16),
                            label: const Text('Accept',
                                style: TextStyle(fontWeight: FontWeight.bold)),
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
                            color: _navy.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.directions_car_rounded,
                              color: _navy, size: 18),
                        ),
                        const SizedBox(width: 10),
                        const Text('En Route to Pickup',
                            style: TextStyle(
                                color: _navy,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('Active',
                              style: TextStyle(
                                  color: Colors.blue,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _RideInfoRow(
                        icon: Icons.person_outline,
                        label: 'Passenger',
                        value: _activeRide!['passengerName'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                        icon: Icons.phone_outlined,
                        label: 'Phone',
                        value: _activeRide!['passengerPhone'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                        icon: Icons.straighten_rounded,
                        label: 'Distance',
                        value: _distanceKm >= 1
                            ? '${_distanceKm.toStringAsFixed(1)} km to pickup'
                            : '${(_distanceKm * 1000).toStringAsFixed(0)} m to pickup'),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          await db.collection('rides').doc(_activeRideId).update({
                            'tripPhase': 'arrived',
                          });
                          setState(() => _tripPhase = 'arrived');
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _navy,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.location_on_rounded, size: 18),
                        label: const Text('Arrived at Customer',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // in_trip phase card
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
                          child: const Icon(Icons.person_pin_circle_rounded,
                              color: Colors.orange, size: 18),
                        ),
                        const SizedBox(width: 10),
                        const Text('Arrived at Pickup',
                            style: TextStyle(
                                color: _navy,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('Waiting',
                              style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _RideInfoRow(
                        icon: Icons.person_outline,
                        label: 'Passenger',
                        value: _activeRide!['passengerName'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                        icon: Icons.location_on_outlined,
                        label: 'Destination',
                        value: _activeRide!['destination'] ?? ''),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          print('🚀 Start Trip tapped');
                          print('📦 Active ride keys: ${_activeRide!.keys.toList()}');

                          Position? pos = _currentPosition ?? await MapService.getCurrentPosition();
                          if (pos == null || !mounted) {
                            print('❌ Position is null');
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Location not available. Please wait...')),
                            );
                            return;
                          }

                          // try lat/lng fields first, else geocode destination string
                          double? destLat = (_activeRide!['destinationLat'] as num?)?.toDouble();
                          double? destLng = (_activeRide!['destinationLng'] as num?)?.toDouble();

                          if (destLat == null || destLng == null) {
                            final destStr = _activeRide!['destination'] as String? ?? '';
                            print('📍 Geocoding destination: $destStr');
                            if (destStr.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Destination not set.')),
                              );
                              return;
                            }
                            try {
                              final res = await http.get(Uri.parse(
                                'https://maps.googleapis.com/maps/api/geocode/json'
                                '?address=${Uri.encodeComponent(destStr)}'
                                '&key=$geocodingApiKey',
                              ));
                              final data = jsonDecode(res.body);
                              final loc = data['results']?[0]?['geometry']?['location'];
                              print('📍 Geocode result: $loc');
                              if (loc == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Could not find destination location.')),
                                );
                                return;
                              }
                              destLat = (loc['lat'] as num).toDouble();
                              destLng = (loc['lng'] as num).toDouble();
                            } catch (e) {
                              print('❌ Geocode error: $e');
                              return;
                            }
                          }

                          final dest = LatLng(destLat!, destLng!);
                          final origin = LatLng(pos.latitude, pos.longitude);
                          print('🗺️ Drawing route from $origin to $dest');

                          setState(() {
                            _currentPosition = pos;
                            _tripPhase = 'in_trip';
                            _tripDistanceKm = 0;
                            _lastTripPosition = pos;
                            _steps = [];
                            _stepIndex = 0;
                            _isNavigating = false;
                          });
                          await db.collection('rides').doc(_activeRideId).update({
                            'status': 'in_trip',
                            'tripPhase': 'in_trip',
                            'tripDistanceKm': 0,
                          });
                          await _drawRoute(origin, dest);
                          print('✅ Route drawn. Steps: ${_steps.length}, distance: $_distanceKm km');
                          if (_steps.isEmpty && mounted) {
                            print('⚠️ Steps empty, retrying...');
                            await _drawRoute(origin, dest);
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.navigation_rounded, size: 18),
                        label: const Text('Start Trip',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
                            BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(0, 3)),
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.navigation_rounded, color: Colors.white, size: 18),
                            Text(
                              _tripDistanceKm <= _shortDistanceThresholdKm
                                  ? '${(_shortDistanceFee / 1000).toStringAsFixed(0)}K'
                                  : '${((_baseFee + _tripDistanceKm * _pricePerKm) / 1000).toStringAsFixed(0)}K',
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
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
                                child: const Icon(Icons.navigation_rounded, color: Colors.green, size: 18),
                              ),
                              const SizedBox(width: 10),
                              const Text('Trip in Progress',
                                  style: TextStyle(color: _navy, fontWeight: FontWeight.bold, fontSize: 15)),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text('On Trip',
                                    style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => setState(() => _cardMinimized = true),
                                child: const Icon(Icons.keyboard_arrow_down_rounded, color: _navy, size: 22),
                              ),
                            ],
                          ),
                    const SizedBox(height: 14),
                    _RideInfoRow(
                        icon: Icons.person_outline,
                        label: 'Passenger',
                        value: _activeRide!['passengerName'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                        icon: Icons.location_on_outlined,
                        label: 'Destination',
                        value: _activeRide!['destination'] ?? ''),
                    const SizedBox(height: 8),
                    _RideInfoRow(
                        icon: Icons.straighten_rounded,
                        label: 'Distance',
                        value: _distanceKm >= 1
                            ? '${_distanceKm.toStringAsFixed(1)} km remaining'
                            : '${(_distanceKm * 1000).toStringAsFixed(0)} m remaining'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.payments_rounded, color: Colors.green, size: 16),
                          const SizedBox(width: 8),
                          Text('Live Fare: ',
                              style: TextStyle(color: _navy.withValues(alpha: 0.6), fontSize: 12)),
                          Text(
                            _tripDistanceKm <= _shortDistanceThresholdKm
                                ? 'MWK ${_shortDistanceFee.toStringAsFixed(0)} (flat)'
                                : 'MWK ${(_baseFee + _tripDistanceKm * _pricePerKm).toStringAsFixed(0)}',
                            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const Spacer(),
                          Text('${_tripDistanceKm.toStringAsFixed(2)} km',
                              style: TextStyle(color: _navy.withValues(alpha: 0.5), fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final rideId = _activeRideId;
                          final ride = Map<String, dynamic>.from(_activeRide ?? {});
                          final dist = _tripDistanceKm;
                          final fare = dist <= _shortDistanceThresholdKm
                              ? _shortDistanceFee
                              : _baseFee + dist * _pricePerKm;

                          final uid = FirebaseAuth.instance.currentUser?.uid;
                          double subscriptionRateKm = 0;
                          double currentKm = 0;
                          double currentBalance = 0;

                          if (uid != null) {
                            try {
                              final results = await Future.wait([
                                db.collection('drivers').doc(uid).get(),
                                db.collection('settings').doc('fares').get(),
                              ]);
                              final driverData = results[0].data() as Map<String, dynamic>? ?? {};
                              final faresData = results[1].data() as Map<String, dynamic>? ?? {};
                              currentKm = (driverData['subscriptionKm'] as num?)?.toDouble() ?? 0;
                              currentBalance = (driverData['subscriptionBalance'] as num?)?.toDouble() ?? 0;
                              subscriptionRateKm = (faresData['fares'] as num?)?.toDouble() ?? 0;
                            } catch (e) {
                              print('❌ Driver/fares fetch error: $e');
                            }
                          }

                          // subscriptionFee = fare * (subscriptionRateKm / pricePerKm)
                          final subscriptionFee = _pricePerKm > 0
                              ? fare * (subscriptionRateKm / _pricePerKm)
                              : 0.0;

                          if (rideId != null) {
                            await db.collection('rides').doc(rideId).update({
                              'status': 'completed',
                              'finalFare': fare,
                              'tripDistanceKm': dist,
                              'subscriptionFeeCharged': subscriptionFee,
                              'subscriptionRatePerKm': subscriptionRateKm,
                              'pricePerKm': _pricePerKm,
                            });
                          }

                          if (uid != null) {
                            try {
                              await db.collection('drivers').doc(uid).update({
                                'subscriptionKm': currentKm + dist,
                                'subscriptionBalance': currentBalance + subscriptionFee,
                              });
                            } catch (e) {
                              print('❌ Subscription update error: $e');
                            }
                          }

                          _resetTripState();
                          if (mounted) _showCompletionSheet(ride, dist, fare, subscriptionFee);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.flag_rounded, size: 18),
                        label: const Text('Complete Trip',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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

class _StripStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StripStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
        Text(label, style: TextStyle(color: color.withValues(alpha: 0.5), fontSize: 10)),
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
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
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
            Text(label,
                style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            const SizedBox(height: 2),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: color.withValues(alpha: 0.6),
                    fontSize: 11)),
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

  const _NavStat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: _navy, size: 20),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                color: _navy, fontWeight: FontWeight.bold, fontSize: 15)),
        Text(label,
            style: TextStyle(
                color: _navy.withValues(alpha: 0.5), fontSize: 11)),
      ],
    );
  }
}

class _RideInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _RideInfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: _navy.withValues(alpha: 0.5), size: 16),
        const SizedBox(width: 8),
        Text('$label: ',
            style: TextStyle(color: _navy.withValues(alpha: 0.5), fontSize: 12)),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  color: _navy, fontWeight: FontWeight.w600, fontSize: 13),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
