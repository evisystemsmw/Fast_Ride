import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'map_service.dart';
import 'db.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();

  String? _sosId;
  bool _creating = false;
  bool _resolved = false;
  bool _distressSent = false;
  bool _distressSending = false;

  // press-and-hold state
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
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // Resume existing unresolved SOS if one exists
    final existing = await db
        .collection('sos_chats')
        .where('passengerId', isEqualTo: uid)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();

    if (existing.docs.isNotEmpty) {
      final existingDoc = existing.docs.first;
      final distressSent = existingDoc.data()['distressSent'] == true;
      if (mounted) {
        setState(() {
          _sosId = existingDoc.id;
          _distressSent = distressSent;
          _creating = false;
        });
      }
      return;
    }

    final user = await db.collection('users').doc(uid).get();
    final name = user.data()?['name'] ?? 'Passenger';

    final doc = await db.collection('sos_chats').add({
      'passengerId': uid,
      'passengerName': name,
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });

    await db.collection('sos_chats').doc(doc.id).collection('messages').add({
      'senderId': uid,
      'text': '🚨 SOS Alert triggered by $name',
      'createdAt': FieldValue.serverTimestamp(),
      'isSystem': true,
    });

    if (mounted)
      setState(() {
        _sosId = doc.id;
        _creating = false;
      });
  }

  Future<void> _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _sosId == null) return;
    _msgController.clear();
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await db.collection('sos_chats').doc(_sosId).collection('messages').add({
      'senderId': uid,
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
      'isSystem': false,
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
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
    HapticFeedback.mediumImpact();
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
    HapticFeedback.heavyImpact();
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
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
      _scrollToBottom();
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
                    child: Container(color: Colors.white.withOpacity(0.25)),
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
                          color: Colors.white.withOpacity(0.75),
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
                      : _red.withOpacity(0.9),
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
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: CircularProgressIndicator(color: _navy),
                        );
                      }
                      final docs = snapshot.data?.docs ?? [];
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _scrollToBottom(),
                      );
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
                              FirebaseAuth.instance.currentUser!.uid;
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
                                    color: _red.withOpacity(0.1),
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
                                            ? Colors.white.withOpacity(0.5)
                                            : _navy.withOpacity(0.4),
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
                                color: _navy.withOpacity(0.35),
                                fontSize: 14,
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
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _sendMessage,
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
