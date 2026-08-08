import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'db.dart';
import 'notifications_screen.dart';
import 'notification_service.dart';
import 'edit_profile_screen.dart';
import 'driver_navigation_screen.dart';
import 'auth_gate.dart';
import 'auth_persistence.dart';
import 'settings_screen.dart';
import 'help_center_screen.dart';
import 'booking_detail_screen.dart';
import 'map_service.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  String _name = '';
  String? _photoUrl;
  bool _isOffline = false;
  int _currentIndex = 0;
  StreamSubscription<bool>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _initConnectivity();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
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
      });
    }

    // load from drivers collection only
    final doc = await db.collection('drivers').doc(uid).get();
    if (doc.exists && mounted) {
      setState(() {
        _name = (doc.data() as Map<String, dynamic>?)?['name'] ?? '';
        _photoUrl = (doc.data() as Map<String, dynamic>?)?['photoUrl'];
      });
    }
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  // Keep stable instances so IndexedStack doesn't remount and reset state
  late final _dashboardPage = const _DashboardPage();
  late final _ridesPage = const _RidesPage();
  late final _navPage = DriverNavigationScreen(
    onRideAccepted: () => setState(() => _currentIndex = 1),
  );

  List<Widget> get _pages => [
    _dashboardPage,
    _navPage,
    _ridesPage,
    _DriverProfilePage(name: _name, photoUrl: _photoUrl),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (_currentIndex == 0)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _greeting,
                          style: TextStyle(
                            fontSize: 14,
                            color: _navy.withValues(alpha: 0.5),
                          ),
                        ),
                        Text(
                          _name.isNotEmpty ? _name.split(' ').first : 'Driver',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: _navy,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    _NotificationBell(),
                    const SizedBox(width: 12),
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _navy.withValues(alpha: 0.1),
                        border: Border.all(
                          color: _navy.withValues(alpha: 0.15),
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
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _navy,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: IndexedStack(index: _currentIndex, children: _pages),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomNav(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
      ),
    );
  }
}

// ── Pages ───────────────────────────────────────────────

