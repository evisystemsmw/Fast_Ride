import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'db.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class HelpCenterScreen extends StatefulWidget {
  const HelpCenterScreen({super.key});

  @override
  State<HelpCenterScreen> createState() => _HelpCenterScreenState();
}

class _HelpCenterScreenState extends State<HelpCenterScreen> {
  final _subjectController = TextEditingController();
  final _messageController = TextEditingController();
  bool _submitting = false;
  String? _successMsg;
  String? _error;

  @override
  void dispose() {
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submitTicket() async {
    final subject = _subjectController.text.trim();
    final message = _messageController.text.trim();
    if (subject.isEmpty || message.isEmpty) {
      setState(() => _error = 'Please fill in all fields.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _successMsg = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await db.collection('support_tickets').add({
        'userId': uid,
        'subject': subject,
        'message': message,
        'status': 'open',
        'createdAt': FieldValue.serverTimestamp(),
      });
      _subjectController.clear();
      _messageController.clear();
      setState(() => _successMsg = 'Your message has been sent. We\'ll get back to you soon.');
    } catch (_) {
      setState(() => _error = 'Failed to send. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
          'Help Center',
          style: TextStyle(color: _navy, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),

            // FAQ section
            const Text(
              'Frequently Asked Questions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _navy),
            ),
            const SizedBox(height: 12),

            StreamBuilder<QuerySnapshot>(
              stream: db.collection('faqs').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('Error: ${snapshot.error}', style: const TextStyle(color: _red));
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: _navy));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return _emptyFaq();
                }
                return Column(
                  children: snapshot.data!.docs.map((doc) {
                    final d = doc.data() as Map<String, dynamic>;
                    return _FaqTile(
                      question: d['question'] ?? '',
                      answer: d['answer'] ?? '',
                    );
                  }).toList(),
                );
              },
            ),

            const SizedBox(height: 32),

            // Contact support section
            const Text(
              'Contact Support',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _navy),
            ),
            const SizedBox(height: 12),

            _field(_subjectController, 'Subject', Icons.subject_outlined),
            const SizedBox(height: 12),
            TextField(
              controller: _messageController,
              maxLines: 4,
              style: const TextStyle(color: _navy),
              decoration: InputDecoration(
                hintText: 'Describe your issue...',
                hintStyle: TextStyle(color: _navy.withOpacity(0.4)),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: _red, fontSize: 13)),
            ],
            if (_successMsg != null) ...[
              const SizedBox(height: 10),
              Text(_successMsg!, style: TextStyle(color: Colors.green.shade700, fontSize: 13)),
            ],

            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submitTicket,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _red.withOpacity(0.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Text('Send Message', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _emptyFaq() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          'No FAQs available yet.',
          style: TextStyle(color: _navy.withOpacity(0.5)),
        ),
      );

  Widget _field(TextEditingController controller, String hint, IconData icon) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: _navy),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _navy.withOpacity(0.4)),
        prefixIcon: Icon(icon, color: _navy.withOpacity(0.5)),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _FaqTile extends StatefulWidget {
  final String question;
  final String answer;
  const _FaqTile({required this.question, required this.answer});

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Text(
            widget.question,
            style: const TextStyle(color: _navy, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          trailing: Icon(
            _expanded ? Icons.remove : Icons.add,
            color: _red,
            size: 20,
          ),
          onExpansionChanged: (v) => setState(() => _expanded = v),
          children: [
            Text(
              widget.answer,
              style: TextStyle(color: _navy.withOpacity(0.7), fontSize: 14, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
