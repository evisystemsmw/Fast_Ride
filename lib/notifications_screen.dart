import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'db.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<QueryDocumentSnapshot> _docs = [];
  bool _loading = true;
  StreamSubscription? _userSub;
  StreamSubscription? _userIdSub;
  StreamSubscription? _broadcastSub;
  final Map<String, QueryDocumentSnapshot> _userUidDocMap = {};
  final Map<String, QueryDocumentSnapshot> _userIdDocMap = {};
  final Map<String, QueryDocumentSnapshot> _broadcastDocMap = {};

  bool _isNotificationDoc(Map<String, dynamic> data) {
    final type = (data['type'] as String?)?.toLowerCase().trim() ?? '';
    final title = (data['title'] as String?)?.toLowerCase().trim() ?? '';
    if (title.contains('ride request') || title.contains('new ride request')) {
      return false;
    }
    const allowedTypes = {'notification', 'ticket_reply'};
    return type.isEmpty || allowedTypes.contains(type);
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  Future<void> _listen() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    void merge() {
      final combined = {
        ..._userUidDocMap,
        ..._userIdDocMap,
        ..._broadcastDocMap,
      };
      final sorted = combined.values.toList()
        ..sort((a, b) {
          final at = (a['createdAt'] as Timestamp?)?.toDate() ?? DateTime(0);
          final bt = (b['createdAt'] as Timestamp?)?.toDate() ?? DateTime(0);
          return bt.compareTo(at);
        });
      if (mounted) {
        setState(() {
          _docs = sorted;
          _loading = false;
        });
      }
    }

    final userDoc = await db.collection('users').doc(uid).get();
    final role = (userDoc.data()?['role'] as String?)?.toLowerCase();
    final driverDoc = await db.collection('drivers').doc(uid).get();
    final isDriver = role == 'driver' || driverDoc.exists;
    final isStaff = !isDriver && role == 'staff';
    final broadcastTargets = isDriver
        ? ['all', 'All', 'drivers', 'Drivers', 'driver', 'Driver']
        : isStaff
        ? ['all', 'All', 'staff', 'Staff']
        : ['all', 'All', 'passengers', 'Passengers', 'passenger', 'Passenger'];

    _userSub = db
        .collection('notifications')
        .where('uid', isEqualTo: uid)
        .snapshots()
        .listen(
          (snap) {
            _userUidDocMap.clear();
            for (final doc in snap.docs) {
              final data = doc.data();
              final title = (data['title'] as String?)?.trim();
              if (title == null || title.isEmpty) continue;
              if (!_isNotificationDoc(data)) continue;
              _userUidDocMap[doc.id] = doc;
            }
            merge();
          },
          onError: (e) {
            if (mounted) setState(() => _loading = false);
          },
        );

    _userIdSub = db
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .listen(
          (snap) {
            _userIdDocMap.clear();
            for (final doc in snap.docs) {
              final data = doc.data();
              final title = (data['title'] as String?)?.trim();
              if (title == null || title.isEmpty) continue;
              if (!_isNotificationDoc(data)) continue;
              _userIdDocMap[doc.id] = doc;
            }
            merge();
          },
          onError: (e) {
            if (mounted) setState(() => _loading = false);
          },
        );

    _broadcastSub = db
        .collection('notifications')
        .where('target', whereIn: broadcastTargets)
        .snapshots()
        .listen(
          (snap) {
            _broadcastDocMap.clear();
            for (final doc in snap.docs) {
              final data = doc.data();
              final title = (data['title'] as String?)?.trim();
              if (title == null || title.isEmpty) continue;
              if (!_isNotificationDoc(data)) continue;
              _broadcastDocMap[doc.id] = doc;
            }
            merge();
          },
          onError: (e) {
            if (mounted) setState(() => _loading = false);
          },
        );
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _userIdSub?.cancel();
    _broadcastSub?.cancel();
    super.dispose();
  }

  Future<void> _markAllRead(String uid) async {
    for (final doc in _docs) {
      final data = doc.data() as Map<String, dynamic>;
      final isRead = (data['isRead'] ?? data['read']) == true;
      if (!isRead) doc.reference.update({'isRead': true, 'read': true});
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _cream,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _navy),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Notifications',
          style: TextStyle(color: _navy, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () => _markAllRead(uid),
            child: const Text(
              'Mark all read',
              style: TextStyle(color: _red, fontSize: 13),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _navy))
          : _docs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_off_outlined,
                    size: 56,
                    color: _navy.withOpacity(0.2),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No notifications yet',
                    style: TextStyle(
                      color: _navy.withOpacity(0.4),
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              itemCount: _docs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final doc = _docs[i];
                final d = doc.data() as Map<String, dynamic>;
                return _NotifTile(doc: doc, data: d);
              },
            ),
    );
  }
}

class _NotifTile extends StatefulWidget {
  final QueryDocumentSnapshot doc;
  final Map<String, dynamic> data;
  const _NotifTile({required this.doc, required this.data});

  @override
  State<_NotifTile> createState() => _NotifTileState();
}

class _NotifTileState extends State<_NotifTile> {
  bool _expanded = false;

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final isRead = (d['isRead'] ?? d['read']) == true;
    final ts = (d['createdAt'] as Timestamp?)?.toDate();
    final body = (d['body'] ?? '') as String;

    return GestureDetector(
      onTap: () {
        setState(() => _expanded = !_expanded);
        if (!isRead) {
          widget.doc.reference.update({'isRead': true, 'read': true});
        }
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isRead ? Colors.white : _navy.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: isRead ? null : Border.all(color: _navy.withOpacity(0.1)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isRead ? _navy.withOpacity(0.06) : _red.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.notifications_outlined,
                color: isRead ? _navy.withOpacity(0.4) : _red,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d['title'] ?? '',
                    style: TextStyle(
                      color: _navy,
                      fontWeight: isRead ? FontWeight.w500 : FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      body,
                      maxLines: _expanded ? null : 2,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _navy.withOpacity(0.6),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _expanded ? 'Show less' : 'Read more',
                      style: const TextStyle(
                        color: _red,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (ts != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _timeAgo(ts),
                      style: TextStyle(
                        color: _navy.withOpacity(0.35),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!isRead)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 4),
                decoration: const BoxDecoration(
                  color: _red,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
