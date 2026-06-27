import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'db.dart';
import 'login_screen.dart';
import 'edit_profile_screen.dart';
import 'driver_navigation_screen.dart';
import 'settings_screen.dart';
import 'help_center_screen.dart';
import 'booking_detail_screen.dart';
import 'fcm_service.dart';

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
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadUser();
    // When driver taps a ride request notification, jump to Navigate tab
    onRideRequestTap = (rideId) {
      if (mounted) setState(() => _currentIndex = 1);
    };
    // consume any rideId that arrived while app was launching from killed state
    if (pendingRideId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _currentIndex = 1);
        consumePendingRideId();
      });
    }
  }

  @override
  void dispose() {
    onRideRequestTap = null;
    super.dispose();
  }

  Future<void> _loadUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // try drivers collection first, fall back to users
    DocumentSnapshot doc = await db.collection('drivers').doc(uid).get();
    if (!doc.exists) doc = await db.collection('users').doc(uid).get();
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

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Logout',
            style: TextStyle(color: _navy, fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(color: _navy)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: _navy.withOpacity(0.6))),
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
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  List<Widget> get _pages => [
        const _DashboardPage(),
        DriverNavigationScreen(
          onRideAccepted: () => setState(() => _currentIndex = 1),
        ),
        const _RidesPage(),
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
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _greeting,
                          style: TextStyle(
                              fontSize: 14, color: _navy.withOpacity(0.5)),
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
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _navy.withOpacity(0.1),
                        border: Border.all(
                            color: _navy.withOpacity(0.15), width: 2),
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
                                _name.isNotEmpty
                                    ? _name[0].toUpperCase()
                                    : '?',
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
              child: IndexedStack(
                index: _currentIndex,
                children: _pages,
              ),
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
  bool _toggling = false;
  Map<String, dynamic>? _driverData;
  double _totalDistance = 0;
  double _subscriptionOwed = 0;
  StreamSubscription? _driverSub;

  @override
  void initState() {
    super.initState();
    _loadFaresAndListen();
  }

  @override
  void dispose() {
    _driverSub?.cancel();
    super.dispose();
  }

  Future<void> _loadFaresAndListen() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _driverSub = db.collection('drivers').doc(uid).snapshots().listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data() as Map<String, dynamic>;
      final totalKm = (data['subscriptionKm'] as num?)?.toDouble() ?? 0;
      final balance = (data['subscriptionBalance'] as num?)?.toDouble() ?? 0;
      setState(() {
        _isOnline = data['isOnline'] == true;
        _driverData = data;
        _totalDistance = totalKm;
        _subscriptionOwed = balance;
      });
    });
  }

  Future<void> _toggleOnline() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() => _toggling = true);
    final newStatus = !_isOnline;
    await db.collection('drivers').doc(uid).update({'isOnline': newStatus});
    if (mounted) setState(() { _isOnline = newStatus; _toggling = false; });
  }

  @override
  Widget build(BuildContext context) {
    final sub = _driverData?['subscriptionFee'];
    final subDue = _driverData?['subscriptionDueDate'] as Timestamp?;
    final subStatus = (_driverData?['subscriptionStatus'] ?? 'unknown') as String;
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: _isOnline ? Colors.green : _navy.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _isOnline ? 'Online' : 'Offline',
                          style: const TextStyle(
                              color: _navy, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      _toggling
                          ? const SizedBox(
                              width: 28, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: _navy),
                            )
                          : Transform.scale(
                              scale: 0.8,
                              child: Switch(
                                value: _isOnline,
                                onChanged: (_) => _toggleOnline(),
                                activeColor: Colors.green,
                                inactiveThumbColor: _navy.withOpacity(0.4),
                                inactiveTrackColor: _navy.withOpacity(0.1),
                              ),
                            ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const _DriverSosScreen())),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: _red, borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.sos_rounded, color: Colors.white, size: 18),
                      SizedBox(width: 6),
                      Text('SOS', style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Amount owed
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: _navy.withOpacity(0.08), shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.receipt_outlined, color: _navy, size: 18),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Amount Owed',
                      style: TextStyle(
                          color: _navy, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
                Text('MWK ${_subscriptionOwed.toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: _red, fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Incoming bookings
          const Text('Incoming Bookings',
              style: TextStyle(color: _navy, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          // Incoming bookings — only rides requested for this driver
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseAuth.instance.currentUser == null
                ? const Stream.empty()
                : db.collection('rides')
                    .where('driverId', isEqualTo: uid)
                    .where('status', isEqualTo: 'requested')
                    .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator(color: _navy));
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white, borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text('No incoming bookings',
                      style: TextStyle(color: _navy.withOpacity(0.4), fontSize: 13)),
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
                            ? Colors.green.withOpacity(0.4)
                            : _navy.withOpacity(0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.location_on_outlined, color: _red, size: 16),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${d['pickup'] ?? ''} → ${d['destination'] ?? ''}',
                                style: const TextStyle(
                                    color: _navy, fontWeight: FontWeight.bold, fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if ((d['passengerName'] ?? '').toString().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(Icons.person_outline, color: _navy.withOpacity(0.5), size: 14),
                              const SizedBox(width: 4),
                              Text(d['passengerName'],
                                  style: TextStyle(color: _navy.withOpacity(0.6), fontSize: 12)),
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
                                builder: (_) => BookingDetailScreen(rideId: doc.id, ride: d),
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _navy,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('View & Calculate Fare',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
          const Text('In Progress',
              style: TextStyle(color: _navy, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseAuth.instance.currentUser == null ? const Stream.empty() : db.collection('rides')
                .where('driverId', isEqualTo: uid)
                .where('status', isEqualTo: 'accepted')
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator(color: _navy));
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white, borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text('No rides in progress',
                      style: TextStyle(color: _navy.withOpacity(0.4), fontSize: 13)),
                );
              }
              return Column(
                children: docs.map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _navy, borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.directions_car_rounded,
                                color: Colors.white, size: 16),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${d['pickup'] ?? ''} → ${d['destination'] ?? ''}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text('In Progress',
                                  style: TextStyle(
                                      color: Colors.green,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if ((d['passengerName'] ?? '').toString().isNotEmpty)
                          Row(
                            children: [
                              Icon(Icons.person_outline,
                                  color: Colors.white.withOpacity(0.6), size: 14),
                              const SizedBox(width: 4),
                              Text(d['passengerName'],
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.7),
                                      fontSize: 12)),
                            ],
                          ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () async {
                              await doc.reference.update({'status': 'completed'});
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Complete Ride',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 13)),
                          ),
                        ),
                      ],
                    ),
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

  @override
  void initState() {
    super.initState();
    _createSos();
  }

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _createSos() async {
    setState(() => _creating = true);
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final doc = await db.collection('drivers').doc(uid).get();
    final name = (doc.data() as Map<String, dynamic>?)?['name'] ?? 'Driver';
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
    if (mounted) setState(() { _sosId = ref.id; _creating = false; });
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
            Text('SOS Emergency',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          if (!_resolved && _sosId != null)
            TextButton(
              onPressed: _resolve,
              child: const Text('Resolve',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
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
                  color: _resolved ? Colors.green.shade600 : _red.withOpacity(0.9),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _resolved ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                        color: Colors.white, size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _resolved ? 'SOS Resolved — You are safe' : 'SOS Active — Support has been notified',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
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
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: docs.length,
                        itemBuilder: (context, i) {
                          final d = docs[i].data() as Map<String, dynamic>;
                          final isSystem = d['isSystem'] == true;
                          final isMe = d['senderId'] == FirebaseAuth.instance.currentUser?.uid;
                          final ts = (d['createdAt'] as Timestamp?)?.toDate();
                          if (isSystem) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _red.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(d['text'] ?? '',
                                      style: const TextStyle(
                                          color: _red, fontSize: 12, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            );
                          }
                          return Align(
                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width * 0.7),
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
                                crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                children: [
                                  Text(d['text'] ?? '',
                                      style: TextStyle(
                                          color: isMe ? Colors.white : _navy, fontSize: 14)),
                                  if (ts != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: isMe ? Colors.white.withOpacity(0.5) : _navy.withOpacity(0.4)),
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
                if (!_resolved)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _msgController,
                            style: const TextStyle(color: _navy, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Describe your situation...',
                              hintStyle: TextStyle(color: _navy.withOpacity(0.35)),
                              filled: true,
                              fillColor: _cream,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                            decoration: const BoxDecoration(color: _red, shape: BoxShape.circle),
                            child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
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
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: TextStyle(color: _red, fontSize: 13)),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: _navy));
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.directions_car_outlined,
                    size: 56, color: _navy.withOpacity(0.2)),
                const SizedBox(height: 12),
                Text('No rides yet',
                    style: TextStyle(
                        color: _navy.withOpacity(0.4), fontSize: 15)),
              ],
            ),
          );
        }
        final docs = snapshot.data!.docs;
        return ListView.separated(
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            final ts = (d['createdAt'] as Timestamp?)?.toDate();
            final status = (d['status'] ?? '') as String;
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
                              fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: status == 'completed'
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
                            color: status == 'completed'
                                ? Colors.green.shade700
                                : _red,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (ts != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${ts.day}/${ts.month}/${ts.year}',
                      style: TextStyle(
                          fontSize: 11, color: _navy.withOpacity(0.35)),
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
    try {
      DocumentSnapshot userDoc = await db.collection('drivers').doc(uid).get();
      if (!userDoc.exists) userDoc = await db.collection('users').doc(uid).get();
      final ridesSnap = await db.collection('rides').where('driverId', isEqualTo: uid).get();
      final completed = ridesSnap.docs.where((r) => (r.data()['status'] ?? '') == 'completed').toList();
      double ratingSum = 0;
      int ratingCount = 0;
      for (final r in completed) {
        final rating = (r.data()['driverRating'] ?? 0).toDouble();
        if (rating > 0) { ratingSum += rating; ratingCount++; }
      }
      if (mounted) {
        setState(() {
          _data = (userDoc.data() as Map<String, dynamic>?) ?? {};
          _totalRides = completed.length;
          _rating = ratingCount > 0 ? ratingSum / ratingCount : 0;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _data = {});
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
                color: _navy.withOpacity(0.1),
                border: Border.all(color: _navy.withOpacity(0.2), width: 2),
                image: photoUrl != null
                    ? DecorationImage(
                        image: NetworkImage(photoUrl), fit: BoxFit.cover)
                    : null,
              ),
              child: photoUrl == null
                  ? Center(
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: _navy),
                      ),
                    )
                  : null,
            ),
          ),

          const SizedBox(height: 16),
          Text(name,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _navy)),
          const SizedBox(height: 4),
          if (phone.isNotEmpty)
            Text(phone,
                style: TextStyle(
                    fontSize: 14, color: _navy.withOpacity(0.5))),
          if (email.isNotEmpty) ...[  
            const SizedBox(height: 2),
            Text(email,
                style: TextStyle(
                    fontSize: 14, color: _navy.withOpacity(0.5))),
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
              label: const Text('Edit Profile',
                  style: TextStyle(color: _navy)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _navy.withOpacity(0.3)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
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
                _infoRow(Icons.directions_car_rounded, 'Total Rides', '$_totalRides'),
                const Divider(height: 24),
                _infoRow(Icons.star_rounded, 'Passenger Rating',
                    _rating > 0 ? '${_rating.toStringAsFixed(1)} / 5.0' : 'No ratings yet',
                    iconColor: _rating > 0 ? Colors.amber : null),
                const Divider(height: 24),
                _infoRow(Icons.calendar_today_outlined, 'Member Since', memberSince),
                if ((_data!['phone'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(Icons.phone_outlined, 'Phone', _data!['phone']),
                ],
                if ((_data!['driverIdNumber'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(Icons.fingerprint, 'ID Number', _data!['driverIdNumber']),
                ],
                if ((_data!['licenseNumber'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(Icons.credit_card_outlined, 'Licence Number', _data!['licenseNumber']),
                ],
                if ((_data!['vehicleMake'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(Icons.directions_car_outlined, 'Vehicle', _data!['vehicleMake']),
                ],
                if ((_data!['numberPlate'] ?? '').toString().isNotEmpty) ...[
                  const Divider(height: 24),
                  _infoRow(Icons.pin_outlined, 'Plate Number', _data!['numberPlate']),
                ],
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Settings
          _ProfileTile(
            icon: Icons.settings_outlined,
            title: 'Settings',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(height: 10),

          // Help Center
          _ProfileTile(
            icon: Icons.help_outline_rounded,
            title: 'Help Center',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const HelpCenterScreen())),
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
        title: const Text('Logout',
            style: TextStyle(color: _navy, fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(color: _navy)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: TextStyle(color: _navy.withOpacity(0.6))),
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
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, {Color? iconColor}) => Row(
        children: [
          Icon(icon, color: iconColor ?? _navy.withOpacity(0.5), size: 20),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 11, color: _navy.withOpacity(0.4))),
              Text(value,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _navy)),
            ],
          ),
        ],
      );

  String _month(int m) => const [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
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
                color: iconColor.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      color: titleColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 15)),
            ),
            Icon(Icons.arrow_forward_ios,
                color: _navy.withOpacity(0.3), size: 16),
          ],
        ),
      ),
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
              color: _navy.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavItem(icon: Icons.dashboard_outlined, label: 'Dashboard', index: 0, currentIndex: currentIndex, onTap: onTap),
            _NavItem(icon: Icons.map_outlined, label: 'Navigate', index: 1, currentIndex: currentIndex, onTap: onTap),
            _NavItem(icon: Icons.receipt_long_outlined, label: 'History', index: 2, currentIndex: currentIndex, onTap: onTap),
            _NavItem(icon: Icons.person_outline_rounded, label: 'Profile', index: 3, currentIndex: currentIndex, onTap: onTap),
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
              ? Colors.white.withOpacity(0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(icon,
                color: isActive
                    ? Colors.white
                    : Colors.white.withOpacity(0.4),
                size: 22),
            if (isActive) ...[
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    );
  }
}
