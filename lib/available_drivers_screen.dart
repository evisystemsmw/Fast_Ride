import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'db.dart';
import 'map_service.dart';
import 'package:geolocator/geolocator.dart';

const _googleMapsApiKey = googleMapsApiKey;

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class AvailableDriversScreen extends StatefulWidget {
  final String rideId;
  final String pickup;
  final String destination;
  final double? pickupLat;
  final double? pickupLng;
  final bool isScheduled;
  final DateTime? scheduledAt;

  const AvailableDriversScreen({
    super.key,
    required this.rideId,
    required this.pickup,
    required this.destination,
    this.pickupLat,
    this.pickupLng,
    this.isScheduled = false,
    this.scheduledAt,
  });

  @override
  State<AvailableDriversScreen> createState() => _AvailableDriversScreenState();
}

class _AvailableDriversScreenState extends State<AvailableDriversScreen>
    with SingleTickerProviderStateMixin {
  GoogleMapController? _mapCtrl;
  LatLng? _pickupLatLng;
  Set<Marker> _markers = {};
  List<_DriverInfo> _drivers = [];
  bool _resolvingPickup = true;
  StreamSubscription? _driverSub;
  String? _selectedDriverId;
  bool _booking = false;
  late AnimationController _pulseCtrl;

  double? _estimatedFare;

  Set<String> _busyDriverIds = {};
  StreamSubscription? _busySub;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _lastDriverDocs = [];

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _startBusyStream();
    _startDriverStream();
    _resolvePickup();
    _fetchEstimatedFare().then((f) { if (mounted) setState(() => _estimatedFare = f); });
  }

  @override
  void dispose() {
    _driverSub?.cancel();
    _busySub?.cancel();
    _mapCtrl?.dispose();
    _pulseCtrl.dispose();
    // Cancel the ride if passenger backed out without booking a driver
    db.collection('rides').doc(widget.rideId).get().then((doc) {
      if (!doc.exists) return;
      final data = doc.data()!;
      final status = data['status'] as String? ?? '';
      final hasDriver = data['driverId'] != null;
      if ((status == 'pending' || status == 'scheduled') && !hasDriver) {
        doc.reference.delete();
      }
    });
    super.dispose();
  }

  void _startBusyStream() {
    _busySub = db
        .collection('rides')
        .where('status', whereIn: ['accepted', 'in_trip'])
        .snapshots()
        .listen((snap) {
      final ids = snap.docs
          .map((d) => d.data()['driverId'] as String?)
          .whereType<String>()
          .toSet();
      _busyDriverIds = ids;
      if (_lastDriverDocs.isNotEmpty) _rebuildDriverList(_lastDriverDocs);
    });
  }

  /// Stream only drivers within ~15 km of pickup using a lat/lng bounding box
  void _startDriverStream() {
    // If pickup coords not yet known, stream all online and re-filter once resolved
    final lat = _pickupLatLng?.latitude;
    final lng = _pickupLatLng?.longitude;
    const double delta = 0.135; // ~15 km in degrees

    // No range filter server-side to avoid composite index requirement.
    // Filter isOnline + location client-side.
    final query = db.collection('drivers');

    _driverSub = query.snapshots().listen((snap) {
      final filtered = snap.docs.where((d) {
        final data = d.data();
        if (data['isOnline'] != true) return false;
        if (lat == null || lng == null) return true;
        final dLat = (data['lat'] as num?)?.toDouble();
        final dLng = (data['lng'] as num?)?.toDouble();
        if (dLat == null || dLng == null) return false;
        return (dLat - lat).abs() <= delta && (dLng - lng).abs() <= delta;
      }).toList();
      _lastDriverDocs = filtered;
      _rebuildDriverList(filtered);
    });
  }

  void _rebuildDriverList(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final list = <_DriverInfo>[];
    final driverMarkers = <Marker>{};

    for (final doc in docs) {
      final data = doc.data();
      final status = (data['status'] as String?)?.toLowerCase();
      if (status == 'pending' || status == 'suspended' || status == 'blocked') continue;
      final gp = data['location'] as GeoPoint?;
      final lat = gp?.latitude ?? (data['lat'] as num?)?.toDouble();
      final lng = gp?.longitude ?? (data['lng'] as num?)?.toDouble();
      final hasLocation = lat != null && lng != null;

      final distKm = (hasLocation && _pickupLatLng != null)
          ? MapService.distanceKm(
              _pickupLatLng!.latitude,
              _pickupLatLng!.longitude,
              lat,
              lng,
            )
          : double.maxFinite;
      final etaMin = distKm < double.maxFinite ? (distKm / 40 * 60).round() : 0;

      final name = (data['name'] as String? ?? 'Driver').trim();
      final car = (data['vehicleMake'] ?? data['car'] ?? '') as String;
      final plate = (data['numberPlate'] ?? data['plate'] ?? '') as String;
      final rating = (data['rating'] ?? 0.0).toDouble();
      final photoUrl = data['photoUrl'] as String?;

      final isBusy = _busyDriverIds.contains(doc.id);

      list.add(
        _DriverInfo(
          id: doc.id,
          name: name,
          car: car,
          plate: plate,
          rating: rating,
          distKm: distKm < double.maxFinite ? distKm : 0,
          etaMin: etaMin,
          photoUrl: photoUrl,
          position: LatLng(lat ?? 0, lng ?? 0),
          hasLocation: hasLocation,
          isBusy: isBusy,
        ),
      );

      if (hasLocation) {
        final isSelected = doc.id == _selectedDriverId;
        driverMarkers.add(
          Marker(
            markerId: MarkerId('driver_${doc.id}'),
            position: LatLng(lat, lng),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              isSelected ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed,
            ),
            infoWindow: InfoWindow(
              title: name,
              snippet: distKm < double.maxFinite
                  ? '$etaMin min • ${distKm.toStringAsFixed(1)} km'
                  : null,
            ),
            zIndex: isSelected ? 2 : 1,
          ),
        );
      }
    }

    list.sort((a, b) {
      if (a.isBusy && !b.isBusy) return 1;
      if (!a.isBusy && b.isBusy) return -1;
      if (a.hasLocation && !b.hasLocation) return -1;
      if (!a.hasLocation && b.hasLocation) return 1;
      return a.distKm.compareTo(b.distKm);
    });

    if (mounted) {
      setState(() {
        _drivers = list;
        _markers = {
          ..._markers.where((m) => m.markerId.value == 'pickup'),
          ...driverMarkers,
        };
      });
      if (_pickupLatLng != null) _fitMapBounds();
    }
  }

  Future<void> _resolvePickup() async {
    // Use pre-resolved coords if passed — instant, no HTTP needed
    if (widget.pickupLat != null && widget.pickupLng != null) {
      final latlng = LatLng(widget.pickupLat!, widget.pickupLng!);
      if (!mounted) return;
      setState(() {
        _pickupLatLng = latlng;
        _resolvingPickup = false;
        _markers = {
          Marker(
            markerId: const MarkerId('pickup'),
            position: latlng,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
            infoWindow: InfoWindow(title: '📍 ${widget.pickup}'),
          ),
          ..._markers.where((m) => m.markerId.value != 'pickup'),
        };
      });
      // restart stream with geo filter — the stream listener calls _rebuildDriverList
      _driverSub?.cancel();
      _startDriverStream();
      _fitMapBounds();
      return;
    }

    LatLng? latlng;
    // fallback: geocode the address string
    try {
      final res = await http.get(
        Uri.parse(
          'https://maps.googleapis.com/maps/api/geocode/json'
          '?address=${Uri.encodeComponent(widget.pickup)}'
          '&key=$googleMapsApiKey',
        ),
      );
      final data = jsonDecode(res.body);
      final loc = data['results']?[0]?['geometry']?['location'];
      if (loc != null) {
        latlng = LatLng(
          (loc['lat'] as num).toDouble(),
          (loc['lng'] as num).toDouble(),
        );
      }
    } catch (_) {}

    // last resort: GPS
    if (latlng == null) {
      try {
        final pos = await Geolocator.getCurrentPosition();
        latlng = LatLng(pos.latitude, pos.longitude);
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _pickupLatLng = latlng;
      _resolvingPickup = false;
      if (latlng != null) {
        _markers = {
          Marker(
            markerId: const MarkerId('pickup'),
            position: latlng,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
            infoWindow: InfoWindow(title: '📍 ${widget.pickup}'),
          ),
          ..._markers.where((m) => m.markerId.value != 'pickup'),
        };
      }
    });
    // restart stream now that we have pickup coords for geo filter
    _driverSub?.cancel();
    _startDriverStream();
    _fitMapBounds();
  }

  void _onDriverTapped(_DriverInfo driver) {
    setState(() => _selectedDriverId = driver.id);
    if (driver.hasLocation) {
      _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(driver.position, 15));
    }
    // rebuild markers so selected one turns green
    final currentDocs = _drivers;
    _rebuildFromDriverList(currentDocs);
    _showDriverSheet(driver);
  }

  void _rebuildFromDriverList(List<_DriverInfo> existing) {
    final driverMarkers = <Marker>{};
    for (final d in existing) {
      if (!d.hasLocation) continue;
      final isSelected = d.id == _selectedDriverId;
      driverMarkers.add(
        Marker(
          markerId: MarkerId('driver_${d.id}'),
          position: d.position,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            isSelected ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed,
          ),
          infoWindow: InfoWindow(
            title: d.name,
            snippet: d.hasLocation
                ? '${d.etaMin} min • ${d.distKm.toStringAsFixed(1)} km'
                : null,
          ),
          zIndex: isSelected ? 2 : 1,
        ),
      );
    }
    if (mounted) {
      setState(() {
        _markers = {
          ..._markers.where((m) => m.markerId.value == 'pickup'),
          ...driverMarkers,
        };
      });
    }
  }

  Future<double?> _fetchEstimatedFare() async {
    double baseFee = 2500, pricePerKm = 2500, shortDistanceFee = 10000, shortThresholdKm = 2.8;
    try {
      final fareDoc = await db.collection('settings').doc('fare').get();
      final fd = fareDoc.data() ?? {};
      baseFee = (fd['baseFee'] as num?)?.toDouble() ?? baseFee;
      pricePerKm = (fd['pricePerKm'] as num?)?.toDouble() ?? pricePerKm;
      shortDistanceFee = (fd['shortDistanceFee'] as num?)?.toDouble() ?? shortDistanceFee;
      shortThresholdKm = (fd['shortDistanceThresholdKm'] as num?)?.toDouble() ?? shortThresholdKm;
    } catch (_) {}
    double? distKm;
    if (widget.pickupLat != null && widget.pickupLng != null) {
      try {
        final res = await http.get(Uri.parse(
          'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=${widget.pickupLat},${widget.pickupLng}'
          '&destination=${Uri.encodeComponent(widget.destination)}'
          '&mode=driving&key=$googleMapsApiKey',
        ));
        final json = jsonDecode(res.body);
        final routes = json['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          distKm = (routes[0]['legs'][0]['distance']['value'] as num).toDouble() / 1000;
        }
      } catch (_) {}
    }
    if (distKm == null) return null;
    return distKm < shortThresholdKm ? shortDistanceFee : baseFee + distKm * pricePerKm;
  }

  void _showDriverSheet(_DriverInfo driver) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final fare = _estimatedFare;
          return Container(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.of(ctx).padding.bottom + 20,
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
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: _navy.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _navy.withOpacity(0.1),
                      image: driver.photoUrl != null
                          ? DecorationImage(
                              image: NetworkImage(driver.photoUrl!),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: driver.photoUrl == null
                        ? Center(
                            child: Text(
                              driver.name.isNotEmpty
                                  ? driver.name[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                color: _navy,
                                fontWeight: FontWeight.bold,
                                fontSize: 24,
                              ),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                driver.name,
                                style: const TextStyle(
                                  color: _navy,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (fare != null)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.green.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        'MWK ${fare.toStringAsFixed(0)}',
                                        style: TextStyle(
                                          color: Colors.green.shade700,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Estimated fare',
                                      style: TextStyle(
                                        color: _navy.withOpacity(0.4),
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          [
                            driver.car,
                            driver.plate,
                          ].where((s) => s.isNotEmpty).join(' • '),
                          style: TextStyle(
                            color: _navy.withOpacity(0.5),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.star_rounded,
                              color: Colors.amber,
                              size: 15,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              driver.rating > 0
                                  ? driver.rating.toStringAsFixed(1)
                                  : 'New driver',
                              style: const TextStyle(
                                color: _navy,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _StatPill(
                    icon: Icons.access_time_rounded,
                    label: driver.hasLocation ? '${driver.etaMin} min' : '–',
                    sublabel: 'ETA',
                  ),
                  const SizedBox(width: 10),
                  _StatPill(
                    icon: Icons.straighten_rounded,
                    label: driver.hasLocation
                        ? '${driver.distKm.toStringAsFixed(1)} km'
                        : '–',
                    sublabel: 'Distance',
                  ),
                  const SizedBox(width: 10),
                  _StatPill(
                    icon: Icons.circle,
                    label: driver.hasLocation ? 'Live' : 'Unknown',
                    sublabel: 'Location',
                    iconColor: driver.hasLocation
                        ? Colors.green
                        : _navy.withOpacity(0.35),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (driver.hasLocation) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _mapCtrl?.animateCamera(
                            CameraUpdate.newLatLngZoom(driver.position, 15),
                          );
                        },
                        icon: const Icon(
                          Icons.map_rounded,
                          color: _navy,
                          size: 16,
                        ),
                        label: const Text(
                          'Show on Map',
                          style: TextStyle(color: _navy),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: _navy.withOpacity(0.3)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    flex: 2,
                    child: StatefulBuilder(
                      builder: (_, setBtn) => ElevatedButton.icon(
                        onPressed: _booking
                            ? null
                            : () async {
                                await _bookDriver(driver, (fn) {
                                  setBtn(fn);
                                  setSheet(fn);
                                });
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                        icon: _booking
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_rounded, size: 18),
                        label: Text(_booking ? 'Booking...' : 'Book Driver'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _navy,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          );
        },
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _selectedDriverId = null);
      _rebuildFromDriverList(_drivers);
    });
  }

  Future<void> _bookDriver(_DriverInfo driver, StateSetter setSt) async {
    dev.log('[BOOK] _bookDriver started — driver.id: ${driver.id}');
    setSt(() => _booking = true);
    if (mounted) setState(() => _booking = true);
    try {
      final driverDoc = await db.collection('drivers').doc(driver.id).get();
      final dd = driverDoc.data() ?? {};
      // Check if driver is currently on a trip
      final busySnap = await db
          .collection('rides')
          .where('driverId', isEqualTo: driver.id)
          .where('status', whereIn: ['accepted', 'in_trip'])
          .limit(1)
          .get();
      if (busySnap.docs.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${driver.name} is currently on a trip. Please choose another driver.'),
              backgroundColor: _red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      dev.log(
        '[BOOK] driver doc exists: ${driverDoc.exists} | driver name: ${dd['name']}',
      );
      final Map<String, dynamic> update = {
        'driverId': driver.id,
        'driverName': dd['name'] ?? driver.name,
        'driverPhone': dd['phone'] ?? '',
        'driverCar':
            '${dd['vehicleMake'] ?? driver.car} ${dd['numberPlate'] ?? driver.plate}'
                .trim(),
        'status': widget.isScheduled ? 'scheduled' : 'requested',
        'preBookedAt': FieldValue.serverTimestamp(),
      };
      await db.collection('rides').doc(widget.rideId).update(update);
      dev.log('[BOOK] ride updated with driverId: ${driver.id}');

      // Fetch fare config and compute estimated fare + distance
      double baseFee = 2500,
          pricePerKm = 2500,
          shortDistanceFee = 10000,
          shortThresholdKm = 2.8;
      try {
        final fareDoc = await db.collection('settings').doc('fare').get();
        final fd = fareDoc.data() ?? {};
        baseFee = (fd['baseFee'] as num?)?.toDouble() ?? baseFee;
        pricePerKm = (fd['pricePerKm'] as num?)?.toDouble() ?? pricePerKm;
        shortDistanceFee =
            (fd['shortDistanceFee'] as num?)?.toDouble() ?? shortDistanceFee;
        shortThresholdKm =
            (fd['shortDistanceThresholdKm'] as num?)?.toDouble() ??
            shortThresholdKm;
      } catch (_) {}

      double distKm = driver.distKm;
      if (widget.pickupLat != null && widget.pickupLng != null) {
        try {
          final res = await http.get(
            Uri.parse(
              'https://maps.googleapis.com/maps/api/directions/json'
              '?origin=${widget.pickupLat},${widget.pickupLng}'
              '&destination=${Uri.encodeComponent(widget.destination)}'
              '&mode=driving&key=$googleMapsApiKey',
            ),
          );
          final json = jsonDecode(res.body);
          final routes = json['routes'] as List?;
          if (routes != null && routes.isNotEmpty) {
            distKm =
                (routes[0]['legs'][0]['distance']['value'] as num).toDouble() /
                1000;
          }
        } catch (_) {}
      }

      final estimatedFare = distKm < shortThresholdKm
          ? shortDistanceFee
          : baseFee + distKm * pricePerKm;
      final distStr = distKm >= 1
          ? '${distKm.toStringAsFixed(1)} km'
          : '${(distKm * 1000).toStringAsFixed(0)} m';

      final rideDoc = await db.collection('rides').doc(widget.rideId).get();
      final passengerName = (rideDoc.data()?['passengerName'] as String? ?? '')
          .trim();
      dev.log(
        '[BOOK] passengerName: $passengerName | distKm: $distKm | estimatedFare: $estimatedFare',
      );

      // Check if driver doc ID matches auth UID
      dev.log(
        '[BOOK] writing notification with uid: ${driver.id} (this must match the driver\'s Firebase Auth UID)',
      );
      final notifRef = await db.collection('notifications').add({
        'uid': driver.id,
        'title': '🚗 New Ride Request',
        'body':
            '${passengerName.isNotEmpty ? passengerName : 'A passenger'} needs a ride\n'
            '📍 Pickup: ${widget.pickup}\n'
            '🏁 Destination: ${widget.destination}\n'
            '📏 Distance: $distStr\n'
            '💰 Estimated Fare: MWK ${estimatedFare.toStringAsFixed(0)}',
        'isRead': false,
        'read': false,
        'target': 'driver',
        'type': 'ride_request',
        'createdAt': FieldValue.serverTimestamp(),
      });
      dev.log('[BOOK] notification written — doc id: ${notifRef.id}');
      if (mounted) {
        if (widget.isScheduled && widget.scheduledAt != null) {
          final dt = widget.scheduledAt!;
          const months = [
            'Jan',
            'Feb',
            'Mar',
            'Apr',
            'May',
            'Jun',
            'Jul',
            'Aug',
            'Sep',
            'Oct',
            'Nov',
            'Dec',
          ];
          final formatted =
              '${dt.day} ${months[dt.month - 1]} ${dt.year}, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.green,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Ride Scheduled!',
                    style: TextStyle(
                      color: _navy,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your ride with ${dd['name'] ?? driver.name} has been scheduled for:',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _navy.withOpacity(0.6),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: _navy,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.schedule_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatted,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'The driver will be notified. You\'ll receive a confirmation once they confirm availability.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _navy.withOpacity(0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _navy,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'Got it',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          );
          if (mounted) Navigator.pop(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ ${driver.name} booked successfully!'),
              backgroundColor: Colors.green.shade700,
              behavior: SnackBarBehavior.floating,
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Booking failed: $e'),
            backgroundColor: _red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  void _fitMapBounds() {
    if (_mapCtrl == null || _pickupLatLng == null) return;
    final positions = [
      _pickupLatLng!,
      ..._drivers.where((d) => d.hasLocation).map((d) => d.position),
    ];
    if (positions.length == 1) {
      _mapCtrl!.animateCamera(CameraUpdate.newLatLngZoom(positions.first, 14));
      return;
    }
    double minLat = positions.first.latitude;
    double maxLat = positions.first.latitude;
    double minLng = positions.first.longitude;
    double maxLng = positions.first.longitude;
    for (final p in positions) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _mapCtrl!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat - 0.01, minLng - 0.01),
          northeast: LatLng(maxLat + 0.01, maxLng + 0.01),
        ),
        80,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: _cream,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Map ──────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _pickupLatLng ?? const LatLng(-13.9626, 33.7741),
              zoom: 13,
            ),
            onMapCreated: (c) {
              _mapCtrl = c;
              if (_pickupLatLng != null) _fitMapBounds();
            },
            markers: _markers,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
          ),

          // ── Back button ──────────────────────────────────
          Positioned(
            top: topPad + 8,
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
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: _navy,
                  size: 20,
                ),
              ),
            ),
          ),

          // ── Route label pill ─────────────────────────────
          Positioned(
            top: topPad + 8,
            left: 70,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.location_on_rounded, color: _red, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${widget.pickup} → ${widget.destination}',
                      style: const TextStyle(
                        color: _navy,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Bottom sheet ─────────────────────────────────
          DraggableScrollableSheet(
            initialChildSize: 0.30,
            minChildSize: 0.30,
            maxChildSize: 0.55,
            snap: true,
            snapSizes: const [0.30, 0.55],
            builder: (_, scrollCtrl) => Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 20,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // drag handle
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 6),
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _navy.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  // header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Row(
                      children: [
                        const Text(
                          'Available Drivers',
                          style: TextStyle(
                            color: _navy,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_resolvingPickup)
                          // pulsing dots while locating pickup
                          AnimatedBuilder(
                            animation: _pulseCtrl,
                            builder: (_, _) => Row(
                              children: List.generate(
                                3,
                                (i) => Container(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _navy.withOpacity(
                                      0.2 +
                                          0.6 *
                                              (((_pulseCtrl.value + i * 0.33) %
                                                  1.0)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _navy.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_drivers.where((d) => d.hasLocation).length} nearby',
                              style: const TextStyle(
                                color: _navy,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        const Spacer(),
                        // recenter button
                        GestureDetector(
                          onTap: _fitMapBounds,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: _navy.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.fit_screen_rounded,
                              color: _navy,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // drivers list
                  if (_drivers.isEmpty && _resolvingPickup)
                    _shimmerRow()
                  else if (_drivers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text(
                          'No drivers available nearby',
                          style: TextStyle(
                            color: _navy.withOpacity(0.45),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: 152,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.only(
                          left: 16,
                          right: 16,
                          bottom: bottomPad,
                        ),
                        itemCount: _drivers.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (_, i) => _DriverCard(
                          driver: _drivers[i],
                          isSelected: _drivers[i].id == _selectedDriverId,
                          onTap: _drivers[i].isBusy ? null : () => _onDriverTapped(_drivers[i]),
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

  Widget _shimmerRow() {
    return SizedBox(
      height: 152,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, _) => AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, _) => Container(
            width: 140,
            decoration: BoxDecoration(
              color: Color.lerp(
                const Color(0xFFEEEEEE),
                const Color(0xFFD5D5D5),
                _pulseCtrl.value,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }
}

class _DriverInfo {
  final String id;
  final String name;
  final String car;
  final String plate;
  final double rating;
  final double distKm;
  final int etaMin;
  final String? photoUrl;
  final LatLng position;
  final bool hasLocation;
  final bool isBusy;

  const _DriverInfo({
    required this.id,
    required this.name,
    required this.car,
    required this.plate,
    required this.rating,
    required this.distKm,
    required this.etaMin,
    required this.photoUrl,
    required this.position,
    required this.hasLocation,
    this.isBusy = false,
  });
}

class _DriverCard extends StatelessWidget {
  final _DriverInfo driver;
  final bool isSelected;
  final VoidCallback? onTap;
  const _DriverCard({
    required this.driver,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 140,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: driver.isBusy
              ? _red
              : isSelected ? _navy.withOpacity(0.07) : _cream,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: driver.isBusy
                ? _red
                : isSelected ? _navy : _navy.withOpacity(0.07),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: driver.isBusy
                        ? Colors.white.withOpacity(0.2)
                        : _navy.withOpacity(0.1),
                    image: driver.photoUrl != null
                        ? DecorationImage(
                            image: NetworkImage(driver.photoUrl!),
                            fit: BoxFit.cover,
                            colorFilter: driver.isBusy
                                ? ColorFilter.mode(
                                    _red.withOpacity(0.5),
                                    BlendMode.darken,
                                  )
                                : null,
                          )
                        : null,
                  ),
                  child: driver.photoUrl == null
                      ? Center(
                          child: Text(
                            driver.name.isNotEmpty
                                ? driver.name[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        )
                      : null,
                ),
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: driver.isBusy ? Colors.white : Colors.green,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      driver.isBusy ? 'Busy' : 'Free',
                      style: TextStyle(
                        color: driver.isBusy ? _red : Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              driver.name,
              style: TextStyle(
                color: driver.isBusy ? Colors.white : _navy,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              [driver.car, driver.plate].where((s) => s.isNotEmpty).join(' • '),
              style: TextStyle(
                color: driver.isBusy
                    ? Colors.white.withOpacity(0.7)
                    : _navy.withOpacity(0.5),
                fontSize: 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
                const SizedBox(width: 2),
                Text(
                  driver.rating > 0 ? driver.rating.toStringAsFixed(1) : 'New',
                  style: TextStyle(
                    color: driver.isBusy ? Colors.white : _navy,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: driver.isBusy
                    ? Colors.white.withOpacity(0.2)
                    : driver.hasLocation ? _navy : _navy.withOpacity(0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                driver.isBusy
                    ? 'On Trip'
                    : driver.hasLocation
                        ? '${driver.etaMin} min • ${driver.distKm.toStringAsFixed(1)} km'
                        : 'Locating...',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color? iconColor;
  const _StatPill({
    required this.icon,
    required this.label,
    required this.sublabel,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: _navy.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: iconColor ?? _navy, size: 18),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: _navy,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            Text(
              sublabel,
              style: TextStyle(color: _navy.withOpacity(0.45), fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
