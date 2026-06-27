import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final user = await db.collection('users').doc(uid).get();
    final name = user.data()?['name'] ?? 'Passenger';

    final doc = await db.collection('sos_chats').add({
      'passengerId': uid,
      'passengerName': name,
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });

    // Auto first message
    await db.collection('sos_chats').doc(doc.id).collection('messages').add({
      'senderId': uid,
      'text': '🚨 SOS Alert triggered by $name',
      'createdAt': FieldValue.serverTimestamp(),
      'isSystem': true,
    });

    if (mounted) setState(() { _sosId = doc.id; _creating = false; });
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
                // Status banner
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
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),

                // Messages
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
                            child: CircularProgressIndicator(color: _navy));
                      }
                      final docs = snapshot.data?.docs ?? [];
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _scrollToBottom());
                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        itemCount: docs.length,
                        itemBuilder: (context, i) {
                          final d =
                              docs[i].data() as Map<String, dynamic>;
                          final isSystem = d['isSystem'] == true;
                          final isMe = d['senderId'] ==
                              FirebaseAuth.instance.currentUser!.uid;
                          final ts =
                              (d['createdAt'] as Timestamp?)?.toDate();

                          if (isSystem) {
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _red.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    d['text'] ?? '',
                                    style: const TextStyle(
                                        color: _red,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600),
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
                                  horizontal: 14, vertical: 10),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.7,
                              ),
                              decoration: BoxDecoration(
                                color: isMe ? _navy : Colors.white,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft:
                                      Radius.circular(isMe ? 16 : 4),
                                  bottomRight:
                                      Radius.circular(isMe ? 4 : 16),
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
                                      color: isMe
                                          ? Colors.white
                                          : _navy,
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

                // Input
                if (!_resolved)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _msgController,
                            style:
                                const TextStyle(color: _navy, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Describe your situation...',
                              hintStyle: TextStyle(
                                  color: _navy.withOpacity(0.35),
                                  fontSize: 14),
                              filled: true,
                              fillColor: _cream,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
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
                            child: const Icon(Icons.send_rounded,
                                color: Colors.white, size: 20),
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
