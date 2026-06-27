import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'db.dart';

const _navy = Color(0xFF143B58);
const _cream = Color(0xFFF7EAD9);

class PolicyScreen extends StatefulWidget {
  final String title;
  final String docId;

  const PolicyScreen({super.key, required this.title, required this.docId});

  @override
  State<PolicyScreen> createState() => _PolicyScreenState();
}

class _PolicyScreenState extends State<PolicyScreen> {
  List<Map<String, String>> _sections = [];
  String? _updatedAt;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await db
          .collection('legal')
          .doc(widget.docId)
          .get();
      if (doc.exists && mounted) {
        final data = doc.data()!;
        final ts = data['updatedAt'] as Timestamp?;
        final raw = data['sections'] as List<dynamic>? ?? [];
        setState(() {
          _sections = raw
              .map((e) => {
                    'title': (e['title'] ?? '') as String,
                    'body': (e['body'] ?? '') as String,
                  })
              .toList();
          _updatedAt = ts != null ? _formatDate(ts.toDate()) : null;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  String _formatDate(DateTime d) =>
      '${d.day} ${_month(d.month)} ${d.year}';

  String _month(int m) => const [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ][m];

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
        title: Text(widget.title,
            style: const TextStyle(color: _navy, fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _navy))
          : _error
              ? Center(
                  child: Text('Failed to load content.',
                      style: TextStyle(color: _navy.withOpacity(0.5))),
                )
              : _sections.isEmpty
                  ? Center(
                      child: Text('No content available.',
                          style: TextStyle(color: _navy.withOpacity(0.5))),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      itemCount: _sections.length + 1, // +1 for header
                      separatorBuilder: (_, __) => const SizedBox(height: 16),
                      itemBuilder: (_, i) {
                        if (i == 0) {
                          return _updatedAt != null
                              ? Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    'Last updated: $_updatedAt',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: _navy.withOpacity(0.4)),
                                  ),
                                )
                              : const SizedBox.shrink();
                        }
                        final s = _sections[i - 1];
                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s['title']!,
                                style: const TextStyle(
                                  color: _navy,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                s['body']!,
                                style: TextStyle(
                                  color: _navy.withOpacity(0.75),
                                  fontSize: 14,
                                  height: 1.6,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
    );
  }
}
