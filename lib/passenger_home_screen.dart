import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'map_service.dart';
import 'db.dart';
import 'edit_profile_screen.dart';
import 'help_center_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';
import 'notifications_screen.dart';
import 'sos_screen.dart';
import 'available_drivers_screen.dart';
import 'ride_tracking_screen.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class PassengerHomeScreen extends StatefulWidget {
  const PassengerHomeScreen({super.key});

  @override
  State<PassengerHomeScreen> createState() => _PassengerHomeScreenState();
}

class _PassengerHomeScreenState extends State<PassengerHomeScreen> {
  String _name = '';
  String? _photoUrl;
  Map<String, dynamic>? _profileData;
  bool _hasNotification = false;
  int _currentIndex = 0;
  StreamSubscription? _notifSub;
  StreamSubscription? _activeRideSub;
  Map<String, dynamic>? _activeRide;
  String? _activeRideId;

  // map & search
  GoogleMapController? _mapCtrl;
  static const _defaultTarget = LatLng(-13.9626, 33.7741);
  LatLng? _currentPosition;
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _suggestions = [];
  bool _searching = false;
  Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _loadUser();
    _listenNotifications();
    _listenActiveRide();
    _initLocation();
  }

  Future<void> _initLocation() async {
    final pos = await MapService.getCurrentPosition();
    if (pos != null && mounted) {
      setState(() => _currentPosition = LatLng(pos.latitude, pos.longitude));
      _mapCtrl?.animateCamera(
        CameraUpdate.newLatLngZoom(_currentPosition!, 15),
      );
    }
  }

  Future<void> _searchPlaces(String query) async {
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final res = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
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
        setState(() {
          _suggestions = (data['suggestions'] as List? ?? [])
              .map(
                (s) => {
                  'placeId': s['placePrediction']['placeId'] as String,
                  'description': s['placePrediction']['text']['text'] as String,
                },
              )
              .toList()
              .cast<Map<String, dynamic>>();
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _selectPlace(String placeId, String description) async {
    _searchCtrl.text = description;
    setState(() => _suggestions = []);
    final res = await http.get(
      Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json?place_id=$placeId&key=$geocodingApiKey',
      ),
    );
    final data = jsonDecode(res.body);
    final loc = data['results']?[0]?['geometry']?['location'];
    if (loc == null) return;
    final target = LatLng(loc['lat'], loc['lng']);
    setState(() {
      _markers = {
        Marker(
          markerId: const MarkerId('destination'),
          position: target,
          infoWindow: InfoWindow(title: description),
        ),
      };
    });
    _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
  }

  void _listenNotifications() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // listen to broadcast unread
    _notifSub = db
        .collection('notifications')
        .where('target', isEqualTo: 'all')
        .where('isRead', isEqualTo: false)
        .snapshots()
        .listen((snap) {
          if (mounted) setState(() => _hasNotification = snap.docs.isNotEmpty);
        });
  }

  void _listenActiveRide() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _activeRideSub = db
        .collection('rides')
        .where('passengerId', isEqualTo: uid)
        .where(
          'status',
          whereIn: ['pending', 'requested', 'accepted', 'in_trip'],
        )
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          if (snap.docs.isNotEmpty) {
            setState(() {
              _activeRide = snap.docs.first.data();
              _activeRideId = snap.docs.first.id;
            });
          } else {
            // check if the last ride just completed and needs rating
            final prevId = _activeRideId;
            setState(() {
              _activeRide = null;
              _activeRideId = null;
            });
            if (prevId != null) {
              db.collection('rides').doc(prevId).get().then((doc) {
                if (!mounted) return;
                final data = doc.data();
                if (data == null) return;
                if (data['status'] == 'completed' &&
                    data['passengerId'] == FirebaseAuth.instance.currentUser?.uid &&
                    (data['passengerRating'] == null ||
                        data['passengerRating'] == 0)) {
                  _showRatingPrompt(prevId, data);
                }
              });
            }
          }
        });
  }

  void _showRatingPrompt(String rideId, Map<String, dynamic> d) {
    int rating = 0;
    bool submitting = false;
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              MediaQuery.of(ctx).padding.bottom + 20,
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
                  'How was your ride with ${d['driverName'] ?? 'your driver'}?',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _navy.withOpacity(0.5), fontSize: 13),
                ),
                if ((d['finalFare'] as num?) != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: _navy,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Amount Paid',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'MWK ${(d['finalFare'] as num).toStringAsFixed(0)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 28,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    5,
                    (i) => GestureDetector(
                      onTap: () => setSheet(() => rating = i + 1),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                          i < rating
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: i < rating
                              ? Colors.amber
                              : Colors.grey.shade300,
                          size: 40,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: submitting || rating == 0
                        ? null
                        : () async {
                            setSheet(() => submitting = true);
                            await db.collection('rides').doc(rideId).update({
                              'passengerRating': rating,
                            });
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade200,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: submitting
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
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Skip',
                    style: TextStyle(color: _navy.withOpacity(0.4)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    _activeRideSub?.cancel();
    _searchCtrl.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc = await db.collection('users').doc(uid).get();
    if (doc.exists && mounted) {
      setState(() {
        _name = doc.data()?['name'] ?? '';
        _photoUrl = doc.data()?['photoUrl'];
        _profileData = doc.data();
      });
    }
  }

  void _showSosDialog(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SosScreen()),
    );
  }

  void _showScheduleDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.schedule_rounded, color: _navy),
            SizedBox(width: 8),
            Text(
              'Schedule a Ride',
              style: TextStyle(color: _navy, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: const Text(
          'Schedule booking coming soon.',
          style: TextStyle(color: _navy),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: _navy)),
          ),
        ],
      ),
    );
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  Widget _buildHeader() {
    final onMap = _currentIndex == 0;
    final textColor = onMap ? Colors.white : _navy;
    final subColor = onMap ? Colors.white70 : _navy.withOpacity(0.5);
    final iconColor = onMap ? Colors.white : _navy;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_greeting, style: TextStyle(fontSize: 14, color: subColor)),
            Text(
              _name.isNotEmpty ? _name.split(' ').first : 'there',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Stack(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.notifications_outlined,
                    color: iconColor,
                    size: 28,
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NotificationsScreen(),
                    ),
                  ),
                ),
                if (_hasNotification)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: IgnorePointer(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: _red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _currentIndex = 3),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: onMap
                      ? Colors.white.withOpacity(0.15)
                      : _navy.withOpacity(0.1),
                  border: Border.all(
                    color: onMap
                        ? Colors.white.withOpacity(0.4)
                        : _navy.withOpacity(0.15),
                    width: 2,
                  ),
                  image: _photoUrl != null
                      ? DecorationImage(
                          image: NetworkImage(_photoUrl!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: _photoUrl == null
                    ? Center(
                        child: Text(
                          _name.isNotEmpty ? _name[0].toUpperCase() : '?',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: onMap ? Colors.white : _navy,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> get _pages => [
    _HomePage(
      onMapCreated: (c) {
        _mapCtrl?.dispose();
        _mapCtrl = c;
      },
      onMapDisposed: () => _mapCtrl = null,
      currentPosition: _currentPosition,
      markers: _markers,
      defaultTarget: _defaultTarget,
    ),
    const _RideHistoryPage(),
    _BookPage(onBooked: () => setState(() => _currentIndex = 0)),
    _ProfilePage(data: _profileData, onUpdated: _loadUser),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: Stack(
        children: [
          // Full-screen content
          if (_currentIndex == 0)
            Positioned.fill(child: _pages[0])
          else
            Positioned.fill(
              child: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    if (_currentIndex != 3 && _currentIndex != 2)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: _buildHeader(),
                      ),
                    Expanded(child: _pages[_currentIndex]),
                  ],
                ),
              ),
            ),

          // Overlay header + search bar (home tab only)
          if (_currentIndex == 0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: false,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.55),
                        Colors.black.withOpacity(0.25),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 14),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: _navy.withOpacity(0.07),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: TextField(
                              controller: _searchCtrl,
                              onChanged: (q) {
                                setState(
                                  () {},
                                ); // rebuild to show/hide clear button
                                _searchPlaces(q);
                              },
                              style: const TextStyle(
                                color: _navy,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Search location...',
                                hintStyle: TextStyle(
                                  color: _navy.withOpacity(0.35),
                                  fontSize: 14,
                                ),
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  color: _navy.withOpacity(0.4),
                                ),
                                suffixIcon: _searchCtrl.text.isNotEmpty
                                    ? IconButton(
                                        icon: Icon(
                                          Icons.close_rounded,
                                          color: _navy.withOpacity(0.4),
                                          size: 18,
                                        ),
                                        onPressed: () {
                                          _searchCtrl.clear();
                                          setState(() => _suggestions = []);
                                          FocusScope.of(context).unfocus();
                                        },
                                      )
                                    : _searching
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
                                    : Icon(
                                        Icons.my_location_rounded,
                                        color: _red.withOpacity(0.8),
                                        size: 20,
                                      ),
                                filled: true,
                                fillColor: Colors.white,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          if (_suggestions.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: _navy.withOpacity(0.07),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _suggestions.length > 5
                                    ? 5
                                    : _suggestions.length,
                                separatorBuilder: (_, __) => Divider(
                                  height: 1,
                                  color: _navy.withOpacity(0.07),
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
                                      style: const TextStyle(
                                        color: _navy,
                                        fontSize: 13,
                                      ),
                                    ),
                                    onTap: () {
                                      FocusScope.of(context).unfocus();
                                      _selectPlace(
                                        s['placeId'],
                                        s['description'],
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          // transparent spacer so touches below pass to map
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Centre (my location) button
          if (_currentIndex == 0)
            Positioned(
              right: 16,
              bottom: 300,
              child: GestureDetector(
                onTap: () async {
                  if (_currentPosition != null) {
                    _mapCtrl?.animateCamera(
                      CameraUpdate.newLatLngZoom(_currentPosition!, 15),
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
                        color: Colors.black.withOpacity(0.18),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.my_location_rounded,
                    color: _navy,
                    size: 22,
                  ),
                ),
              ),
            ),

          // Bottom nav + quick action always on top
          if (_currentIndex != 2)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_currentIndex == 0) ...[
                    if (_activeRide != null && _activeRideId != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: _ActiveRideBanner(
                          ride: _activeRide!,
                          rideId: _activeRideId!,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => RideTrackingScreen(
                                rideId: _activeRideId!,
                                pickup: _activeRide!['pickup'] ?? '',
                                destination: _activeRide!['destination'] ?? '',
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _QuickActionCard(
                          onBook: () => setState(() => _currentIndex = 2),
                          onSos: () => _showSosDialog(context),
                          onSchedule: () => _showScheduleDialog(context),
                        ),
                      ),
                  ],
                  _BottomNav(
                    currentIndex: _currentIndex,
                    onTap: (i) => setState(() => _currentIndex = i),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Pages ──────────────────────────────────────────────
class _HomePage extends StatefulWidget {
  final void Function(GoogleMapController) onMapCreated;
  final VoidCallback onMapDisposed;
  final LatLng? currentPosition;
  final Set<Marker> markers;
  final LatLng defaultTarget;

  const _HomePage({
    required this.onMapCreated,
    required this.onMapDisposed,
    required this.currentPosition,
    required this.markers,
    required this.defaultTarget,
  });

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  @override
  void dispose() {
    widget.onMapDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: widget.currentPosition ?? widget.defaultTarget,
        zoom: 15,
      ),
      onMapCreated: widget.onMapCreated,
      markers: widget.markers,
      myLocationEnabled: true,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapType: MapType.normal,
    );
  }
}

class _RideHistoryPage extends StatefulWidget {
  const _RideHistoryPage();
  @override
  State<_RideHistoryPage> createState() => _RideHistoryPageState();
}

class _RideHistoryPageState extends State<_RideHistoryPage> {
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return StreamBuilder<QuerySnapshot>(
      stream: db
          .collection('rides')
          .where('passengerId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: _navy));
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.directions_car_outlined,
                  size: 56,
                  color: _navy.withOpacity(0.2),
                ),
                const SizedBox(height: 12),
                Text(
                  'No rides yet',
                  style: TextStyle(color: _navy.withOpacity(0.4), fontSize: 15),
                ),
              ],
            ),
          );
        }
        final docs = snapshot.data!.docs;
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            final ts = (d['createdAt'] as Timestamp?)?.toDate();
            final status = (d['status'] ?? '') as String;
            final distKm = (d['tripDistanceKm'] as num?)?.toDouble();
            final fare = (d['finalFare'] as num?)?.toDouble();
            final rating = (d['passengerRating'] as num?)?.toInt() ?? 0;
            final isCompleted = status == 'completed';
            final canRate = isCompleted && rating == 0;
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '${d['pickup'] ?? ''} → ${d['destination'] ?? ''}',
                          style: const TextStyle(
                            color: _navy,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isCompleted
                              ? Colors.green.withOpacity(0.1)
                              : _red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          status.isNotEmpty
                              ? status[0].toUpperCase() + status.substring(1)
                              : '',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isCompleted ? Colors.green.shade700 : _red,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _rideDetail(
                          Icons.person_outline,
                          d['driverName'] ?? '',
                        ),
                      ),
                      Expanded(
                        child: _rideDetail(
                          Icons.directions_car_outlined,
                          d['driverCar'] ?? '',
                        ),
                      ),
                    ],
                  ),
                  if (distKm != null || fare != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (distKm != null)
                          Expanded(
                            child: _rideDetail(
                              Icons.straighten_outlined,
                              distKm >= 1
                                  ? '${distKm.toStringAsFixed(1)} km'
                                  : '${(distKm * 1000).toStringAsFixed(0)} m',
                            ),
                          ),
                        if (fare != null)
                          Expanded(
                            child: _rideDetail(
                              Icons.payments_outlined,
                              'MWK ${fare.toStringAsFixed(0)}',
                              color: Colors.green,
                            ),
                          ),
                        if (rating > 0)
                          _rideDetail(
                            Icons.star_rounded,
                            '$rating ★',
                            color: Colors.amber,
                          ),
                      ],
                    ),
                  ],
                  if (ts != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _formatDate(ts),
                      style: TextStyle(
                        fontSize: 11,
                        color: _navy.withOpacity(0.35),
                      ),
                    ),
                  ],
                  if (canRate) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _showRatingSheet(context, docs[i].id, d),
                        icon: const Icon(
                          Icons.star_outline_rounded,
                          size: 16,
                          color: _navy,
                        ),
                        label: const Text(
                          'Rate this ride',
                          style: TextStyle(color: _navy),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: _navy.withOpacity(0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showRatingSheet(
    BuildContext context,
    String rideId,
    Map<String, dynamic> d,
  ) {
    final fare = (d['finalFare'] as num?)?.toDouble() ?? 0;
    int rating = 0;
    bool submitting = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              MediaQuery.of(ctx).padding.bottom + 20,
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
                const SizedBox(height: 16),
                const Icon(Icons.star_rounded, color: Colors.amber, size: 40),
                const SizedBox(height: 8),
                Text(
                  'Rate your ride with ${d['driverName'] ?? 'the driver'}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _navy,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (fare > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    'MWK ${fare.toStringAsFixed(0)} paid',
                    style: TextStyle(
                      color: _navy.withOpacity(0.5),
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    5,
                    (i) => GestureDetector(
                      onTap: () => setSheet(() => rating = i + 1),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                          i < rating
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: i < rating
                              ? Colors.amber
                              : Colors.grey.shade300,
                          size: 40,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: submitting || rating == 0
                        ? null
                        : () async {
                            setSheet(() => submitting = true);
                            await db.collection('rides').doc(rideId).update({
                              'passengerRating': rating,
                            });
                            if (ctx.mounted) Navigator.pop(ctx);
                            setState(() {});
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade200,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: submitting
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
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Skip',
                    style: TextStyle(color: _navy.withOpacity(0.4)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rideDetail(IconData icon, String text, {Color color = _navy}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color.withOpacity(0.6)),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: _navy.withOpacity(0.6)),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );

  String _formatDate(DateTime dt) {
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
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _BookPage extends StatefulWidget {
  final VoidCallback onBooked;
  const _BookPage({required this.onBooked});
  @override
  State<_BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<_BookPage> {
  final _pickupCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  bool _loading = false;
  bool _locating = false;
  double? _pickupLat;
  double? _pickupLng;

  // places search
  TextEditingController? _activeCtrl;
  List<Map<String, dynamic>> _suggestions = [];
  bool _searching = false;
  List<Map<String, dynamic>> _favourites = [];

  @override
  void initState() {
    super.initState();
    _loadFavourites();
  }

  Future<void> _loadFavourites() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snap = await db
        .collection('users')
        .doc(uid)
        .collection('favourites')
        .orderBy('createdAt', descending: true)
        .get();
    if (mounted) {
      setState(
        () => _favourites = snap.docs
            .map((d) => {'id': d.id, ...d.data()})
            .toList(),
      );
    }
  }

  Future<void> _saveFavourite(String name) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await db.collection('users').doc(uid).collection('favourites').add({
      'name': name,
      'createdAt': FieldValue.serverTimestamp(),
    });
    _loadFavourites();
  }

  Future<void> _deleteFavourite(String id) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await db
        .collection('users')
        .doc(uid)
        .collection('favourites')
        .doc(id)
        .delete();
    _loadFavourites();
  }

  void _onFavouriteTapped(String name) {
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
                const Icon(Icons.star_rounded, color: Colors.amber, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
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
            const Text(
              'Use this location as:',
              style: TextStyle(color: _navy, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _pickupCtrl.text = name;
                    },
                    icon: const Icon(
                      Icons.my_location_rounded,
                      color: _navy,
                      size: 16,
                    ),
                    label: const Text('Pickup', style: TextStyle(color: _navy)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: _navy.withOpacity(0.3)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _destCtrl.text = name;
                    },
                    icon: const Icon(
                      Icons.location_on_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                    label: const Text('Destination'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _navy,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
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

  @override
  void dispose() {
    _pickupCtrl.dispose();
    _destCtrl.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final pos = await MapService.getCurrentPosition();
      if (pos == null) return;
      _pickupLat = pos.latitude;
      _pickupLng = pos.longitude;

      // Try street-level first, fall back to any result
      String? address;
      for (final resultType in ['street_address', 'route', '']) {
        final query = resultType.isEmpty
            ? '?latlng=${pos.latitude},${pos.longitude}&key=$geocodingApiKey'
            : '?latlng=${pos.latitude},${pos.longitude}&result_type=$resultType&key=$geocodingApiKey';
        final res = await http.get(
          Uri.parse('https://maps.googleapis.com/maps/api/geocode/json$query'),
        );
        final data = jsonDecode(res.body);
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          address = results[0]['formatted_address'] as String?;
          break;
        }
      }

      if (mounted) {
        _pickupCtrl.text =
            address ??
            '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}';
        setState(() => _suggestions = []);
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _searchPlaces(String query, TextEditingController ctrl) async {
    _activeCtrl = ctrl;
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final res = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
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
        setState(() {
          _suggestions = (data['suggestions'] as List? ?? [])
              .map(
                (s) => {
                  'placeId': s['placePrediction']['placeId'] as String,
                  'description': s['placePrediction']['text']['text'] as String,
                },
              )
              .toList()
              .cast<Map<String, dynamic>>();
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _selectPlace(String placeId, String description) async {
    _activeCtrl?.text = description;
    setState(() => _suggestions = []);
    FocusScope.of(context).unfocus();
    // geocode to get lat/lng so we don't need to do it again later
    if (_activeCtrl == _pickupCtrl) {
      try {
        final res = await http.get(
          Uri.parse(
            'https://maps.googleapis.com/maps/api/geocode/json'
            '?place_id=$placeId&key=$geocodingApiKey',
          ),
        );
        final data = jsonDecode(res.body);
        final loc = data['results']?[0]?['geometry']?['location'];
        if (loc != null) {
          _pickupLat = (loc['lat'] as num).toDouble();
          _pickupLng = (loc['lng'] as num).toDouble();
        }
      } catch (_) {}
    }
    // offer to save as favourite
    final alreadySaved = _favourites.any((f) => f['name'] == description);
    if (!alreadySaved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Save this location as a favourite?'),
          action: SnackBarAction(
            label: '★ Save',
            onPressed: () => _saveFavourite(description),
          ),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _submit() async {
    final pickup = _pickupCtrl.text.trim();
    final dest = _destCtrl.text.trim();
    if (pickup.isEmpty || dest.isEmpty) return;

    setState(() => _loading = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final userDoc = await db.collection('users').doc(uid).get();
      final name = (userDoc.data() as Map<String, dynamic>?)?['name'] ?? '';
      final phone = (userDoc.data() as Map<String, dynamic>?)?['phone'] ?? '';

      final rideRef = await db.collection('rides').add({
        'passengerId': uid,
        'passengerName': name,
        'passengerPhone': phone,
        'pickup': pickup,
        'destination': dest,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        if (_pickupLat != null) 'pickupLat': _pickupLat,
        if (_pickupLng != null) 'pickupLng': _pickupLng,
        if (_pickupLat != null && _pickupLng != null)
          'pickupLocation': GeoPoint(_pickupLat!, _pickupLng!),
      });

      _pickupCtrl.clear();
      _destCtrl.clear();

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AvailableDriversScreen(
              rideId: rideRef.id,
              pickup: pickup,
              destination: dest,
              pickupLat: _pickupLat,
              pickupLng: _pickupLng,
            ),
          ),
        ).then((_) => widget.onBooked());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top bar with back button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: _navy),
                onPressed: () => widget.onBooked(),
              ),
              const Text(
                'Book a Ride',
                style: TextStyle(
                  color: _navy,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Pickup field
                _SearchField(
                  controller: _pickupCtrl,
                  hint: 'Pickup location',
                  icon: Icons.my_location_rounded,
                  isSearching: _searching && _activeCtrl == _pickupCtrl,
                  onChanged: (q) => _searchPlaces(q, _pickupCtrl),
                ),
                if (_suggestions.isNotEmpty && _activeCtrl == _pickupCtrl)
                  _SuggestionsList(
                    suggestions: _suggestions,
                    onTap: _selectPlace,
                  ),
                const SizedBox(height: 12),
                // Destination field
                _SearchField(
                  controller: _destCtrl,
                  hint: 'Destination',
                  icon: Icons.location_on_rounded,
                  isSearching: _searching && _activeCtrl == _destCtrl,
                  onChanged: (q) => _searchPlaces(q, _destCtrl),
                ),
                if (_suggestions.isNotEmpty && _activeCtrl == _destCtrl)
                  _SuggestionsList(
                    suggestions: _suggestions,
                    onTap: _selectPlace,
                  ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _locating ? null : _useCurrentLocation,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _navy.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _navy.withOpacity(0.12)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _locating
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _navy,
                                ),
                              )
                            : const Icon(
                                Icons.my_location_rounded,
                                color: _navy,
                                size: 16,
                              ),
                        const SizedBox(width: 8),
                        Text(
                          _locating
                              ? 'Getting location...'
                              : 'Use current location as pickup',
                          style: TextStyle(
                            color: _navy.withOpacity(0.8),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Colors.blue.shade700,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Fare will be calculated automatically based on distance',
                          style: TextStyle(
                            color: Colors.blue.shade700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // ── Favourites ──
                if (_favourites.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: Colors.amber,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Favourite Locations',
                        style: TextStyle(
                          color: _navy,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...(_favourites.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => _onFavouriteTapped(f['name'] as String),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _navy.withOpacity(0.08)),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                color: Colors.amber,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  f['name'] as String,
                                  style: const TextStyle(
                                    color: _navy,
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              GestureDetector(
                                onTap: () =>
                                    _deleteFavourite(f['id'] as String),
                                child: Icon(
                                  Icons.close_rounded,
                                  color: _navy.withOpacity(0.3),
                                  size: 16,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )),
                ],
              ],
            ),
          ),
        ),
        // Button at bottom
        Container(
          padding: EdgeInsets.fromLTRB(
            24,
            16,
            24,
            MediaQuery.of(context).padding.bottom + 16,
          ),
          decoration: BoxDecoration(
            color: _cream,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 12,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _navy,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Request Ride',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType keyboardType;
  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType = TextInputType.text,
  });
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: _navy, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _navy.withOpacity(0.35)),
        prefixIcon: Icon(icon, color: _navy.withOpacity(0.5), size: 20),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool isSearching;
  final ValueChanged<String> onChanged;
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.icon,
    required this.isSearching,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: _navy, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _navy.withOpacity(0.35)),
        prefixIcon: Icon(icon, color: _navy.withOpacity(0.5), size: 20),
        suffixIcon: isSearching
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
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _SuggestionsList extends StatelessWidget {
  final List<Map<String, dynamic>> suggestions;
  final Future<void> Function(String, String) onTap;
  const _SuggestionsList({required this.suggestions, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: _navy.withOpacity(0.07),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: suggestions.length > 5 ? 5 : suggestions.length,
        separatorBuilder: (_, __) =>
            Divider(height: 1, color: _navy.withOpacity(0.07)),
        itemBuilder: (_, i) {
          final s = suggestions[i];
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
            onTap: () => onTap(s['placeId'], s['description']),
          );
        },
      ),
    );
  }
}

class _ProfilePage extends StatefulWidget {
  final Map<String, dynamic>? data;
  final VoidCallback onUpdated;

  const _ProfilePage({required this.data, required this.onUpdated});

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  int _totalRides = 0;
  double _avgRating = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final rides = await db
          .collection('rides')
          .where('passengerId', isEqualTo: uid)
          .get();
      final completed = rides.docs
          .where((r) => (r.data()['status'] ?? '') == 'completed')
          .toList();
      double ratingSum = 0;
      for (var r in completed) {
        ratingSum += (r.data()['passengerRating'] ?? 0).toDouble();
      }
      if (mounted)
        setState(() {
          _totalRides = completed.length;
          _avgRating = completed.isNotEmpty ? ratingSum / completed.length : 0;
        });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data == null) {
      return const Center(child: CircularProgressIndicator(color: _navy));
    }

    final name = widget.data!['name'] ?? '';
    final email = widget.data!['email'] ?? '';
    final phone = widget.data!['phone'] ?? '';
    final photoUrl = widget.data!['photoUrl'];
    final createdAt = (widget.data!['createdAt'] as Timestamp?)?.toDate();
    final memberSince = createdAt != null
        ? '${_monthName(createdAt.month)} ${createdAt.year}'
        : 'N/A';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 16),

          // Avatar
          Center(
            child: GestureDetector(
              onTap: () {
                if (photoUrl == null) return;
                showDialog(
                  context: context,
                  builder: (_) => Dialog(
                    backgroundColor: Colors.transparent,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.network(photoUrl, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                );
              },
              child: Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _navy.withOpacity(0.1),
                  border: Border.all(color: _navy.withOpacity(0.2), width: 2),
                  image: photoUrl != null
                      ? DecorationImage(
                          image: NetworkImage(photoUrl),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: photoUrl == null
                    ? Center(
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: _navy,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ),

          const SizedBox(height: 12),

          Text(
            name,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: _navy,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            phone,
            style: TextStyle(fontSize: 14, color: _navy.withOpacity(0.5)),
          ),
          if (email.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              email,
              style: TextStyle(fontSize: 14, color: _navy.withOpacity(0.5)),
            ),
          ],

          const SizedBox(height: 16),

          // Edit profile button
          SizedBox(
            width: 160,
            height: 42,
            child: OutlinedButton.icon(
              onPressed: () async {
                final updated = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EditProfileScreen(
                      name: name,
                      phone: phone,
                      photoUrl: photoUrl,
                    ),
                  ),
                );
                if (updated == true) widget.onUpdated();
              },
              icon: const Icon(Icons.edit_outlined, size: 16, color: _navy),
              label: const Text('Edit Profile', style: TextStyle(color: _navy)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _navy.withOpacity(0.3)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 28),

          // Account summary
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _SummaryItem(
                  value: '$_totalRides',
                  label: 'Total Rides',
                  icon: Icons.directions_car_rounded,
                ),
                _divider(),
                _SummaryItem(
                  value: memberSince,
                  label: 'Member Since',
                  icon: Icons.calendar_today_outlined,
                ),
                _divider(),
                _SummaryItem(
                  value: _avgRating > 0 ? _avgRating.toStringAsFixed(1) : 'N/A',
                  label: 'Avg Rating',
                  icon: Icons.star_rounded,
                  iconColor: Colors.amber,
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Settings tile
          _ProfileTile(
            icon: Icons.settings_outlined,
            title: 'Settings',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(height: 10),

          // Help Center tile
          _ProfileTile(
            icon: Icons.help_outline_rounded,
            title: 'Help Center',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HelpCenterScreen()),
            ),
          ),
          const SizedBox(height: 10),

          // Logout tile
          _ProfileTile(
            icon: Icons.logout_rounded,
            title: 'Logout',
            iconColor: _red,
            titleColor: _red,
            onTap: () => _confirmLogout(context),
          ),

          const SizedBox(height: 100),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Logout',
          style: TextStyle(color: _navy, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Are you sure you want to logout?',
          style: TextStyle(color: _navy),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: _navy.withOpacity(0.6)),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (_) => false,
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Container(height: 40, width: 1, color: _navy.withOpacity(0.1));

  String _monthName(int month) {
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
    return months[month - 1];
  }
}

class _SummaryItem extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color iconColor;

  const _SummaryItem({
    required this.value,
    required this.label,
    required this.icon,
    this.iconColor = _navy,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 22),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: _navy,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: _navy.withOpacity(0.5)),
        ),
      ],
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Color iconColor;
  final Color titleColor;

  const _ProfileTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.iconColor = _navy,
    this.titleColor = _navy,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: titleColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: _navy.withOpacity(0.3),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Active Ride Banner ────────────────────────────────
class _ActiveRideBanner extends StatefulWidget {
  final Map<String, dynamic> ride;
  final String rideId;
  final VoidCallback onTap;
  const _ActiveRideBanner({
    required this.ride,
    required this.rideId,
    required this.onTap,
  });
  @override
  State<_ActiveRideBanner> createState() => _ActiveRideBannerState();
}

class _ActiveRideBannerState extends State<_ActiveRideBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  static const _steps = ['requested', 'accepted', 'arrived', 'in_trip'];

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String get _statusLabel {
    switch (widget.ride['status']) {
      case 'pending':
        return 'Selecting driver...';
      case 'requested':
        return 'Calling driver...';
      case 'accepted':
        final phase = widget.ride['tripPhase'] as String? ?? '';
        if (phase == 'arrived') return 'Driver has arrived!';
        return 'Driver is on the way';
      case 'in_trip':
        return 'Trip in progress';
      default:
        return 'Processing...';
    }
  }

  Color get _statusColor {
    switch (widget.ride['status']) {
      case 'requested':
        return Colors.orange;
      case 'accepted':
        final phase = widget.ride['tripPhase'] as String? ?? '';
        if (phase == 'arrived') return Colors.orange;
        return Colors.blue;
      case 'in_trip':
        return Colors.green;
      default:
        return _navy;
    }
  }

  IconData get _statusIcon {
    switch (widget.ride['status']) {
      case 'requested':
        return Icons.search_rounded;
      case 'accepted':
        final phase = widget.ride['tripPhase'] as String? ?? '';
        if (phase == 'arrived') return Icons.place_rounded;
        return Icons.directions_car_rounded;
      case 'in_trip':
        return Icons.navigation_rounded;
      default:
        return Icons.hourglass_top_rounded;
    }
  }

  int get _stepIndex {
    final status = widget.ride['status'] as String? ?? '';
    final phase = widget.ride['tripPhase'] as String? ?? '';
    if (status == 'in_trip') return 3;
    if (phase == 'arrived') return 2;
    if (status == 'accepted') return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor;
    final idx = _stepIndex;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _navy,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
          boxShadow: [
            BoxShadow(
              color: _navy.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // status row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_statusIcon, color: color, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _statusLabel,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 6),
                          FadeTransition(
                            opacity: _pulse,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${widget.ride['pickup'] ?? ''} → ${widget.ride['destination'] ?? ''}',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.white38,
                  size: 13,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // progress bar
            Row(
              children: List.generate(_steps.length * 2 - 1, (i) {
                if (i.isOdd) {
                  final filled = (i ~/ 2) < idx;
                  return Expanded(
                    child: Container(
                      height: 3,
                      color: filled ? color : Colors.white.withOpacity(0.15),
                    ),
                  );
                }
                final dotIdx = i ~/ 2;
                final active = dotIdx == idx;
                final done = dotIdx < idx;
                return FadeTransition(
                  opacity: active ? _pulse : const AlwaysStoppedAnimation(1.0),
                  child: Container(
                    width: active ? 13 : 10,
                    height: active ? 13 : 10,
                    decoration: BoxDecoration(
                      color: done || active
                          ? color
                          : Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                      border: active
                          ? Border.all(color: Colors.white, width: 2)
                          : null,
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            // step labels
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StepLabel('Searching', idx >= 0, color),
                _StepLabel('Accepted', idx >= 1, color),
                _StepLabel('Arrived', idx >= 2, color),
                _StepLabel('On Trip', idx >= 3, color),
              ],
            ),
            if (widget.ride['driverName'] != null) ...[
              const SizedBox(height: 10),
              Divider(color: Colors.white.withOpacity(0.1), height: 1),
              const SizedBox(height: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.person_outline,
                        color: Colors.white54,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.ride['driverName'] ?? '',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(
                        Icons.directions_car_outlined,
                        color: Colors.white54,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.ride['driverCar'] ?? '',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Text(
                        'Tap to track',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ],
            // Cancel button for pending/requested rides
            if (['pending', 'requested'].contains(widget.ride['status'])) ...[
              const SizedBox(height: 10),
              Divider(color: Colors.white.withOpacity(0.1), height: 1),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await db.collection('rides').doc(widget.rideId).update({
                      'status': 'cancelled',
                    });
                  },
                  icon: const Icon(Icons.close_rounded, color: _red, size: 16),
                  label: const Text(
                    'Cancel Ride',
                    style: TextStyle(color: _red, fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _red.withOpacity(0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepLabel extends StatelessWidget {
  final String text;
  final bool active;
  final Color activeColor;
  const _StepLabel(this.text, this.active, this.activeColor);
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: active ? activeColor : Colors.white.withOpacity(0.3),
        fontSize: 9,
        fontWeight: active ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }
}

// ── Quick Action Card ──────────────────────────────────
class _QuickActionCard extends StatelessWidget {
  final VoidCallback onBook;
  final VoidCallback onSos;
  final VoidCallback onSchedule;

  const _QuickActionCard({
    required this.onBook,
    required this.onSos,
    required this.onSchedule,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _navy,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: _navy.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Book Ride row
          GestureDetector(
            onTap: onBook,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.15)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.directions_car_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Book a Ride',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          'Where are you going?',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_ios,
                    color: Colors.white.withOpacity(0.4),
                    size: 13,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // SOS & Schedule
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: onSos,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _red,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.sos_rounded, color: Colors.white, size: 18),
                        SizedBox(width: 6),
                        Text(
                          'SOS',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: onSchedule,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withOpacity(0.15)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          color: Colors.white.withOpacity(0.85),
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Schedule',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.85),
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Bottom Nav ──────────────────────────────────────────
class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  const _BottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: _navy,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: _navy.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _NavItem(
            icon: Icons.home_rounded,
            label: 'Home',
            index: 0,
            currentIndex: currentIndex,
            onTap: onTap,
          ),
          _NavItem(
            icon: Icons.receipt_long_outlined,
            label: 'History',
            index: 1,
            currentIndex: currentIndex,
            onTap: onTap,
          ),
          _NavItem(
            icon: Icons.directions_car_rounded,
            label: 'Book',
            index: 2,
            currentIndex: currentIndex,
            onTap: onTap,
            isCenter: true,
          ),
          _NavItem(
            icon: Icons.person_outline_rounded,
            label: 'Profile',
            index: 3,
            currentIndex: currentIndex,
            onTap: onTap,
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final int index;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isCenter;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.currentIndex,
    required this.onTap,
    this.isCenter = false,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = currentIndex == index;

    if (isCenter) {
      return GestureDetector(
        onTap: () => onTap(index),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isActive ? _red : Colors.white.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 26),
        ),
      );
    }

    return GestureDetector(
      onTap: () => onTap(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.white.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isActive ? Colors.white : Colors.white.withOpacity(0.4),
              size: 22,
            ),
            if (isActive) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
