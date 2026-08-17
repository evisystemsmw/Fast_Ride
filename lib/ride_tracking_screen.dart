import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'db.dart';
import 'map_service.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class RideTrackingScreen extends StatefulWidget {
  final String rideId;
  final String pickup;
  final String destination;

  const RideTrackingScreen({
    super.key,
    required this.rideId,
    this.pickup = '',
    this.destination = '',
  });

  @override
  State<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends State<RideTrackingScreen> {
  GoogleMapController? _mapCtrl;
  static const _defaultTarget = LatLng(-13.9626, 33.7741);

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  StreamSubscription? _rideSub;
  StreamSubscription? _driversSub;

  Map<String, dynamic>? _rideData;
  String _rideStatus = 'requested';
  String _tripPhase = '';
  double _estimatedFare = 0;
  double _distanceKm = 0;
  String? _driverId;
  List<LatLng> _lastGoodLivePolyline = [];
  bool _liveRouteDrawing = false;

  // fare config
  double _baseFee = 2500;
  double _pricePerKm = 2500;
  double _shortDistanceFee = 10000;
  double _shortDistanceThresholdKm = 2.8;

  @override
  void initState() {
    super.initState();
    _loadFareConfig();
    _listenRide();
  }

  @override
  void dispose() {
    _rideSub?.cancel();
    _driversSub?.cancel();
    _mapCtrl?.dispose();
    super.dispose();
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
        });
      }
    } catch (_) {}
  }

  bool _popped = false;

  bool _routeCalculated = false;
  double _totalRouteKm = 0; // fixed pickup→destination distance

  void _listenRide() {
    _rideSub = db.collection('rides').doc(widget.rideId).snapshots().listen((
      snap,
    ) {
      if (!snap.exists || !mounted) return;
      final data = snap.data()!;
      final prevStatus = _rideStatus;
      final prevPhase = _tripPhase;
      final newDriverId = data['driverId'] as String?;
      setState(() {
        _rideData = data;
        _rideStatus = data['status'] ?? 'requested';
        _tripPhase = data['tripPhase'] as String? ?? '';
        _driverId = newDriverId;
      });
      // Calculate route once GeoPoints are available from Firestore
      if (!_routeCalculated &&
          (data['pickupLocation'] != null ||
              data['destinationLocation'] != null)) {
        _routeCalculated = true;
        _calculateRoute();
      }
      // start tracking assigned driver once accepted
      if (newDriverId != null && prevStatus == 'requested') {
        _listenAssignedDriver(newDriverId);
      }
      // when trip starts, redraw route to destination and avoid stacked markers
      if (prevPhase != 'in_trip' && _tripPhase == 'in_trip') {
        _lastDriverPos = null;
        // remove pickup marker so it doesn't visually overlap the driver marker
        setState(() {
          _markers = _markers
              .where((m) => m.markerId.value != 'pickup')
              .toSet();
        });
        final driverMarker = _markers
            .where((m) => m.markerId.value == 'driver')
            .firstOrNull;
        if (driverMarker != null) _updateLiveRoute(driverMarker.position);
      }
      // navigate away — only once
      if (!_popped) {
        if (_rideStatus == 'cancelled') {
          _popped = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        } else if (_rideStatus == 'completed') {
          _popped = true;
          // restore total distance for the receipt if remaining was shown
          if (_totalRouteKm > 0) _distanceKm = _totalRouteKm;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showCompletedSheet();
          });
        }
      }
    });
  }

  void _listenAssignedDriver(String driverId) {
    _driversSub?.cancel();
    _driversSub = db.collection('drivers').doc(driverId).snapshots().listen((
      snap,
    ) async {
      try {
        debugPrint('[RideTracking] driver snapshot for $driverId');
      } catch (_) {}
      if (!snap.exists || !mounted) return;
      final loc = snap.data()?['location'] as GeoPoint?;
      if (loc == null) return;
      final pos = LatLng(loc.latitude, loc.longitude);
      final heading = (snap.data()?['heading'] as num?)?.toDouble() ?? 0;
      final carIcon = await MapService.carMarker(heading);
      if (!mounted) return;
      setState(() {
        _markers = {
          ..._markers.where((m) => m.markerId.value != 'driver'),
          Marker(
            markerId: const MarkerId('driver'),
            position: pos,
            icon: carIcon,
            flat: true,
            anchor: const Offset(0.5, 0.5),
            infoWindow: InfoWindow(title: _rideData?['driverName'] ?? 'Driver'),
          ),
        };
      });
      _fitMarkers();
      _updateLiveRoute(pos);
    });
  }

  LatLng? _lastDriverPos;

  Future<void> _updateLiveRoute(LatLng driverPos, {int attempt = 0}) async {
    if (_lastDriverPos != null) {
      final dlat = driverPos.latitude - _lastDriverPos!.latitude;
      final dlng = driverPos.longitude - _lastDriverPos!.longitude;
      if (dlat * dlat + dlng * dlng < 0.000000081) return; // ~30 m
    }
    if (_liveRouteDrawing) return;
    _liveRouteDrawing = true;
    _lastDriverPos = driverPos;

    LatLng? destination;
    if (_rideStatus == 'accepted' && _tripPhase != 'in_trip') {
      final pickupGeo = _rideData?['pickupLocation'] as GeoPoint?;
      if (pickupGeo != null) {
        destination = LatLng(pickupGeo.latitude, pickupGeo.longitude);
      }
    } else if (_tripPhase == 'in_trip' || _rideStatus == 'in_trip') {
      final destGeo = _rideData?['destinationLocation'] as GeoPoint?;
      if (destGeo != null) {
        destination = LatLng(destGeo.latitude, destGeo.longitude);
      }
    }
    if (destination == null) {
      _liveRouteDrawing = false;
      return;
    }

    try {
      final res = await http
          .get(
            Uri.parse(
              'https://maps.googleapis.com/maps/api/directions/json'
              '?origin=${driverPos.latitude},${driverPos.longitude}'
              '&destination=${destination.latitude},${destination.longitude}'
              '&mode=driving'
              '&key=$googleMapsApiKey',
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body);
      if ((data['routes'] as List).isEmpty) throw Exception('No routes');
      final points = data['routes'][0]['overview_polyline']['points'] as String;
      final decoded = _decodePolyline(points);
      // extract remaining distance from Directions response
      final remainingM =
          (data['routes'][0]['legs'][0]['distance']['value'] as num).toDouble();
      final remainingKm = remainingM / 1000;
      _lastGoodLivePolyline = decoded;
      if (mounted) {
        setState(() {
          // during in_trip update remaining distance; otherwise keep total
          if (_tripPhase == 'in_trip' || _rideStatus == 'in_trip') {
            _distanceKm = remainingKm;
          }
          _polylines = {
            ..._polylines.where((p) => p.polylineId.value != 'live'),
            Polyline(
              polylineId: const PolylineId('live'),
              points: decoded,
              color: Colors.blue,
              width: 4,
            ),
          };
        });
      }
    } catch (e) {
      debugPrint('[RideTracking] _updateLiveRoute error: $e');
      // restore cached polyline so map doesn't go blank
      if (mounted && _lastGoodLivePolyline.isNotEmpty) {
        final hasLive = _polylines.any((p) => p.polylineId.value == 'live');
        if (!hasLive) {
          setState(() {
            _polylines = {
              ..._polylines,
              Polyline(
                polylineId: const PolylineId('live'),
                points: _lastGoodLivePolyline,
                color: Colors.blue.withOpacity(0.5),
                width: 4,
              ),
            };
          });
        }
      }
      if (attempt < 3 && mounted) {
        _liveRouteDrawing = false;
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        _updateLiveRoute(driverPos, attempt: attempt + 1);
        return;
      }
    } finally {
      _liveRouteDrawing = false;
    }
  }

  void _fitMarkersIfReady() {
    if (_mapCtrl == null || _markers.length < 2) return;
    final lats = _markers.map((m) => m.position.latitude);
    final lngs = _markers.map((m) => m.position.longitude);
    _mapCtrl!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(
            lats.reduce((a, b) => a < b ? a : b),
            lngs.reduce((a, b) => a < b ? a : b),
          ),
          northeast: LatLng(
            lats.reduce((a, b) => a > b ? a : b),
            lngs.reduce((a, b) => a > b ? a : b),
          ),
        ),
        80,
      ),
    );
  }

  void _fitMarkers() {
    if (_mapCtrl == null || _markers.length < 2) return;
    final lats = _markers.map((m) => m.position.latitude);
    final lngs = _markers.map((m) => m.position.longitude);
    _mapCtrl!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(
            lats.reduce((a, b) => a < b ? a : b),
            lngs.reduce((a, b) => a < b ? a : b),
          ),
          northeast: LatLng(
            lats.reduce((a, b) => a > b ? a : b),
            lngs.reduce((a, b) => a > b ? a : b),
          ),
        ),
        80,
      ),
    );
  }

  Future<void> _calculateRoute({int attempt = 0}) async {
    try {
      try {
        debugPrint(
          '[RideTracking] _calculateRoute attempt=$attempt rideId=${widget.rideId}',
        );
      } catch (_) {}
      // Prefer stored GeoPoints — more reliable than geocoding address strings
      LatLng? origin, dest;
      if (_rideData != null) {
        final pGeo = _rideData!['pickupLocation'] as GeoPoint?;
        final dGeo = _rideData!['destinationLocation'] as GeoPoint?;
        if (pGeo != null) origin = LatLng(pGeo.latitude, pGeo.longitude);
        if (dGeo != null) dest = LatLng(dGeo.latitude, dGeo.longitude);
      }

      // Fall back to geocoding if GeoPoints not available yet
      if (origin == null || dest == null) {
        final pickupRes = await http
            .get(
              Uri.parse(
                'https://maps.googleapis.com/maps/api/geocode/json'
                '?address=${Uri.encodeComponent(widget.pickup)}'
                '&key=$geocodingApiKey',
              ),
            )
            .timeout(const Duration(seconds: 10));
        final destRes = await http
            .get(
              Uri.parse(
                'https://maps.googleapis.com/maps/api/geocode/json'
                '?address=${Uri.encodeComponent(widget.destination)}'
                '&key=$geocodingApiKey',
              ),
            )
            .timeout(const Duration(seconds: 10));
        final pickupLoc = jsonDecode(
          pickupRes.body,
        )['results']?[0]?['geometry']?['location'];
        final destLoc = jsonDecode(
          destRes.body,
        )['results']?[0]?['geometry']?['location'];
        if (pickupLoc == null || destLoc == null) {
          throw Exception('Geocode failed');
        }
        origin ??= LatLng(pickupLoc['lat'], pickupLoc['lng']);
        dest ??= LatLng(destLoc['lat'], destLoc['lng']);
      }

      setState(() {
        _markers = {
          ..._markers,
          Marker(
            markerId: const MarkerId('pickup'),
            position: origin!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen,
            ),
            infoWindow: InfoWindow(title: 'Pickup: ${widget.pickup}'),
          ),
          Marker(
            markerId: const MarkerId('destination'),
            position: dest!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            infoWindow: InfoWindow(title: 'Destination: ${widget.destination}'),
          ),
        };
      });

      final dirRes = await http
          .get(
            Uri.parse(
              'https://maps.googleapis.com/maps/api/directions/json'
              '?origin=${origin.latitude},${origin.longitude}'
              '&destination=${dest.latitude},${dest.longitude}'
              '&mode=driving'
              '&key=$directionsApiKey',
            ),
          )
          .timeout(const Duration(seconds: 10));
      final dirData = jsonDecode(dirRes.body);
      if (dirData['status'] != 'OK' || (dirData['routes'] as List).isEmpty) {
        throw Exception('Directions failed: ${dirData['status']}');
      }

      final leg = dirData['routes'][0]['legs'][0];
      final km = (leg['distance']['value'] as num).toDouble() / 1000;
      final fare = km < _shortDistanceThresholdKm
          ? _shortDistanceFee
          : _baseFee + km * _pricePerKm;
      final decoded = _decodePolyline(
        dirData['routes'][0]['overview_polyline']['points'] as String,
      );

      if (mounted) {
        setState(() {
          _distanceKm = km;
          _totalRouteKm = km;
          _estimatedFare = fare;
          _polylines = {
            Polyline(
              polylineId: const PolylineId('route'),
              points: decoded,
              color: _navy,
              width: 5,
            ),
          };
        });
        _fitBounds(origin, dest);
      }
    } catch (e) {
      debugPrint('[RideTracking] _calculateRoute error: $e');
      if (attempt < 3 && mounted) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        _calculateRoute(attempt: attempt + 1);
      }
    }
  }

  void _fitBounds(LatLng a, LatLng b) {
    final bounds = LatLngBounds(
      southwest: LatLng(
        a.latitude < b.latitude ? a.latitude : b.latitude,
        a.longitude < b.longitude ? a.longitude : b.longitude,
      ),
      northeast: LatLng(
        a.latitude > b.latitude ? a.latitude : b.latitude,
        a.longitude > b.longitude ? a.longitude : b.longitude,
      ),
    );
    if (_mapCtrl != null) {
      _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
    } else {
      // map not ready yet — retry once it is
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds(a, b));
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

  Future<void> _cancelRide() async {
    // If already accepted, apply cancellation fee
    if (_rideStatus == 'accepted') {
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
      // Show confirmation sheet with fee
      final confirmed = await _showCancellationFeeSheet(cancellationFee);
      if (confirmed != true) return;
      final subFee = cancellationFee * (subscriptionRate / 100);
      final driverId = _rideData?['driverId'] as String?;
      await db.collection('rides').doc(widget.rideId).update({
        'status': 'cancelled',
        'cancelledByPassenger': true,
        'cancellationFee': cancellationFee,
        'subscriptionFeeCharged': subFee,
      });
      if (driverId != null && subFee > 0) {
        try {
          await db.collection('drivers').doc(driverId).update({
            'subscriptionBalance': FieldValue.increment(subFee),
          });
        } catch (_) {}
      }
    } else {
      await db.collection('rides').doc(widget.rideId).update({
        'status': 'cancelled',
      });
    }
    // listener will detect 'cancelled' status and pop
  }

  Future<bool?> _showCancellationFeeSheet(double fee) {
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
                color: _red.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cancel_outlined, color: _red, size: 36),
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
                  ? 'Since the driver has already accepted, a cancellation fee applies.'
                  : 'Are you sure you want to cancel this ride?',
              textAlign: TextAlign.center,
              style: TextStyle(color: _navy.withOpacity(0.55), fontSize: 13),
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
                  color: _red.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _red.withOpacity(0.2)),
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
                        color: _red,
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
                      side: BorderSide(color: _navy.withOpacity(0.3)),
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
                      backgroundColor: _red,
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

  String get _statusLabel {
    if (_rideStatus == 'accepted') {
      if (_tripPhase == 'arrived') return 'Driver has arrived!';
      return 'Driver is on the way!';
    }
    switch (_rideStatus) {
      case 'requested':
        return 'Looking for a driver...';
      case 'in_trip':
        return 'Trip in progress';
      case 'completed':
        return 'Trip completed';
      case 'cancelled':
        return 'Ride cancelled';
      default:
        return 'Processing...';
    }
  }

  Color get _statusColor {
    if (_rideStatus == 'accepted' && _tripPhase == 'arrived') {
      return Colors.orange;
    }
    switch (_rideStatus) {
      case 'requested':
        return Colors.orange;
      case 'accepted':
        return Colors.blue;
      case 'in_trip':
        return Colors.green;
      case 'completed':
        return Colors.green;
      case 'cancelled':
        return _red;
      default:
        return _navy;
    }
  }

  IconData get _statusIcon {
    if (_rideStatus == 'accepted' && _tripPhase == 'arrived') {
      return Icons.place_rounded;
    }
    switch (_rideStatus) {
      case 'accepted':
        return Icons.directions_car_rounded;
      case 'in_trip':
        return Icons.navigation_rounded;
      default:
        return Icons.directions_car_rounded;
    }
  }

  String get _statusBadge {
    if (_rideStatus == 'accepted') {
      if (_tripPhase == 'arrived') return 'Arrived ✔';
      return 'On the way';
    }
    if (_rideStatus == 'in_trip') return 'Trip started';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Map
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: const CameraPosition(
                target: _defaultTarget,
                zoom: 13,
              ),
              onMapCreated: (c) {
                _mapCtrl = c;
                // route already drawn in initState; just fit bounds
                _fitMarkersIfReady();
              },
              markers: _markers,
              polylines: _polylines,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapType: MapType.normal,
            ),
          ),

          // Top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _navy.withOpacity(0.08),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.arrow_back_rounded,
                          color: _navy,
                          size: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _statusLabel,
                            style: TextStyle(
                              color: _statusColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            '${widget.pickup} → ${widget.destination}',
                            style: TextStyle(
                              color: _navy.withOpacity(0.5),
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    _StatusPulse(color: _statusColor),
                  ],
                ),
              ),
            ),
          ),

          // Bottom card
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
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
                  // Handle
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Route info
                  Row(
                    children: [
                      Expanded(
                        child: _InfoTile(
                          icon: Icons.straighten_rounded,
                          label:
                              (_tripPhase == 'in_trip' ||
                                  _rideStatus == 'in_trip')
                              ? 'Remaining'
                              : 'Distance',
                          value: _distanceKm >= 1
                              ? '${_distanceKm.toStringAsFixed(1)} km'
                              : '${(_distanceKm * 1000).toStringAsFixed(0)} m',
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 40,
                        color: _navy.withOpacity(0.1),
                      ),
                      Expanded(
                        child: _InfoTile(
                          icon: Icons.payments_rounded,
                          label: 'Estimated Fare',
                          value: 'MWK ${_estimatedFare.toStringAsFixed(0)}',
                          valueColor: Colors.green,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Driver / trip status card
                  if (_rideData != null && _rideStatus != 'requested') ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _statusColor.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _statusColor.withOpacity(0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _statusColor.withOpacity(0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _statusIcon,
                              color: _statusColor,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _rideData!['driverName'] ?? 'Driver',
                                  style: const TextStyle(
                                    color: _navy,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                if ((_rideData!['driverCar'] ?? '').isNotEmpty)
                                  Text(
                                    _rideData!['driverCar'],
                                    style: TextStyle(
                                      color: _navy.withOpacity(0.5),
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Call button
                          if ((_rideData!['driverPhone'] ?? '').isNotEmpty)
                            GestureDetector(
                              onTap: () => launchUrl(
                                Uri.parse('tel:${_rideData!['driverPhone']}'),
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.phone_rounded,
                                  color: Colors.green,
                                  size: 18,
                                ),
                              ),
                            ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _statusColor.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _statusBadge,
                              style: TextStyle(
                                color: _statusColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Cancel button — only while waiting for a driver
                  if (_rideStatus == 'requested')
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _cancelRide,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _red,
                          size: 18,
                        ),
                        label: const Text(
                          'Cancel Ride',
                          style: TextStyle(color: _red),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: _red),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
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

  void _showCompletedSheet() {
    final fare =
        (_rideData?['finalFare'] as num?)?.toDouble() ?? _estimatedFare;
    final distKm =
        (_rideData?['tripDistanceKm'] as num?)?.toDouble() ?? _distanceKm;
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RatingSheet(
        fare: fare,
        distKm: distKm,
        rideId: widget.rideId,
        driverName: _rideData?['driverName'] ?? 'your driver',
        driverCar: _rideData?['driverCar'] ?? '',
        pickup: widget.pickup,
        destination: widget.destination,
        onDone: () {
          Navigator.pop(context); // close sheet
          Navigator.pop(context); // back to home
        },
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: _navy.withOpacity(0.5), size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? _navy,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        Text(
          label,
          style: TextStyle(color: _navy.withOpacity(0.45), fontSize: 11),
        ),
      ],
    );
  }
}

// ── Rating Sheet (with full receipt) ────────────────────────────────
class _RatingSheet extends StatefulWidget {
  final double fare;
  final double distKm;
  final String rideId;
  final String driverName;
  final String driverCar;
  final String pickup;
  final String destination;
  final VoidCallback onDone;
  const _RatingSheet({
    required this.fare,
    required this.distKm,
    required this.rideId,
    required this.driverName,
    required this.driverCar,
    required this.pickup,
    required this.destination,
    required this.onDone,
  });
  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  int _rating = 0;
  final _commentCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!mounted) return;
    setState(() => _submitting = true);
    try {
      await db.collection('rides').doc(widget.rideId).update({
        'driverRating': _rating,
        if (_commentCtrl.text.trim().isNotEmpty)
          'passengerComment': _commentCtrl.text.trim(),
      });
    } catch (_) {}
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
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
        child: SingleChildScrollView(
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
                  color: Colors.green.withOpacity(0.08),
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
                'How was your ride with ${widget.driverName}?',
                style: TextStyle(color: _navy.withOpacity(0.5), fontSize: 13),
              ),
              const SizedBox(height: 20),

              // ── Receipt card ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _navy,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    Text(
                      'Amount to Pay',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'MWK ${widget.fare.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 34,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Divider(color: Colors.white.withOpacity(0.12), height: 1),
                    const SizedBox(height: 12),
                    _ReceiptRow(
                      label: 'Distance',
                      value: widget.distKm >= 1
                          ? '${widget.distKm.toStringAsFixed(2)} km'
                          : '${(widget.distKm * 1000).toStringAsFixed(0)} m',
                    ),
                    const SizedBox(height: 6),
                    _ReceiptRow(label: 'Driver', value: widget.driverName),
                    if (widget.driverCar.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _ReceiptRow(label: 'Vehicle', value: widget.driverCar),
                    ],
                    const SizedBox(height: 6),
                    _ReceiptRow(label: 'From', value: widget.pickup),
                    const SizedBox(height: 6),
                    _ReceiptRow(label: 'To', value: widget.destination),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── Stars ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  final filled = i < _rating;
                  return GestureDetector(
                    onTap: () => setState(() => _rating = i + 1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        filled
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: filled ? Colors.amber : Colors.grey.shade300,
                        size: 40,
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 6),
              Text(
                _rating == 0
                    ? 'Tap to rate'
                    : _rating == 1
                    ? 'Poor'
                    : _rating == 2
                    ? 'Fair'
                    : _rating == 3
                    ? 'Good'
                    : _rating == 4
                    ? 'Great'
                    : 'Excellent!',
                style: TextStyle(
                  color: _rating == 0 ? Colors.grey : Colors.amber.shade700,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),

              // ── Comment ──
              TextField(
                controller: _commentCtrl,
                maxLines: 2,
                style: const TextStyle(color: _navy, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Leave a comment (optional)',
                  hintStyle: TextStyle(
                    color: _navy.withOpacity(0.35),
                    fontSize: 13,
                  ),
                  filled: true,
                  fillColor: _navy.withOpacity(0.04),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting || _rating == 0 ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade200,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Submit Rating',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _submitting ? null : widget.onDone,
                child: Text(
                  'Skip',
                  style: TextStyle(color: _navy.withOpacity(0.4), fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReceiptRow extends StatelessWidget {
  final String label;
  final String value;
  const _ReceiptRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _StatusPulse extends StatefulWidget {
  final Color color;
  const _StatusPulse({required this.color});
  @override
  State<_StatusPulse> createState() => _StatusPulseState();
}

class _StatusPulseState extends State<_StatusPulse>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
