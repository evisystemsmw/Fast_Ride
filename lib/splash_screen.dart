import 'package:flutter/material.dart';
import 'dart:math';

class SplashScreen extends StatelessWidget {
  final bool noInternet;
  final VoidCallback? onRetry;

  const SplashScreen({super.key, this.noInternet = false, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7EAD9),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo
                  Image.asset(
                    'assets/fast_ride_logo_transparent.png',
                    width: 160,
                  ),
                  const SizedBox(height: 48),
                  // Loading or no-internet
                  if (noInternet) ...[
                    const Icon(
                      Icons.wifi_off_rounded,
                      color: Color(0xFF143B58),
                      size: 32,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No internet connection',
                      style: TextStyle(
                        color: Color(0xFF143B58),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Please connect to the internet to continue.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF143B58), fontSize: 13),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF143B58),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ] else
                    const _PendulumDots(),
                ],
              ),
            ),
          ),
          // Bottom powered-by text
          const Padding(
            padding: EdgeInsets.only(bottom: 32),
            child: Text(
              'Powered by Evisystemsmw',
              style: TextStyle(
                color: Color(0xFF143B58),
                fontSize: 11,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendulumDots extends StatefulWidget {
  const _PendulumDots();

  @override
  State<_PendulumDots> createState() => _PendulumDotsState();
}

class _PendulumDotsState extends State<_PendulumDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_controller.value + i / 3) % 1.0;
            final offset = -sin(t * 2 * pi) * 8.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Transform.translate(
                offset: Offset(0, offset),
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF143B58),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
