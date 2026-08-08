import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'help_center_screen.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class DriverStatusScreen extends StatelessWidget {
  final String status; // 'pending' | 'suspended' | 'blocked'
  const DriverStatusScreen({super.key, required this.status});

  bool get _isPending => status == 'pending';
  bool get _isBlocked => status == 'blocked';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: (_isPending ? _navy : _red).withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isPending ? Icons.hourglass_top_rounded : Icons.block_rounded,
                  color: _isPending ? _navy : _red,
                  size: 52,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                _isPending
                    ? 'Verification Pending'
                    : _isBlocked
                    ? 'Account Blocked'
                    : 'Account Suspended',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: _isPending ? _navy : _red,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _isPending
                    ? 'Your driver account is currently under review. Our team is verifying your documents. You will be notified once approved.'
                    : _isBlocked
                    ? 'Your driver account has been blocked. Please contact support for assistance.'
                    : 'Your driver account has been suspended. Please contact support for more information.',
                style: TextStyle(fontSize: 14, color: _navy.withOpacity(0.55), height: 1.6),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_isPending) ...[
                      _InfoRow(Icons.badge_outlined, 'ID document submitted'),
                      const SizedBox(height: 12),
                      _InfoRow(Icons.credit_card_outlined, 'Licence submitted'),
                      const SizedBox(height: 12),
                      _InfoRow(Icons.directions_car_outlined, 'Vehicle details submitted'),
                      const SizedBox(height: 12),
                      _InfoRow(Icons.access_time_rounded, 'Awaiting admin approval'),
                    ] else if (_isBlocked) ...[
                      _InfoRow(Icons.block_rounded, 'Account blocked due to policy review', iconColor: _red),
                      const SizedBox(height: 12),
                      _InfoRow(Icons.support_agent_rounded, 'Contact: support@fastride.com', iconColor: _red),
                      const SizedBox(height: 12),
                      _InfoRow(Icons.phone_outlined, '+265 999 000 000', iconColor: _red),
                    ] else ...[
                      _InfoRow(Icons.support_agent_rounded, 'Contact: support@fastride.com', iconColor: _red),
                      const SizedBox(height: 12),
                      _InfoRow(Icons.phone_outlined, '+265 999 000 000', iconColor: _red),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HelpCenterScreen()),
                  ),
                  icon: const Icon(Icons.support_agent_rounded, size: 18),
                  label: const Text('Contact Help Center'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isPending ? _navy : _red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await FirebaseAuth.instance.signOut();
                  },
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: const Text('Sign Out'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _navy,
                    side: BorderSide(color: _navy.withOpacity(0.3)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? iconColor;
  const _InfoRow(this.icon, this.text, {this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor ?? Colors.green, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(color: _navy, fontSize: 13))),
      ],
    );
  }
}
