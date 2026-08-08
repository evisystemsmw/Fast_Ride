import 'package:flutter/material.dart';

class SplashScreen extends StatelessWidget {
  final bool noInternet;
  final VoidCallback? onRetry;

  const SplashScreen({super.key, this.noInternet = false, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7EAD9),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Image(
              image: AssetImage('assets/fast_ride_logo_transparent.png'),
              width: 200,
            ),
            const SizedBox(height: 24),
            if (noInternet) ...[
              const Icon(Icons.wifi_off_rounded, color: Color(0xFF143B58), size: 32),
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
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF143B58),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
