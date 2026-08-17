import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'db.dart';
import 'edit_profile_screen.dart';
import 'help_center_screen.dart';
import 'settings_screen.dart';
import 'notifications_screen.dart';
import 'sos_screen.dart';
import 'available_drivers_screen.dart';
import 'ride_tracking_screen.dart';
import 'auth_persistence.dart';

const _googleApiKey = 'AIzaSyDHtA496iglb6kibnug_Y_Du4m7G9duNQE';

Future<({double latitude, double longitude})?> _getPosition() async {
  try {
    final pos = await Geolocator.getCurrentPosition();
    return (latitude: pos.latitude, longitude: pos.longitude);
  } catch (_) {
    return null;
  }
}

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
  bool _isOffline = false;
  int _currentIndex = 0;
  StreamSubscription? _notifSub;
  StreamSubscription<bool>? _connectivitySub;
  StreamSubscription? _notifPersonalSub;
  StreamSubscription? _notifUserIdSub;
  StreamSubscription? _activeRideSub;
  StreamSubscription? _scheduledRideSub;
  Timer? _searchDebounce;
  final Map<String, Timer> _autoStartTimers = {};
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

  // Notifiers so _HomePage is never recreated on setState
  final _positionNotifier = ValueNotifier<LatLng?>(null);
  final _markersNotifier = ValueNotifier<Set<Marker>>({});

  @override
  void initState() {
    super.initState();
    _loadUser();
    _listenNotifications();
    _listenActiveRide();
    _listenScheduledRides();
    _initLocation();
    _initConnectivity();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _notifSub?.cancel();
    _notifPersonalSub?.cancel();
    _notifUserIdSub?.cancel();
    _activeRideSub?.cancel();
    _scheduledRideSub?.cancel();
    for (final t in _autoStartTimers.values) {
      t.cancel();
    }
    _autoStartTimers.clear();
    _searchDebounce?.cancel();
    _mapCtrl?.dispose();
    super.dispose();
  }

  Future<void> _initConnectivity() async {
    _connectivitySub = AuthPersistence.connectionStatusStream().listen((
      isOnline,
    ) {
      if (!mounted) return;
      setState(() => _isOffline = !isOnline);
    });
    final isOnline = await AuthPersistence.hasInternetConnection();
    if (mounted) {
      setState(() => _isOffline = !isOnline);
    }
  }

  Future<void> _initLocation() async {
    final pos = await _getPosition();
    if (pos != null && mounted) {
      _currentPosition = LatLng(pos.latitude, pos.longitude);
      _positionNotifier.value = _currentPosition;
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
          'X-Goog-Api-Key': _googleApiKey,
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
        'https://maps.googleapis.com/maps/api/geocode/json?place_id=$placeId&key=$_googleApiKey',
      ),
    );
    final data = jsonDecode(res.body);
    final loc = data['results']?[0]?['geometry']?['location'];
    if (loc == null) return;
    final target = LatLng(loc['lat'], loc['lng']);
    _markers = {
      Marker(
        markerId: const MarkerId('destination'),
        position: target,
        infoWindow: InfoWindow(title: description),
      ),
    };
    _markersNotifier.value = _markers;
    _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
  }

  void _listenNotifications() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final broadcastTargets = [
      'all',
      'All',
      'passengers',
      'Passengers',
      'passenger',
      'Passenger',
      'drivers',
      'Drivers',
      'driver',
      'Driver',
    ];
    // broadcast notifications
    _notifSub = db
        .collection('notifications')
        .where('target', whereIn: broadcastTargets)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .listen((snap) {
          final hasUnread = snap.docs.any((doc) {
            final data = doc.data();
            final type = (data['type'] as String?)?.toLowerCase().trim() ?? '';
            final title =
                (data['title'] as String?)?.toLowerCase().trim() ?? '';
            final isRideRequest =
                title.contains('ride request') ||
                title.contains('new ride request');
            final allowed =
                type.isEmpty ||
                type == 'notification' ||
                type == 'ticket_reply';
            return !isRideRequest && allowed;
          });
          if (mounted && hasUnread) setState(() => _hasNotification = true);
        }, onError: (_) {});
    // personal notifications
    _notifPersonalSub = db
        .collection('notifications')
        .where('uid', isEqualTo: uid)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .listen((snap) {
          final hasUnread = snap.docs.any((doc) {
            final data = doc.data();
            final type = (data['type'] as String?)?.toLowerCase().trim() ?? '';
            return type.isEmpty ||
                type == 'notification' ||
                type == 'ticket_reply';
          });
          if (mounted && hasUnread) setState(() => _hasNotification = true);
        }, onError: (_) {});

    _notifUserIdSub = db
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .listen((snap) {
          final hasUnread = snap.docs.any((doc) {
            final data = doc.data();
            final type = (data['type'] as String?)?.toLowerCase().trim() ?? '';
            return type.isEmpty ||
                type == 'notification' ||
                type == 'ticket_reply';
          });
          if (mounted && hasUnread) setState(() => _hasNotification = true);
        }, onError: (_) {});
  }

  void _listenScheduledRides() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _scheduledRideSub = db
        .collection('rides')
        .where('passengerId', isEqualTo: uid)
        .where('status', isEqualTo: 'scheduled')
        .snapshots()
        .listen((snap) {
          final activeIds = snap.docs.map((d) => d.id).toSet();
          // cancel timers for rides no longer scheduled
          _autoStartTimers.keys
              .where((id) => !activeIds.contains(id))
              .toList()
              .forEach((id) {
                _autoStartTimers.remove(id)?.cancel();
              });
          for (final doc in snap.docs) {
            if (_autoStartTimers.containsKey(doc.id)) continue;
            final scheduledAt = (doc.data()['scheduledAt'] as Timestamp?)
                ?.toDate();
            if (scheduledAt == null) continue;
            final triggerAt = scheduledAt.subtract(const Duration(minutes: 10));
            final delay = triggerAt.difference(DateTime.now());
            if (delay.isNegative) {
              _autoStartRide(doc.id);
            } else {
              _autoStartTimers[doc.id] = Timer(
                delay,
                () => _autoStartRide(doc.id),
              );
            }
          }
        });
  }

  Future<void> _autoStartRide(String rideId) async {
    _autoStartTimers.remove(rideId);
    final doc = await db.collection('rides').doc(rideId).get();
    if (!doc.exists) return;
    if ((doc.data()?['status'] as String?) != 'scheduled') return;
    await db.collection('rides').doc(rideId).update({'status': 'requested'});
  }

  String? _lastAutoNavRideId;

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
            final doc = snap.docs.first;
            final data = doc.data();
            final status = data['status'] as String? ?? '';
            // Don't show banner for pending rides with no driver selected yet
            final hasDiver = data['driverId'] != null;
            if (status == 'pending' && !hasDiver) {
              setState(() {
                _activeRide = null;
                _activeRideId = null;
              });
              return;
            }
            setState(() {
              _activeRide = data;
              _activeRideId = doc.id;
            });
            // auto-navigate to tracking when driver starts the trip
            if (status == 'in_trip' && _lastAutoNavRideId != doc.id) {
              _lastAutoNavRideId = doc.id;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RideTrackingScreen(rideId: doc.id),
                  ),
                );
              });
            }
          } else {
            // check if the last ride just completed and needs rating
            final prevId = _activeRideId;
            setState(() {
              _activeRide = null;
              _activeRideId = null;
            });
            // Rating is handled by the 'Rate this ride' button in history tab
          }
        });
  }

  Future<void> _loadUser() async {
    final uid =
        FirebaseAuth.instance.currentUser?.uid ??
        await AuthPersistence.loadUid();
    if (uid == null) return;

    final cachedProfile = await AuthPersistence.loadProfileSnapshot();
    if (cachedProfile != null && mounted) {
      setState(() {
        _name = (cachedProfile['name'] as String?) ?? '';
        _photoUrl = cachedProfile['photoUrl'] as String?;
        _profileData = cachedProfile;
      });
    }

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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ScheduleBookingSheet(
        onBooked: () => setState(() => _currentIndex = 0),
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

  late final List<Widget> _pages = [
    _HomePage(
      onMapCreated: (c) {
        _mapCtrl?.dispose();
        _mapCtrl = c;
      },
      onMapDisposed: () => _mapCtrl = null,
      positionNotifier: _positionNotifier,
      markersNotifier: _markersNotifier,
      defaultTarget: _defaultTarget,
    ),
    const _RideHistoryPage(),
    _BookPage(onBooked: () => setState(() => _currentIndex = 0)),
    _ProfilePage(onUpdated: _loadUser),
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
                    if (_currentIndex != 3 &&
                        _currentIndex != 2 &&
                        _currentIndex != 1)
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
                          if (_isOffline) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                border: Border.all(
                                  color: Colors.orange.shade200,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.wifi_off_rounded,
                                    color: Colors.orange.shade700,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'No internet connection. Please check your connection and try again.',
                                      style: TextStyle(
                                        color: Colors.orange.shade900,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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
                                setState(() {});
                                _searchDebounce?.cancel();
                                _searchDebounce = Timer(
                                  const Duration(milliseconds: 300),
                                  () => _searchPlaces(q),
                                );
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
                                separatorBuilder: (_, _) => Divider(
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
                    if (_activeRide != null &&
                        _activeRideId != null &&
                        (_activeRide!['status'] as String? ?? '') !=
                            'scheduled')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: _ActiveRideBanner(
                          ride: _activeRide!,
                          rideId: _activeRideId!,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  RideTrackingScreen(rideId: _activeRideId!),
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
  final ValueNotifier<LatLng?> positionNotifier;
  final ValueNotifier<Set<Marker>> markersNotifier;
  final LatLng defaultTarget;

  const _HomePage({
    required this.onMapCreated,
    required this.onMapDisposed,
    required this.positionNotifier,
    required this.markersNotifier,
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
    return ValueListenableBuilder<Set<Marker>>(
      valueListenable: widget.markersNotifier,
      builder: (_, markers, _) => GoogleMap(
        initialCameraPosition: CameraPosition(
          target: widget.positionNotifier.value ?? widget.defaultTarget,
          zoom: 15,
        ),
        onMapCreated: widget.onMapCreated,
        markers: markers,
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        mapType: MapType.normal,
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'RIDE HISTORY',
            style: TextStyle(
              color: _navy,
              fontWeight: FontWeight.bold,
              fontSize: 22,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: db
                .collection('rides')
                .where('passengerId', isEqualTo: uid)
                .orderBy('createdAt', descending: true)
                .limit(50)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(color: _navy),
                );
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
                        style: TextStyle(
                          color: _navy.withOpacity(0.4),
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                );
              }
              // Sort: active scheduled rides first, then rest by createdAt desc
              final allDocs = snapshot.data!.docs.toList();
              allDocs.sort((a, b) {
                final aStatus =
                    (a.data() as Map<String, dynamic>)['status'] as String? ??
                    '';
                final bStatus =
                    (b.data() as Map<String, dynamic>)['status'] as String? ??
                    '';
                final aIsActiveScheduled = aStatus == 'scheduled';
                final bIsActiveScheduled = bStatus == 'scheduled';
                if (aIsActiveScheduled && !bIsActiveScheduled) return -1;
                if (!aIsActiveScheduled && bIsActiveScheduled) return 1;
                return 0;
              });
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                itemCount: allDocs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final d = allDocs[i].data() as Map<String, dynamic>;
                  final ts = (d['createdAt'] as Timestamp?)?.toDate();
                  final status = (d['status'] ?? '') as String;
                  // Hide rides cancelled before a driver was ever assigned
                  // Hide pending rides with no driver selected yet
                  if (status == 'cancelled' && d['driverId'] == null) {
                    return const SizedBox.shrink();
                  }
                  if (status == 'pending' && d['driverId'] == null) {
                    return const SizedBox.shrink();
                  }
                  if (status == 'scheduled' && d['driverId'] == null) {
                    return const SizedBox.shrink();
                  }
                  final isScheduled = status == 'scheduled';
                  final scheduledAt = (d['scheduledAt'] as Timestamp?)
                      ?.toDate();
                  final distKm = (d['tripDistanceKm'] as num?)?.toDouble();
                  final fare = (d['finalFare'] as num?)?.toDouble();
                  final rating = (d['driverRating'] as num?)?.toInt() ?? 0;
                  final isCompleted = status == 'completed';
                  final canRate = isCompleted && rating == 0;

                  if (isScheduled) {
                    return _ScheduledRideCard(
                      rideId: allDocs[i].id,
                      ride: d,
                      scheduledAt: scheduledAt,
                      onCancel: () async {
                        await db.collection('rides').doc(allDocs[i].id).update({
                          'status': 'cancelled',
                          'cancelledByPassenger': true,
                        });
                      },
                    );
                  }

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
                                    ? status[0].toUpperCase() +
                                          status.substring(1)
                                    : '',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: isCompleted
                                      ? Colors.green.shade700
                                      : _red,
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
                                  _showRatingSheet(context, allDocs[i].id, d),
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
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
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
          ),
        ),
      ],
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
                            if (!ctx.mounted) return;
                            setSheet(() => submitting = true);
                            try {
                              await db.collection('rides').doc(rideId).update({
                                'driverRating': rating,
                              });
                              final driverId = d['driverId'] as String?;
                              if (driverId != null) {
                                try {
                                  final rides = await db
                                      .collection('rides')
                                      .where('driverId', isEqualTo: driverId)
                                      .where('status', isEqualTo: 'completed')
                                      .get();
                                  final ratings = rides.docs
                                      .map(
                                        (r) =>
                                            (r.data()['driverRating'] as num?)
                                                ?.toDouble() ??
                                            0,
                                      )
                                      .where((r) => r > 0)
                                      .toList();
                                  if (ratings.isNotEmpty) {
                                    final avg =
                                        ratings.reduce((a, b) => a + b) /
                                        ratings.length;
                                    await db
                                        .collection('drivers')
                                        .doc(driverId)
                                        .update({
                                          'avgRating': double.parse(
                                            avg.toStringAsFixed(1),
                                          ),
                                          'totalRatings': ratings.length,
                                        });
                                  }
                                } catch (_) {}
                              }
                            } finally {
                              if (ctx.mounted) Navigator.pop(ctx);
                            }
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

class _ScheduledRideCard extends StatefulWidget {
  final String rideId;
  final Map<String, dynamic> ride;
  final DateTime? scheduledAt;
  final VoidCallback onCancel;
  const _ScheduledRideCard({
    required this.rideId,
    required this.ride,
    required this.scheduledAt,
    required this.onCancel,
  });
  @override
  State<_ScheduledRideCard> createState() => _ScheduledRideCardState();
}

class _ScheduledRideCardState extends State<_ScheduledRideCard> {
  bool _expanded = false;

  String _fmt(DateTime dt) {
    const m = [
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
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${m[dt.month - 1]} ${dt.year}, $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    final scheduledAt = widget.scheduledAt;
    final onCancel = widget.onCancel;
    final driverName = ride['driverName'] as String? ?? '';
    final driverCar = ride['driverCar'] as String? ?? '';
    final driverAvailable = ride['driverAvailable'] as bool?;
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1A4A6E), Color(0xFF143B58)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: _navy.withOpacity(0.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.orange.withOpacity(0.5)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.schedule_rounded,
                        color: Colors.orange,
                        size: 12,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Scheduled',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (driverAvailable == true)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          color: Colors.green,
                          size: 12,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Driver Confirmed',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Awaiting confirmation',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Scheduled time
            Row(
              children: [
                const Icon(
                  Icons.calendar_today_rounded,
                  color: Colors.orange,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Text(
                  scheduledAt != null ? _fmt(scheduledAt) : 'Time not set',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Route
            Row(
              children: [
                const Icon(Icons.location_on_rounded, color: _red, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${ride['pickup'] ?? ''} → ${ride['destination'] ?? ''}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (driverName.isNotEmpty) ...[
              const SizedBox(height: 8),
              Divider(color: Colors.white.withOpacity(0.1), height: 1),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.person_outline,
                    color: Colors.white54,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    driverName,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (driverCar.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.directions_car_outlined,
                      color: Colors.white38,
                      size: 13,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        driverCar,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 10),
            // Expand toggle hint — only shown when driver is assigned
            if (driverName.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.white.withOpacity(0.35),
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _expanded ? 'Tap to collapse' : 'Tap to expand options',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.35),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            // Cancel button — always visible if no driver, otherwise expand to show
            if (driverName.isEmpty || _expanded) ...[
              const SizedBox(height: 10),
              Divider(color: Colors.white.withOpacity(0.1), height: 1),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          'Cancel Scheduled Ride?',
                          style: TextStyle(
                            color: _navy,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        content: const Text(
                          'Are you sure you want to cancel this scheduled ride?',
                          style: TextStyle(color: _navy),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(
                              'Keep',
                              style: TextStyle(color: _navy.withOpacity(0.6)),
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _red,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('Cancel Ride'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) onCancel();
                  },
                  icon: const Icon(Icons.close_rounded, color: _red, size: 15),
                  label: const Text(
                    'Cancel Ride',
                    style: TextStyle(color: _red, fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _red.withOpacity(0.6)),
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
      ),
    );
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
  double? _destLat;
  double? _destLng;
  bool _pickupConfirmed = false;
  bool _destConfirmed = false;
  String? _locationError;

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
      final pos = await _getPosition();
      if (pos == null) return;
      _pickupLat = pos.latitude;
      _pickupLng = pos.longitude;
      _pickupConfirmed = true;

      final res = await http.get(
        Uri.parse(
          'https://maps.googleapis.com/maps/api/geocode/json'
          '?latlng=${pos.latitude},${pos.longitude}&key=$_googleApiKey',
        ),
      );
      final data = jsonDecode(res.body);
      final results = data['results'] as List?;

      String? address;
      if (results != null && results.isNotEmpty) {
        const preferred = [
          'premise',
          'street_address',
          'route',
          'neighborhood',
          'sublocality',
          'locality',
        ];
        for (final r in results) {
          final types = (r['types'] as List?)?.cast<String>() ?? [];
          if (types.any(preferred.contains)) {
            address = r['formatted_address'] as String?;
            break;
          }
        }
        address ??= results[0]['formatted_address'] as String?;
      }

      if (mounted) {
        _pickupCtrl.text =
            address ??
            '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
        setState(() => _suggestions = []);
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _searchPlaces(String query, TextEditingController ctrl) async {
    _activeCtrl = ctrl;
    if (ctrl == _pickupCtrl) {
      _pickupLat = null;
      _pickupLng = null;
      _pickupConfirmed = false;
    } else {
      _destLat = null;
      _destLng = null;
      _destConfirmed = false;
    }
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
          'X-Goog-Api-Key': _googleApiKey,
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
    try {
      final res = await http.get(
        Uri.parse(
          'https://maps.googleapis.com/maps/api/geocode/json?place_id=$placeId&key=$_googleApiKey',
        ),
      );
      final data = jsonDecode(res.body);
      final loc = data['results']?[0]?['geometry']?['location'];
      if (loc != null) {
        final lat = (loc['lat'] as num).toDouble();
        final lng = (loc['lng'] as num).toDouble();
        if (_activeCtrl == _pickupCtrl) {
          _pickupLat = lat;
          _pickupLng = lng;
          _pickupConfirmed = true;
        } else {
          _destLat = lat;
          _destLng = lng;
          _destConfirmed = true;
        }
      }
    } catch (_) {}
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

    if (!_pickupConfirmed) {
      setState(() => _locationError = 'pickup');
      _searchPlaces(_pickupCtrl.text, _pickupCtrl);
      return;
    }
    if (!_destConfirmed) {
      setState(() => _locationError = 'dest');
      _searchPlaces(_destCtrl.text, _destCtrl);
      return;
    }
    setState(() {
      _locationError = null;
      _loading = true;
    });
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final userDoc = await db.collection('users').doc(uid).get();
      final name = (userDoc.data())?['name'] ?? '';
      final phone = (userDoc.data())?['phone'] ?? '';
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
        if (_destLat != null) 'destinationLat': _destLat,
        if (_destLng != null) 'destinationLng': _destLng,
        if (_destLat != null && _destLng != null)
          'destinationLocation': GeoPoint(_destLat!, _destLng!),
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
                  onDismiss: () => setState(() => _suggestions = []),
                ),
                if (_locationError == 'pickup')
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, color: _red, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          'Please select a location from the suggestions',
                          style: const TextStyle(color: _red, fontSize: 12),
                        ),
                      ],
                    ),
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
                  onDismiss: () => setState(() => _suggestions = []),
                ),
                if (_locationError == 'dest')
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, color: _red, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          'Please select a location from the suggestions',
                          style: const TextStyle(color: _red, fontSize: 12),
                        ),
                      ],
                    ),
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
  final VoidCallback? onDismiss;
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.icon,
    required this.isSearching,
    required this.onChanged,
    this.onDismiss,
  });
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: (_) {
        onDismiss?.call();
        FocusScope.of(context).unfocus();
      },
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
        separatorBuilder: (_, _) =>
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
  final VoidCallback onUpdated;

  const _ProfilePage({required this.onUpdated});

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  Map<String, dynamic>? _data;
  int _totalRides = 0;
  double _avgRating = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final cachedProfile = await AuthPersistence.loadProfileSnapshot();
    if (cachedProfile != null && mounted) {
      setState(() {
        _data = cachedProfile;
        _totalRides = (cachedProfile['totalRides'] as num?)?.toInt() ?? 0;
        _avgRating = (cachedProfile['avgRating'] as num?)?.toDouble() ?? 0;
      });
    }

    try {
      final userDoc = await db.collection('users').doc(uid).get();
      final data = userDoc.data();
      if (!mounted) return;
      setState(() => _data = data);
      await AuthPersistence.saveProfileSnapshot(data ?? {});
      final cachedRides = (data?['totalRides'] as num?)?.toInt();
      final cachedRating = (data?['avgRating'] as num?)?.toDouble();
      if (cachedRides != null) {
        setState(() {
          _totalRides = cachedRides;
          _avgRating = cachedRating ?? 0;
        });
        return;
      }
      final rides = await db
          .collection('rides')
          .where('passengerId', isEqualTo: uid)
          .where('status', isEqualTo: 'completed')
          .limit(200)
          .get();
      double ratingSum = 0;
      for (var r in rides.docs) {
        ratingSum += (r.data()['passengerRating'] ?? 0).toDouble();
      }
      if (mounted) {
        setState(() {
          _totalRides = rides.docs.length;
          _avgRating = rides.docs.isNotEmpty
              ? ratingSum / rides.docs.length
              : 0;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null) {
      return const Center(child: CircularProgressIndicator(color: _navy));
    }

    final name = _data!['name'] ?? '';
    final email = _data!['email'] ?? '';
    final phone = _data!['phone'] ?? '';
    final photoUrl = _data!['photoUrl'];
    final createdAt = (_data!['createdAt'] as Timestamp?)?.toDate();
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
                if (updated == true) {
                  widget.onUpdated();
                  _load();
                }
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
              Navigator.pop(context);
              await AuthPersistence.clearCredentials();
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

  Future<void> _confirmCancel(BuildContext context) async {
    // fetch cancellation fee
    double fee = 0;
    try {
      final snap = await db.collection('settings').doc('fare').get();
      fee = (snap.data()?['cancellationFee'] as num?)?.toDouble() ?? 0;
    } catch (_) {}

    final status = widget.ride['status'] as String? ?? '';
    final hasDriver = widget.ride['driverId'] != null;
    final chargeable =
        fee > 0 && hasDriver && (status == 'accepted' || status == 'in_trip');

    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Cancel Ride?',
          style: TextStyle(color: _navy, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (chargeable) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _red.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _red.withOpacity(0.2)),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: _red,
                      size: 28,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Cancellation Fee',
                      style: TextStyle(
                        color: _red.withOpacity(0.8),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'MWK ${fee.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: _red,
                        fontWeight: FontWeight.bold,
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'A cancellation fee will be charged because a driver has already been assigned.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _navy.withOpacity(0.6),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ] else
              Text(
                'Are you sure you want to cancel this ride?',
                style: TextStyle(color: _navy.withOpacity(0.7), fontSize: 14),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Keep Ride',
              style: TextStyle(color: _navy.withOpacity(0.6)),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              chargeable
                  ? 'Cancel & Pay MWK ${fee.toStringAsFixed(0)}'
                  : 'Yes, Cancel',
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await db.collection('rides').doc(widget.rideId).update({
        'status': 'cancelled',
        'cancelledByPassenger': true,
        if (chargeable) 'cancellationFee': fee,
      });
    }
  }

  String get _statusLabel {
    switch (widget.ride['status']) {
      case 'pending':
        return 'Selecting driver...';
      case 'scheduled':
        return 'Ride Scheduled';
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
            // Cancel button — allowed until trip actually starts
            if (['pending', 'requested'].contains(widget.ride['status']) ||
                (widget.ride['status'] == 'accepted' &&
                    (widget.ride['tripPhase'] as String? ?? '') !=
                        'in_trip')) ...[
              const SizedBox(height: 10),
              Divider(color: Colors.white.withOpacity(0.1), height: 1),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _confirmCancel(context),
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

// ── Schedule Booking Sheet ────────────────────────────
class _ScheduleBookingSheet extends StatefulWidget {
  final VoidCallback onBooked;
  const _ScheduleBookingSheet({required this.onBooked});
  @override
  State<_ScheduleBookingSheet> createState() => _ScheduleBookingSheetState();
}

class _ScheduleBookingSheetState extends State<_ScheduleBookingSheet> {
  final _pickupCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  DateTime? _scheduledAt;
  bool _loading = false;
  bool _locating = false;
  double? _pickupLat, _pickupLng;
  double? _destLat, _destLng;
  bool _pickupConfirmed = false;
  bool _destConfirmed = false;
  String? _locationError;
  TextEditingController? _activeCtrl;
  List<Map<String, dynamic>> _suggestions = [];
  bool _searching = false;

  @override
  void dispose() {
    _pickupCtrl.dispose();
    _destCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: _navy,
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: _navy,
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (time == null || !mounted) return;
    setState(() {
      _scheduledAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final pos = await _getPosition();
      if (pos == null) return;
      _pickupLat = pos.latitude;
      _pickupLng = pos.longitude;
      _pickupConfirmed = true;
      final res = await http.get(
        Uri.parse(
          'https://maps.googleapis.com/maps/api/geocode/json'
          '?latlng=${pos.latitude},${pos.longitude}&key=$_googleApiKey',
        ),
      );
      final data = jsonDecode(res.body);
      final results = data['results'] as List?;
      String? address;
      if (results != null && results.isNotEmpty) {
        const preferred = [
          'premise',
          'street_address',
          'route',
          'neighborhood',
          'sublocality',
          'locality',
        ];
        for (final r in results) {
          final types = (r['types'] as List?)?.cast<String>() ?? [];
          if (types.any(preferred.contains)) {
            address = r['formatted_address'] as String?;
            break;
          }
        }
        address ??= results[0]['formatted_address'] as String?;
      }
      if (mounted) {
        _pickupCtrl.text =
            address ??
            '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
        setState(() => _suggestions = []);
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _searchPlaces(String query, TextEditingController ctrl) async {
    _activeCtrl = ctrl;
    if (ctrl == _pickupCtrl) {
      _pickupLat = null;
      _pickupLng = null;
      _pickupConfirmed = false;
    } else {
      _destLat = null;
      _destLng = null;
      _destConfirmed = false;
    }
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
          'X-Goog-Api-Key': _googleApiKey,
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
    try {
      final res = await http.get(
        Uri.parse(
          'https://maps.googleapis.com/maps/api/geocode/json?place_id=$placeId&key=$_googleApiKey',
        ),
      );
      final data = jsonDecode(res.body);
      final loc = data['results']?[0]?['geometry']?['location'];
      if (loc != null) {
        final lat = (loc['lat'] as num).toDouble();
        final lng = (loc['lng'] as num).toDouble();
        if (_activeCtrl == _pickupCtrl) {
          _pickupLat = lat;
          _pickupLng = lng;
          _pickupConfirmed = true;
        } else {
          _destLat = lat;
          _destLng = lng;
          _destConfirmed = true;
        }
      }
    } catch (_) {}
  }

  Future<void> _submit() async {
    final pickup = _pickupCtrl.text.trim();
    final dest = _destCtrl.text.trim();
    if (pickup.isEmpty || dest.isEmpty || _scheduledAt == null) return;
    if (_scheduledAt!.isBefore(
      DateTime.now().add(const Duration(minutes: 5)),
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please pick a time at least 5 minutes from now.'),
        ),
      );
      return;
    }
    if (!_pickupConfirmed) {
      setState(() => _locationError = 'pickup');
      _searchPlaces(_pickupCtrl.text, _pickupCtrl);
      return;
    }
    if (!_destConfirmed) {
      setState(() => _locationError = 'dest');
      _searchPlaces(_destCtrl.text, _destCtrl);
      return;
    }
    setState(() {
      _locationError = null;
      _loading = true;
    });
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final userDoc = await db.collection('users').doc(uid).get();
      final name = (userDoc.data())?['name'] ?? '';
      final phone = (userDoc.data())?['phone'] ?? '';
      final rideRef = await db.collection('rides').add({
        'passengerId': uid,
        'passengerName': name,
        'passengerPhone': phone,
        'pickup': pickup,
        'destination': dest,
        'status': 'scheduled',
        'isScheduled': true,
        'scheduledAt': Timestamp.fromDate(_scheduledAt!),
        'reminder50Sent': false,
        'reminder10Sent': false,
        'createdAt': FieldValue.serverTimestamp(),
        if (_pickupLat != null) 'pickupLat': _pickupLat,
        if (_pickupLng != null) 'pickupLng': _pickupLng,
        if (_pickupLat != null && _pickupLng != null)
          'pickupLocation': GeoPoint(_pickupLat!, _pickupLng!),
        if (_destLat != null) 'destinationLat': _destLat,
        if (_destLng != null) 'destinationLng': _destLng,
        if (_destLat != null && _destLng != null)
          'destinationLocation': GeoPoint(_destLat!, _destLng!),
      });
      _pickupCtrl.clear();
      _destCtrl.clear();
      if (mounted) {
        Navigator.pop(context); // close sheet
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AvailableDriversScreen(
              rideId: rideRef.id,
              pickup: pickup,
              destination: dest,
              pickupLat: _pickupLat,
              pickupLng: _pickupLng,
              isScheduled: true,
              scheduledAt: _scheduledAt,
            ),
          ),
        ).then((_) => widget.onBooked());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatScheduled(DateTime dt) {
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
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Row(
                children: [
                  Icon(Icons.schedule_rounded, color: _navy, size: 22),
                  SizedBox(width: 8),
                  Text(
                    'Schedule a Ride',
                    style: TextStyle(
                      color: _navy,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Date & Time picker
              GestureDetector(
                onTap: _pickDateTime,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: _scheduledAt != null
                        ? _navy.withOpacity(0.06)
                        : _cream,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _scheduledAt != null
                          ? _navy.withOpacity(0.3)
                          : _navy.withOpacity(0.12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.calendar_today_rounded,
                        color: _scheduledAt != null
                            ? _navy
                            : _navy.withOpacity(0.4),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _scheduledAt != null
                              ? _formatScheduled(_scheduledAt!)
                              : 'Pick date & time',
                          style: TextStyle(
                            color: _scheduledAt != null
                                ? _navy
                                : _navy.withOpacity(0.4),
                            fontWeight: _scheduledAt != null
                                ? FontWeight.w600
                                : FontWeight.normal,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: _navy.withOpacity(0.3),
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Pickup
              _SearchField(
                controller: _pickupCtrl,
                hint: 'Pickup location',
                icon: Icons.my_location_rounded,
                isSearching: _searching && _activeCtrl == _pickupCtrl,
                onChanged: (q) => _searchPlaces(q, _pickupCtrl),
                onDismiss: () => setState(() => _suggestions = []),
              ),
              if (_locationError == 'pickup')
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Row(
                    children: const [
                      Icon(Icons.info_outline, color: _red, size: 14),
                      SizedBox(width: 4),
                      Text(
                        'Please select a location from the suggestions',
                        style: TextStyle(color: _red, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              if (_suggestions.isNotEmpty && _activeCtrl == _pickupCtrl)
                _SuggestionsList(
                  suggestions: _suggestions,
                  onTap: _selectPlace,
                ),
              const SizedBox(height: 10),
              // Destination
              _SearchField(
                controller: _destCtrl,
                hint: 'Destination',
                icon: Icons.location_on_rounded,
                isSearching: _searching && _activeCtrl == _destCtrl,
                onChanged: (q) => _searchPlaces(q, _destCtrl),
                onDismiss: () => setState(() => _suggestions = []),
              ),
              if (_locationError == 'dest')
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Row(
                    children: const [
                      Icon(Icons.info_outline, color: _red, size: 14),
                      SizedBox(width: 4),
                      Text(
                        'Please select a location from the suggestions',
                        style: TextStyle(color: _red, fontSize: 12),
                      ),
                    ],
                  ),
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
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_loading ||
                          _scheduledAt == null ||
                          _pickupCtrl.text.isEmpty ||
                          _destCtrl.text.isEmpty)
                      ? null
                      : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _navy,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade200,
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
                          'Choose Driver',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
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
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Container(
      margin: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        bottomPadding > 0 ? bottomPadding : 12,
      ),
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