class _DashboardPage extends StatefulWidget {
  const _DashboardPage();
  @override
  State<_DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<_DashboardPage> {
  bool _isOnline = false;
  bool _isOffline = false;
  bool _toggling = false;
  Map<String, dynamic>? _driverData;
  double _subscriptionOwed = 0;
  StreamSubscription? _driverSub;
  StreamSubscription<bool>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _initConnectivity();
    _loadFaresAndListen();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _driverSub?.cancel();
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

  Future<void> _loadFaresAndListen() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Ensure isOnline is false until driver manually turns it on after first login
    final snap = await db.collection('drivers').doc(uid).get();
    if (snap.exists) {
      final d = snap.data() as Map<String, dynamic>;
      if (d['firstLoginDone'] != true) {
        await db.collection('drivers').doc(uid).update({
          'isOnline': false,
          'firstLoginDone': true,
        });
      }
    }

    _driverSub = db.collection('drivers').doc(uid).snapshots().listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data() as Map<String, dynamic>;
      final balance = (data['subscriptionBalance'] as num?)?.toDouble() ?? 0;
      setState(() {
        _isOnline = data['isOnline'] == true;
        _driverData = data;
        _subscriptionOwed = balance;
      });
    });
  }

  void _showCommissionBreakdown(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommissionSheet(
        subscriptionOwed: _subscriptionOwed,
        driverData: _driverData,
      ),
    );
  }

  Future<void> _toggleOnline() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() => _toggling = true);
    final newStatus = !_isOnline;
    await db.collection('drivers').doc(uid).update({'isOnline': newStatus});
    if (mounted) {
      setState(() {
        _isOnline = newStatus;
        _toggling = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sub = _driverData?['subscriptionFee'];
    final subDue = _driverData?['subscriptionDueDate'] as Timestamp?;
    final subStatus =
        (_driverData?['subscriptionStatus'] ?? 'unknown') as String;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),

          // Online toggle + SOS row
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: _isOnline
                              ? Colors.green
                              : _navy.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isOnline
                              ? Icons.wifi_rounded
                              : Icons.wifi_off_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _isOnline ? 'Online' : 'Offline',
                          style: const TextStyle(
                            color: _navy,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      _toggling
                          ? const SizedBox(
                              width: 28,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _navy,
                              ),
                            )
                          : Transform.scale(
                              scale: 0.8,
                              child: Switch(
                                value: _isOnline,
                                onChanged: (_) => _toggleOnline(),
                                activeThumbColor: Colors.green,
                                inactiveThumbColor: _navy.withValues(
                                  alpha: 0.4,
                                ),
                                inactiveTrackColor: _navy.withValues(
                                  alpha: 0.1,
                                ),
                              ),
                            ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const _DriverSosScreen()),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: _red,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
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
            ],
          ),

          const SizedBox(height: 12),

          // Amount owed
          GestureDetector(
            onTap: () => _showCommissionBreakdown(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: _subscriptionOwed > 0 ? _red : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: _subscriptionOwed <= 0
                    ? Border.all(color: _navy.withValues(alpha: 0.08))
                    : null,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: _subscriptionOwed > 0
                          ? Colors.white.withValues(alpha: 0.2)
                          : _navy.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.receipt_outlined,
                      color: _subscriptionOwed > 0 ? Colors.white : _navy,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Amount Owed',
                      style: TextStyle(
                        color: _subscriptionOwed > 0 ? Colors.white : _navy,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    'MWK ${_subscriptionOwed.toStringAsFixed(0)}',
                    style: TextStyle(
                      color: _subscriptionOwed > 0
                          ? Colors.white
                          : _navy.withValues(alpha: 0.5),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: _subscriptionOwed > 0
                        ? Colors.white.withValues(alpha: 0.7)
                        : _navy.withValues(alpha: 0.3),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          if (_isOffline)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                border: Border.all(color: Colors.orange.shade200),
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

          // Incoming bookings
          const Text(
            'Incoming Bookings',
            style: TextStyle(
              color: _navy,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          // Incoming bookings — only rides requested for this driver
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseAuth.instance.currentUser == null
                ? const Stream.empty()
                : db
                      .collection('rides')
                      .where('driverId', isEqualTo: uid)
                      .where('status', isEqualTo: 'requested')
                      .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const SizedBox.shrink();
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'No incoming bookings',
                    style: TextStyle(
                      color: _navy.withValues(alpha: 0.4),
                      fontSize: 13,
                    ),
                  ),
                );
              }
              return Column(
                children: docs.map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final assignedToMe = d['driverId'] == uid;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: assignedToMe
                            ? Colors.green.withValues(alpha: 0.4)
                            : _navy.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on_outlined,
                              color: _red,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${d['pickup'] ?? ''} → ${d['destination'] ?? ''}',
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
                        if ((d['passengerName'] ?? '')
                            .toString()
                            .isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(
                                Icons.person_outline,
                                color: _navy.withValues(alpha: 0.5),
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                d['passengerName'],
                                style: TextStyle(
                                  color: _navy.withValues(alpha: 0.6),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => BookingDetailScreen(
                                  rideId: doc.id,
                                  ride: d,
                                ),
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _navy,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'View & Calculate Fare',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),

          const SizedBox(height: 20),

          // Rides in progress
          const Text(
            'In Progress',
            style: TextStyle(
              color: _navy,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseAuth.instance.currentUser == null
                ? const Stream.empty()
                : db
                      .collection('rides')
                      .where('driverId', isEqualTo: uid)
                      .where('status', whereIn: ['accepted', 'in_trip'])
                      .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const SizedBox.shrink();
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'No rides in progress',
                    style: TextStyle(
                      color: _navy.withValues(alpha: 0.4),
                      fontSize: 13,
                    ),
                  ),
                );
              }
              return Column(
                children: docs.map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _navy,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.directions_car_rounded,
                              color: Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${d['pickup'] ?? ''} → ${d['destination'] ?? ''}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text(
                                'In Progress',
                                style: TextStyle(
                                  color: Colors.green,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if ((d['passengerName'] ?? '')
                            .toString()
                            .isNotEmpty) ...[
                          Row(
                            children: [
                              Icon(
                                Icons.person_outline,
                                color: Colors.white.withValues(alpha: 0.6),
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                d['passengerName'],
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              // Switch to Navigate tab
                              final homeState = context
                                  .findAncestorStateOfType<
                                    _DriverHomeScreenState
                                  >();
                              homeState?.setState(
                                () => homeState._currentIndex = 1,
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _navy,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'View Trip',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),

          const SizedBox(height: 20),

          // Scheduled bookings
          const Text(
            'Scheduled Bookings',
            style: TextStyle(
              color: _navy,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseAuth.instance.currentUser == null
                ? const Stream.empty()
                : db
                      .collection('rides')
                      .where('driverId', isEqualTo: uid)
                      .where('status', isEqualTo: 'scheduled')
                      .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const SizedBox.shrink();
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'No scheduled bookings',
                    style: TextStyle(
                      color: _navy.withValues(alpha: 0.4),
                      fontSize: 13,
                    ),
                  ),
                );
              }
              return Column(
                children: docs.map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final scheduledAt = (d['scheduledAt'] as Timestamp?)
                      ?.toDate();
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
                  final scheduledStr = scheduledAt != null
                      ? '${scheduledAt.day} ${months[scheduledAt.month - 1]} ${scheduledAt.year}, ${scheduledAt.hour.toString().padLeft(2, '0')}:${scheduledAt.minute.toString().padLeft(2, '0')}'
                      : 'Time not set';
                  return _ScheduledBookingCard(
                    rideId: doc.id,
                    ride: d,
                    scheduledStr: scheduledStr,
                  );
                }).toList(),
              );
            },
          ),

          const SizedBox(height: 100),
        ],
      ),
    );
  }
}

class _ScheduledBookingCard extends StatefulWidget {
  final String rideId;
  final Map<String, dynamic> ride;
  final String scheduledStr;
  const _ScheduledBookingCard({
    required this.rideId,
    required this.ride,
    required this.scheduledStr,
  });
  @override
  State<_ScheduledBookingCard> createState() => _ScheduledBookingCardState();
}

class _ScheduledBookingCardState extends State<_ScheduledBookingCard> {
  double _baseFee = 2500,
      _pricePerKm = 2500,
      _shortDistanceFee = 10000,
      _shortDistanceThresholdKm = 2.8;
  double _distanceKm = 0;
  bool _loadingFare = true;
  bool _coordsFound = false;
  bool _responding = false;

  @override
  void initState() {
    super.initState();
    _loadFareAndDistance();
  }

  Future<void> _loadFareAndDistance() async {
    try {
      final doc = await db.collection('settings').doc('fare').get();
      final data = doc.data() ?? {};
      _baseFee = (data['baseFee'] as num?)?.toDouble() ?? 2500;
      _pricePerKm = (data['pricePerKm'] as num?)?.toDouble() ?? 2500;
      _shortDistanceFee =
          (data['shortDistanceFee'] as num?)?.toDouble() ?? 10000;
      _shortDistanceThresholdKm =
          (data['shortDistanceThresholdKm'] as num?)?.toDouble() ?? 2.8;
    } catch (_) {}
    final pLat =
        (widget.ride['pickupLat'] as num?)?.toDouble() ??
        (widget.ride['pickupLocation'] as GeoPoint?)?.latitude;
    final pLng =
        (widget.ride['pickupLng'] as num?)?.toDouble() ??
        (widget.ride['pickupLocation'] as GeoPoint?)?.longitude;
    final dLat =
        (widget.ride['destinationLat'] as num?)?.toDouble() ??
        (widget.ride['destinationLocation'] as GeoPoint?)?.latitude;
    final dLng =
        (widget.ride['destinationLng'] as num?)?.toDouble() ??
        (widget.ride['destinationLocation'] as GeoPoint?)?.longitude;
    if (pLat != null && pLng != null && dLat != null && dLng != null) {
      // use Directions API road distance — same source as BookingDetailScreen
      try {
        final res = await http.get(
          Uri.parse(
            'https://maps.googleapis.com/maps/api/directions/json'
            '?origin=$pLat,$pLng&destination=$dLat,$dLng&mode=driving&key=$googleMapsApiKey',
          ),
        );
        final json = jsonDecode(res.body);
        final routes = json['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          _distanceKm =
              (routes[0]['legs'][0]['distance']['value'] as num).toDouble() /
              1000;
          _coordsFound = true;
        }
      } catch (_) {}
      // fallback to straight-line if API failed
      if (!_coordsFound) {
        _distanceKm = MapService.distanceKm(pLat, pLng, dLat, dLng);
        _coordsFound = true;
      }
    }
    if (mounted) setState(() => _loadingFare = false);
  }

  double get _estimatedFare => _distanceKm < _shortDistanceThresholdKm
      ? _shortDistanceFee
      : _baseFee + (_distanceKm * _pricePerKm);

  Future<void> _respond(bool available) async {
    setState(() => _responding = true);
    try {
      if (available) {
        await db.collection('rides').doc(widget.rideId).update({
          'driverAvailable': true,
        });
        // write a notification for the passenger
        await db.collection('notifications').add({
          'uid': widget.ride['passengerId'],
          'title': 'Driver Confirmed ✅',
          'body':
              '${widget.ride['driverName'] ?? 'Your driver'} confirmed availability for your scheduled ride on ${widget.scheduledStr}.',
          'isRead': false,
          'target': 'passenger',
          'type': 'notification',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await db.collection('rides').doc(widget.rideId).update({
          'status': 'cancelled',
          'cancelledByDriver': true,
          'driverAvailable': false,
        });
        await db.collection('notifications').add({
          'uid': widget.ride['passengerId'],
          'title': 'Driver Unavailable',
          'body':
              'Your scheduled ride on ${widget.scheduledStr} was cancelled because the driver is unavailable.',
          'isRead': false,
          'target': 'passenger',
          'type': 'notification',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.ride;
    final driverAvailable = d['driverAvailable'] as bool?;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Scheduled badge + time
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
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
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.scheduledStr,
                  style: const TextStyle(
                    color: _navy,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Route
          Row(
            children: [
              const Icon(Icons.location_on_outlined, color: _red, size: 15),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${d['pickup'] ?? ''} → ${d['destination'] ?? ''}',
                  style: const TextStyle(
                    color: _navy,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Passenger
          if ((d['passengerName'] ?? '').toString().isNotEmpty)
            Row(
              children: [
                Icon(
                  Icons.person_outline,
                  color: _navy.withValues(alpha: 0.5),
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  d['passengerName'],
                  style: TextStyle(
                    color: _navy.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
                if ((d['passengerPhone'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.phone_outlined,
                    color: _navy.withValues(alpha: 0.5),
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    d['passengerPhone'],
                    style: TextStyle(
                      color: _navy.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          const SizedBox(height: 10),
          // Estimated fare
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _navy,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.payments_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Estimated Fare',
                      style: TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                    Text(
                      _loadingFare || !_coordsFound
                          ? 'Calculating...'
                          : 'MWK ${_estimatedFare.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                if (!_loadingFare && _coordsFound) ...[
                  const Spacer(),
                  Text(
                    '${_distanceKm.toStringAsFixed(1)} km',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Availability response
          if (driverAvailable == true)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: Colors.green,
                    size: 16,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'You confirmed availability',
                    style: TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _responding ? null : () => _respond(false),
                    icon: const Icon(Icons.close_rounded, size: 15),
                    label: const Text('Unavailable'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _red,
                      side: const BorderSide(color: _red),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _responding ? null : () => _respond(true),
                    icon: _responding
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded, size: 15),
                    label: const Text(
                      'Available',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
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

class _DriverSosScreen extends StatefulWidget {
  const _DriverSosScreen();
  @override
  State<_DriverSosScreen> createState() => _DriverSosScreenState();
}

class _DriverSosScreenState extends State<_DriverSosScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  String? _sosId;
  bool _creating = false;
  bool _resolved = false;
  bool _distressSent = false;
  bool _distressSending = false;
  double _holdProgress = 0;
  Timer? _holdTimer;
  static const _holdDuration = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _createSos();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _createSos() async {
    setState(() => _creating = true);
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    // Resume existing unresolved SOS if one exists
    final existing = await db
        .collection('sos_chats')
        .where('driverId', isEqualTo: uid)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      final existingDoc = existing.docs.first;
      if (mounted) {
        setState(() {
          _sosId = existingDoc.id;
          _distressSent = existingDoc.data()['distressSent'] == true;
          _creating = false;
        });
      }
      return;
    }

    final doc = await db.collection('drivers').doc(uid).get();
    final name = (doc.data())?['name'] ?? 'Driver';
    final ref = await db.collection('sos_chats').add({
      'driverId': uid,
      'driverName': name,
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });
    await db.collection('sos_chats').doc(ref.id).collection('messages').add({
      'senderId': uid,
      'text': '🚨 SOS Alert triggered by Driver: $name',
      'createdAt': FieldValue.serverTimestamp(),
      'isSystem': true,
    });
    if (mounted)
      setState(() {
        _sosId = ref.id;
        _creating = false;
      });
  }

  Future<void> _send() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _sosId == null) return;
    _msgController.clear();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    await db.collection('sos_chats').doc(_sosId).collection('messages').add({
      'senderId': uid,
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
      'isSystem': false,
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startHold() {
    if (_distressSent || _distressSending || _sosId == null) return;
    SystemSound.play(SystemSoundType.click);
    const ticks = 60;
    int elapsed = 0;
    _holdTimer = Timer.periodic(
      Duration(milliseconds: _holdDuration.inMilliseconds ~/ ticks),
      (t) {
        elapsed++;
        if (mounted) setState(() => _holdProgress = elapsed / ticks);
        if (elapsed >= ticks) {
          t.cancel();
          _triggerDistress();
        }
      },
    );
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    if (mounted) setState(() => _holdProgress = 0);
  }

  Future<void> _triggerDistress() async {
    if (_sosId == null) return;
    setState(() => _distressSending = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final pos = await MapService.getCurrentPosition();
      final String locationText;
      final Map<String, dynamic> locationData = {};
      if (pos != null) {
        locationText =
            '📍 Location: https://maps.google.com/?q=${pos.latitude},${pos.longitude}\n'
            'Coordinates: ${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}';
        locationData['lat'] = pos.latitude;
        locationData['lng'] = pos.longitude;
        locationData['locationUrl'] =
            'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
      } else {
        locationText = '⚠️ Location unavailable — GPS could not be obtained.';
      }
      await db.collection('sos_chats').doc(_sosId).collection('messages').add({
        'senderId': uid,
        'text': '🆘 DISTRESS SIGNAL TRIGGERED\n$locationText',
        'createdAt': FieldValue.serverTimestamp(),
        'isSystem': true,
      });
      await db.collection('sos_chats').doc(_sosId).update({
        'distressSent': true,
        'distressSentAt': FieldValue.serverTimestamp(),
        if (locationData.isNotEmpty) 'location': locationData,
      });
      if (mounted)
        setState(() {
          _distressSent = true;
          _distressSending = false;
        });
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _distressSending = false;
          _holdProgress = 0;
        });
    }
  }

  Widget _buildDistressButton() {
    if (_distressSent) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.green.shade600,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text(
              'Distress Signal Sent',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onLongPressStart: (_) => _startHold(),
      onLongPressEnd: (_) => _cancelHold(),
      onLongPressCancel: _cancelHold,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        decoration: BoxDecoration(
          color: _red,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            if (_holdProgress > 0)
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: _holdProgress,
                    child: Container(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_distressSending)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  else
                    const Icon(
                      Icons.sos_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  const SizedBox(width: 10),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'TRIGGER EMERGENCY',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        _holdProgress > 0
                            ? 'Hold… ${((1 - _holdProgress) * 3).ceil()}s'
                            : 'Hold 3s · Sends location instantly',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resolve() async {
    if (_sosId == null) return;
    await db.collection('sos_chats').doc(_sosId).update({'status': 'resolved'});
    if (mounted) setState(() => _resolved = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _red,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Row(
          children: [
            Icon(Icons.sos_rounded, color: Colors.white, size: 22),
            SizedBox(width: 8),
            Text(
              'SOS Emergency',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          if (!_resolved && _sosId != null)
            TextButton(
              onPressed: _resolve,
              child: const Text(
                'Resolve',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: _creating
          ? const Center(child: CircularProgressIndicator(color: _red))
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: _resolved
                      ? Colors.green.shade600
                      : _red.withValues(alpha: 0.9),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _resolved
                            ? Icons.check_circle_outline
                            : Icons.warning_amber_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _resolved
                            ? 'SOS Resolved — You are safe'
                            : 'SOS Active — Support has been notified',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: db
                        .collection('sos_chats')
                        .doc(_sosId)
                        .collection('messages')
                        .orderBy('createdAt')
                        .snapshots(),
                    builder: (context, snapshot) {
                      final docs = snapshot.data?.docs ?? [];
                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        itemCount: docs.length,
                        itemBuilder: (context, i) {
                          final d = docs[i].data() as Map<String, dynamic>;
                          final isSystem = d['isSystem'] == true;
                          final isMe =
                              d['senderId'] ==
                              FirebaseAuth.instance.currentUser?.uid;
                          final ts = (d['createdAt'] as Timestamp?)?.toDate();
                          if (isSystem) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _red.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    d['text'] ?? '',
                                    style: const TextStyle(
                                      color: _red,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                          return Align(
                            alignment: isMe
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.7,
                              ),
                              decoration: BoxDecoration(
                                color: isMe ? _navy : Colors.white,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                                  bottomRight: Radius.circular(isMe ? 4 : 16),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: isMe
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d['text'] ?? '',
                                    style: TextStyle(
                                      color: isMe ? Colors.white : _navy,
                                      fontSize: 14,
                                    ),
                                  ),
                                  if (ts != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: isMe
                                            ? Colors.white.withValues(
                                                alpha: 0.5,
                                              )
                                            : _navy.withValues(alpha: 0.4),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                if (!_resolved) _buildDistressButton(),
                if (!_resolved)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _msgController,
                            style: const TextStyle(color: _navy, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Describe your situation...',
                              hintStyle: TextStyle(
                                color: _navy.withValues(alpha: 0.35),
                              ),
                              filled: true,
                              fillColor: _cream,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _send,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: const BoxDecoration(
                              color: _red,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RidesPage extends StatelessWidget {
  const _RidesPage();
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Row(
            children: [
              const Text(
                'Ride History',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: _navy,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: db
                .collection('rides')
                .where('driverId', isEqualTo: uid)
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Error: ${snapshot.error}',
                    style: TextStyle(color: _red, fontSize: 13),
                  ),
                );
              }
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
                        color: _navy.withValues(alpha: 0.2),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No rides yet',
                        style: TextStyle(
                          color: _navy.withValues(alpha: 0.4),
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                );
              }
              final docs = snapshot.data!.docs;
              // weekly earnings: Monday 00:00 → now
              final now = DateTime.now();
              final weekStart = DateTime(
                now.year,
                now.month,
                now.day - (now.weekday - 1),
              );
              double totalEarnings = 0;
              for (final doc in docs) {
                final d = doc.data() as Map<String, dynamic>;
                if (d['status'] != 'completed') continue;
                final ts = (d['createdAt'] as Timestamp?)?.toDate();
                if (ts != null && ts.isBefore(weekStart)) continue;
                totalEarnings += (d['finalFare'] as num?)?.toDouble() ?? 0;
              }
              return Column(
                children: [
                  // Earnings summary card
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: _navy,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.payments_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'This Week\'s Earnings',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                'MWK ${totalEarnings.toStringAsFixed(0)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 20,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      itemCount: docs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final d = docs[i].data() as Map<String, dynamic>;
                        final ts = (d['createdAt'] as Timestamp?)?.toDate();
                        final status = (d['status'] ?? '') as String;
                        final fare = (d['finalFare'] as num?)?.toDouble();
                        final km = (d['distanceKm'] as num?)?.toDouble();
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
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
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
                                      color: status == 'completed'
                                          ? Colors.green.withValues(alpha: 0.1)
                                          : _red.withValues(alpha: 0.1),
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
                                        color: status == 'completed'
                                            ? Colors.green.shade700
                                            : _red,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Icon(
                                    Icons.person_outline,
                                    size: 13,
                                    color: _navy.withValues(alpha: 0.5),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      (d['passengerName'] as String? ?? '')
                                              .isNotEmpty
                                          ? d['passengerName']
                                          : 'Unknown passenger',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _navy.withValues(alpha: 0.6),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if ((d['passengerPhone'] as String? ?? '')
                                      .isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.phone_outlined,
                                      size: 13,
                                      color: _navy.withValues(alpha: 0.5),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      d['passengerPhone'],
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _navy.withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              if (fare != null || km != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    if (fare != null) ...[
                                      const Icon(
                                        Icons.payments_outlined,
                                        size: 13,
                                        color: Colors.green,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'MWK ${fare.toStringAsFixed(0)}',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.green,
                                        ),
                                      ),
                                    ],
                                    if (fare != null && km != null)
                                      const SizedBox(width: 12),
                                    if (km != null) ...[
                                      Icon(
                                        Icons.straighten,
                                        size: 13,
                                        color: _navy.withValues(alpha: 0.4),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${km.toStringAsFixed(1)} km',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: _navy.withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                              if (ts != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  '${ts.day}/${ts.month}/${ts.year}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _navy.withValues(alpha: 0.35),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DriverProfilePage extends StatefulWidget {
  final String name;
  final String? photoUrl;
  const _DriverProfilePage({required this.name, required this.photoUrl});

  @override
  State<_DriverProfilePage> createState() => _DriverProfilePageState();
}

class _DriverProfilePageState extends State<_DriverProfilePage> {
  Map<String, dynamic>? _data;
  int _totalRides = 0;
  double _rating = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final doc = await db.collection('drivers').doc(uid).get();
    final profileData = (doc.data() as Map<String, dynamic>?) ?? {};

    // Count completed rides and calculate rating
    final ridesSnap = await db
        .collection('rides')
        .where('driverId', isEqualTo: uid)
        .get();
    final completed = ridesSnap.docs
        .where((r) => (r.data()['status'] ?? '') == 'completed')
        .toList();
    double ratingSum = 0;
    int ratingCount = 0;
    for (final r in completed) {
      final rating = (r.data()['driverRating'] ?? 0).toDouble();
      if (rating > 0) { ratingSum += rating; ratingCount++; }
    }

    if (mounted) {
      setState(() {
        _data = profileData;
        _totalRides = completed.length;
        _rating = ratingCount > 0 ? ratingSum / ratingCount : 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null) {
      return const Center(child: CircularProgressIndicator(color: _navy));
    }

    final name = _data!['name'] ?? '';
    final email = _data!['email'] ?? '';
    final phone = _data!['phone'] ?? '';
    final photoUrl = _data!['photoUrl'] as String?;
    final createdAt = (_data!['createdAt'] as Timestamp?)?.toDate();
    final memberSince = createdAt != null
        ? '${_month(createdAt.month)} ${createdAt.year}'
        : 'N/A';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 16),

          // Avatar
          Center(
            child: Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _navy.withValues(alpha: 0.1),
                border: Border.all(
                  color: _navy.withValues(alpha: 0.2),
                  width: 2,
                ),
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

          const SizedBox(height: 16),
          Text(
            name,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: _navy,
            ),
          ),
          const SizedBox(height: 4),
          if (phone.isNotEmpty)
            Text(
              phone,
              style: TextStyle(
                fontSize: 14,
                color: _navy.withValues(alpha: 0.5),
              ),
            ),
          if (email.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              email,
              style: TextStyle(
                fontSize: 14,
                color: _navy.withValues(alpha: 0.5),
              ),
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
                      isDriver: true,
                    ),
                  ),
                );
                if (updated == true) _load();
              },
              icon: const Icon(Icons.edit_outlined, size: 16, color: _navy),
              label: const Text('Edit Profile', style: TextStyle(color: _navy)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _navy.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          // Info card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow(Icons.badge_outlined, 'Role', 'Driver'),
                const Divider(height: 24),
                _infoRow(
                  Icons.directions_car_rounded,
                  'Total Rides',
                  '$_totalRides',
                ),
                const Divider(height: 24),
                _infoRow(
                  Icons.star_rounded,
                  'Passenger Rating',
                  _rating > 0
                      ? '${_rating.toStringAsFixed(1)} / 5.0'
                      : 'No ratings yet',
                  iconColor: _rating > 0 ? Colors.amber : null,
                ),
                const Divider(height: 24),
                _infoRow(
                  Icons.calendar_today_outlined,
                  'Member Since',
                  memberSince,
                ),
                if ((_data!['phone'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(Icons.phone_outlined, 'Phone', _data!['phone']),
                ],
                if ((_data!['driverIdNumber'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(
                    Icons.fingerprint,
                    'ID Number',
                    _data!['driverIdNumber'],
                  ),
                ],
                if ((_data!['licenseNumber'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(
                    Icons.credit_card_outlined,
                    'Licence Number',
                    _data!['licenseNumber'],
                  ),
                ],
                if ((_data!['vehicleMake'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(
                    Icons.directions_car_outlined,
                    'Vehicle',
                    _data!['vehicleMake'],
                  ),
                ],
                if ((_data!['numberPlate'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(
                    Icons.pin_outlined,
                    'Plate Number',
                    _data!['numberPlate'],
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Settings
          _ProfileTile(
            icon: Icons.settings_outlined,
            title: 'Settings',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(height: 10),

          // Help Center
          _ProfileTile(
            icon: Icons.help_outline_rounded,
            title: 'Help Center',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HelpCenterScreen()),
            ),
          ),
          const SizedBox(height: 10),

          // Logout
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
              style: TextStyle(color: _navy.withValues(alpha: 0.6)),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                Navigator.pop(context);
                NotificationService.dispose();
                await FirebaseAuth.instance.signOut();
                await AuthPersistence.clearCredentials();
                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => AuthGate()),
                    (route) => false,
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Logout failed: $e')));
                }
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

  Widget _infoRow(
    IconData icon,
    String label,
    String value, {
    Color? iconColor,
  }) => Row(
    children: [
      Icon(icon, color: iconColor ?? _navy.withValues(alpha: 0.5), size: 20),
      const SizedBox(width: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: _navy.withValues(alpha: 0.4)),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _navy,
            ),
          ),
        ],
      ),
    ],
  );

  String _month(int m) => const [
    '',
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
  ][m];
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
                color: iconColor.withValues(alpha: 0.08),
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
              color: _navy.withValues(alpha: 0.3),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Commission Breakdown Sheet ──────────────────────────

class _CommissionSheet extends StatefulWidget {
  final double subscriptionOwed;
  final Map<String, dynamic>? driverData;
  const _CommissionSheet({
    required this.subscriptionOwed,
    required this.driverData,
  });
  @override
  State<_CommissionSheet> createState() => _CommissionSheetState();
}

class _CommissionSheetState extends State<_CommissionSheet> {
  double _rate = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRate();
  }

  Future<void> _loadRate() async {
    final doc = await db.collection('settings').doc('fare').get();
    if (mounted) {
      setState(() {
        _rate = (doc.data()?['subscriptionRate'] as num?)?.toDouble() ?? 0;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
      decoration: const BoxDecoration(
        color: _cream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _navy.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Commission Fee',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _navy,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Fast Ride charges a commission on every completed ride.',
            style: TextStyle(
              fontSize: 13,
              color: _navy.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Center(child: CircularProgressIndicator(color: _navy))
          else
            ..._buildRows(),
        ],
      ),
    );
  }

  List<Widget> _buildRows() => [
    _sheetRow('Commission Rate', '${_rate.toStringAsFixed(0)}% of each fare'),
    const SizedBox(height: 10),
    _sheetRow('Formula', 'Fare × $_rate% = Commission'),
    const SizedBox(height: 10),
    _sheetRow(
      'Example',
      'MWK 5,000 × $_rate% = MWK ${(5000 * _rate / 100).toStringAsFixed(0)}',
    ),
    const SizedBox(height: 16),
    Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: widget.subscriptionOwed > 0
            ? _red.withValues(alpha: 0.1)
            : Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.subscriptionOwed > 0
              ? _red.withValues(alpha: 0.3)
              : Colors.green.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Total Outstanding',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: widget.subscriptionOwed > 0 ? _red : Colors.green.shade700,
              fontSize: 14,
            ),
          ),
          Text(
            'MWK ${widget.subscriptionOwed.toStringAsFixed(0)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: widget.subscriptionOwed > 0 ? _red : Colors.green.shade700,
            ),
          ),
        ],
      ),
    ),
  ];

  Widget _sheetRow(String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 110,
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: _navy.withValues(alpha: 0.5)),
        ),
      ),
      Expanded(
        child: Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _navy,
          ),
        ),
      ),
    ],
  );
}

// ── Notification Bell ──────────────────────────────────────

class _NotificationBell extends StatelessWidget {
  const _NotificationBell();

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return StreamBuilder<QuerySnapshot>(
      stream: db
          .collection('notifications')
          .where('uid', isEqualTo: uid)
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final unread =
            snap.data?.docs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final type =
                  (data['type'] as String?)?.toLowerCase().trim() ?? '';
              final title =
                  (data['title'] as String?)?.toLowerCase().trim() ?? '';
              if (title.contains('ride request') ||
                  title.contains('new ride request')) {
                return false;
              }
              return type.isEmpty ||
                  type == 'notification' ||
                  type == 'ticket_reply';
            }).length ??
            0;
        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const NotificationsScreen()),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _navy.withValues(alpha: 0.1),
                  border: Border.all(
                    color: _navy.withValues(alpha: 0.15),
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.notifications_outlined,
                  color: _navy,
                  size: 22,
                ),
              ),
              if (unread > 0)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: _red,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    child: Text(
                      unread > 9 ? '9+' : '$unread',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ── Bottom Nav ───────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  const _BottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isMap = currentIndex == 1;
    return Container(
      color: isMap ? null : _cream,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: _navy,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: _navy.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavItem(
              icon: Icons.dashboard_outlined,
              label: 'Dashboard',
              index: 0,
              currentIndex: currentIndex,
              onTap: onTap,
            ),
            _NavItem(
              icon: Icons.map_outlined,
              label: 'Navigate',
              index: 1,
              currentIndex: currentIndex,
              onTap: onTap,
            ),
            _NavItem(
              icon: Icons.receipt_long_outlined,
              label: 'History',
              index: 2,
              currentIndex: currentIndex,
              onTap: onTap,
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

  const _NavItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = currentIndex == index;
    return GestureDetector(
      onTap: () => onTap(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isActive
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.4),
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
