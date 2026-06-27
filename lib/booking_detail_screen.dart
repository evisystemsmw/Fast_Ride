import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'map_service.dart';
import 'db.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class BookingDetailScreen extends StatefulWidget {
  final String rideId;
  final Map<String, dynamic> ride;

  const BookingDetailScreen({
    super.key,
    required this.rideId,
    required this.ride,
  });

  @override
  State<BookingDetailScreen> createState() => _BookingDetailScreenState();
}

class _BookingDetailScreenState extends State<BookingDetailScreen> {
  final Completer<GoogleMapController> _mapController = Completer();
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  double _distanceKm = 0;
  double _baseFee = 0;
  double _pricePerKm = 0;
  double _shortDistanceFee = 0;
  double _shortDistanceThresholdKm = 0;
  bool _loadingFare = true;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    await _loadFareConfig();
    _buildMapData();
  }

  Future<void> _loadFareConfig() async {
    try {
      final doc = await db.collection('settings').doc('fare').get();
      final data = doc.data() ?? {};
      setState(() {
        _baseFee = (data['baseFee'] as num?)?.toDouble() ?? 2500;
        _pricePerKm = (data['pricePerKm'] as num?)?.toDouble() ?? 2500;
        _shortDistanceFee = (data['shortDistanceFee'] as num?)?.toDouble() ?? 10000;
        _shortDistanceThresholdKm = (data['shortDistanceThresholdKm'] as num?)?.toDouble() ?? 2.8;
        _loadingFare = false;
      });
    } catch (_) {
      setState(() {
        _baseFee = 2500;
        _pricePerKm = 2500;
        _shortDistanceFee = 10000;
        _shortDistanceThresholdKm = 2.8;
        _loadingFare = false;
      });
    }
  }

  void _buildMapData() {
    final pickupGeo = widget.ride['pickupLocation'] as GeoPoint?;
    final destGeo = widget.ride['destinationLocation'] as GeoPoint?;

    // prefer stored GeoPoints, else fall back to pickupLat/pickupLng + geocode dest
    final double? pLat = pickupGeo?.latitude ?? (widget.ride['pickupLat'] as num?)?.toDouble();
    final double? pLng = pickupGeo?.longitude ?? (widget.ride['pickupLng'] as num?)?.toDouble();

    if (pLat != null && pLng != null) {
      final pickup = LatLng(pLat, pLng);
      if (destGeo != null) {
        final dest = LatLng(destGeo.latitude, destGeo.longitude);
        _setMarkers(pickup, dest);
        _drawRoute(pickup, dest);
      } else {
        // geocode destination string
        _geocodeAndDraw(pickup, widget.ride['destination'] as String? ?? '');
      }
    } else {
      // geocode both
      _geocodeBothAndDraw(
        widget.ride['pickup'] as String? ?? '',
        widget.ride['destination'] as String? ?? '',
      );
    }
  }

  Future<void> _geocodeAndDraw(LatLng pickup, String destAddress) async {
    if (destAddress.isEmpty) return;
    try {
      final res = await http.get(Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?address=${Uri.encodeComponent(destAddress)}'
        '&key=$geocodingApiKey',
      ));
      final data = jsonDecode(res.body);
      final loc = data['results']?[0]?['geometry']?['location'];
      if (loc == null) return;
      final dest = LatLng((loc['lat'] as num).toDouble(), (loc['lng'] as num).toDouble());
      _setMarkers(pickup, dest);
      _drawRoute(pickup, dest);
    } catch (_) {}
  }

  Future<void> _geocodeBothAndDraw(String pickupAddr, String destAddr) async {
    if (pickupAddr.isEmpty || destAddr.isEmpty) return;
    try {
      final results = await Future.wait([
        http.get(Uri.parse('https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(pickupAddr)}&key=$geocodingApiKey')),
        http.get(Uri.parse('https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(destAddr)}&key=$geocodingApiKey')),
      ]);
      final pLoc = jsonDecode(results[0].body)['results']?[0]?['geometry']?['location'];
      final dLoc = jsonDecode(results[1].body)['results']?[0]?['geometry']?['location'];
      if (pLoc == null || dLoc == null) return;
      final pickup = LatLng((pLoc['lat'] as num).toDouble(), (pLoc['lng'] as num).toDouble());
      final dest = LatLng((dLoc['lat'] as num).toDouble(), (dLoc['lng'] as num).toDouble());
      _setMarkers(pickup, dest);
      _drawRoute(pickup, dest);
    } catch (_) {}
  }

  void _setMarkers(LatLng pickup, LatLng dest) {
    if (!mounted) return;
    setState(() {
      _markers = {
        Marker(
          markerId: const MarkerId('pickup'),
          position: pickup,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Pickup: ${widget.ride['pickup'] ?? ''}'),
        ),
        Marker(
          markerId: const MarkerId('destination'),
          position: dest,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(title: 'Destination: ${widget.ride['destination'] ?? ''}'),
        ),
      };
    });
  }

  Future<void> _drawRoute(LatLng origin, LatLng dest) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${dest.latitude},${dest.longitude}'
      '&mode=driving'
      '&key=$googleMapsApiKey',
    );
    final res = await http.get(url);
    if (res.statusCode != 200) return;
    final data = jsonDecode(res.body);
    if ((data['routes'] as List).isEmpty) return;

    final distanceM = (data['routes'][0]['legs'][0]['distance']['value'] as num).toDouble();
    final points = data['routes'][0]['overview_polyline']['points'] as String;
    final decoded = _decodePolyline(points);

    if (!mounted) return;
    setState(() {
      _distanceKm = distanceM / 1000;
      _polylines = {
        Polyline(
          polylineId: const PolylineId('route'),
          points: decoded,
          color: _navy,
          width: 5,
        ),
      };
    });

    // fit camera to show both markers
    if (_mapController.isCompleted) {
      final c = await _mapController.future;
      final bounds = LatLngBounds(
        southwest: LatLng(
          origin.latitude < dest.latitude ? origin.latitude : dest.latitude,
          origin.longitude < dest.longitude ? origin.longitude : dest.longitude,
        ),
        northeast: LatLng(
          origin.latitude > dest.latitude ? origin.latitude : dest.latitude,
          origin.longitude > dest.longitude ? origin.longitude : dest.longitude,
        ),
      );
      await c.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
    }
  }

  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0, lat = 0, lng = 0;
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

  double get _estimatedFare => _distanceKm <= _shortDistanceThresholdKm
      ? _shortDistanceFee
      : _baseFee + (_distanceKm * _pricePerKm);

  LatLng get _initialTarget {
    final geo = widget.ride['pickupLocation'] as GeoPoint?;
    return geo != null ? LatLng(geo.latitude, geo.longitude) : const LatLng(-13.9626, 33.7741);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: Stack(
        children: [
          // Full screen map
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _initialTarget, zoom: 13),
            onMapCreated: (c) {
              if (!_mapController.isCompleted) _mapController.complete(c);
            },
            markers: _markers,
            polylines: _polylines,
            zoomControlsEnabled: false,
            myLocationButtonEnabled: false,
            mapType: MapType.normal,
          ),

          // Back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 6),
                  ],
                ),
                child: const Icon(Icons.arrow_back_ios_new_rounded, color: _navy, size: 18),
              ),
            ),
          ),

          // Bottom info card
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // drag handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: _navy.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Pickup
                  _LocationRow(
                    color: Colors.green,
                    label: 'Pickup',
                    value: widget.ride['pickup'] ?? '',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Container(
                      width: 2,
                      height: 20,
                      color: _navy.withOpacity(0.12),
                    ),
                  ),
                  // Destination
                  _LocationRow(
                    color: _red,
                    label: 'Destination',
                    value: widget.ride['destination'] ?? '',
                  ),

                  const SizedBox(height: 16),

                  // Distance
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: _navy.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.straighten_rounded, color: _navy, size: 18),
                        const SizedBox(width: 10),
                        const Text('Distance',
                            style: TextStyle(color: _navy, fontSize: 13)),
                        const Spacer(),
                        Text(
                          _distanceKm == 0
                              ? '—'
                              : _distanceKm >= 1
                                  ? '${_distanceKm.toStringAsFixed(1)} km'
                                  : '${(_distanceKm * 1000).toStringAsFixed(0)} m',
                          style: const TextStyle(
                              color: _navy, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Estimated fare
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: _navy,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.payments_rounded, color: Colors.white, size: 20),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Estimated Fare',
                                style: TextStyle(color: Colors.white70, fontSize: 11)),
                            const SizedBox(height: 2),
                            Text(
                              _loadingFare || _distanceKm == 0
                                  ? 'Calculating...'
                                  : 'MWK ${_estimatedFare.toStringAsFixed(0)}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (!_loadingFare && _distanceKm > 0)
                          Text(
                            _distanceKm <= _shortDistanceThresholdKm
                                ? 'Short trip flat rate'
                                : 'MWK${_baseFee.toStringAsFixed(0)} base\n+ MWK${_pricePerKm.toStringAsFixed(0)}/km',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 10),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Decline & Accept buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await db.collection('rides').doc(widget.rideId).update({'status': 'cancelled'});
                            if (context.mounted) Navigator.pop(context);
                          },
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Decline'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _red,
                            side: const BorderSide(color: _red),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final uid = FirebaseAuth.instance.currentUser!.uid;
                            await db.collection('rides').doc(widget.rideId).update({
                              'driverId': uid,
                              'status': 'accepted',
                            });
                            if (context.mounted) Navigator.pop(context);
                          },
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Accept', style: TextStyle(fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
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

class _LocationRow extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  const _LocationRow({required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const Icon(Icons.circle, color: Colors.white, size: 8),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 10, color: _navy.withOpacity(0.45))),
              Text(value,
                  style: const TextStyle(
                      color: _navy, fontWeight: FontWeight.w600, fontSize: 13),
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}
