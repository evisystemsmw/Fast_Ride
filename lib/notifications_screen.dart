import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'db.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // two separate streams: user-specific + broadcast
    final userStream = db
        .collection('notifications')
        .where('uid', isEqualTo: uid)
        .snapshots();

    final allStream = db
        .collection('notifications')
        .where('target', isEqualTo: 'all')
        .snapshots();

    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _cream,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _navy),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Notifications',
            style: TextStyle(color: _navy, fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: () => _markAllRead(uid),
            child: const Text('Mark all read',
                style: TextStyle(color: _red, fontSize: 13)),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: userStream,
        builder: (context, userSnap) {
          return StreamBuilder<QuerySnapshot>(
            stream: allStream,
            builder: (context, allSnap) {
              if (userSnap.connectionState == ConnectionState.waiting ||
                  allSnap.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(color: _navy));
              }

              // merge and sort by createdAt
              final docs = [
                ...?userSnap.data?.docs,
                ...?allSnap.data?.docs,
              ]..sort((a, b) {
                  final at = (a['createdAt'] as Timestamp?)?.toDate() ??
                      DateTime(0);
                  final bt = (b['createdAt'] as Timestamp?)?.toDate() ??
                      DateTime(0);
                  return bt.compareTo(at);
                });

              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_off_outlined,
                          size: 56, color: _navy.withOpacity(0.2)),
                      const SizedBox(height: 12),
                      Text('No notifications yet',
                          style: TextStyle(
                              color: _navy.withOpacity(0.4), fontSize: 15)),
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final doc = docs[i];
                  final d = doc.data() as Map<String, dynamic>;
                  return _NotifTile(doc: doc, data: d);
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _markAllRead(String uid) async {
    final fs = db;
    // mark user-specific
    final userSnap = await fs
        .collection('notifications')
        .where('uid', isEqualTo: uid)
        .where('isRead', isEqualTo: false)
        .get();
    for (final doc in userSnap.docs) {
      doc.reference.update({'isRead': true});
    }
    // mark broadcast
    final allSnap = await fs
        .collection('notifications')
        .where('target', isEqualTo: 'all')
        .where('isRead', isEqualTo: false)
        .get();
    for (final doc in allSnap.docs) {
      doc.reference.update({'isRead': true});
    }
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
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
    final isRead = d['isRead'] == true;
    final ts = (d['createdAt'] as Timestamp?)?.toDate();
    final body = (d['body'] ?? '') as String;

    return GestureDetector(
      onTap: () {
        setState(() => _expanded = !_expanded);
        if (!isRead) widget.doc.reference.update({'isRead': true});
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
                      overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _navy.withOpacity(0.6),
                          fontSize: 13,
                          height: 1.4),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _expanded ? 'Show less' : 'Read more',
                      style: const TextStyle(
                          color: _red,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                  if (ts != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _timeAgo(ts),
                      style: TextStyle(
                          color: _navy.withOpacity(0.35), fontSize: 11),
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
                decoration:
                    const BoxDecoration(color: _red, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }
}
