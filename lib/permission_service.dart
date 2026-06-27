import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> requestAppPermissions(BuildContext context) async {
  // 1. Notifications
  final notif = await Permission.notification.status;
  if (notif.isDenied) await Permission.notification.request();

  // 2. Precise location (required before background)
  final loc = await Permission.locationWhenInUse.status;
  if (loc.isDenied) await Permission.locationWhenInUse.request();

  // 3. Background location — only ask if foreground was granted
  final locGranted = await Permission.locationWhenInUse.isGranted;
  if (locGranted) {
    final bg = await Permission.locationAlways.status;
    if (bg.isDenied) {
      if (context.mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Background Location'),
            content: const Text(
              'Fast Ride needs background location to track your trip and show your position to passengers even when the app is minimised.\n\nOn the next screen, please select "Allow all the time".',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Skip'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
      }
      await Permission.locationAlways.request();
    }
  }

  // 4. If any critical permission is permanently denied, open settings
  final notifDenied = await Permission.notification.isPermanentlyDenied;
  final locDenied   = await Permission.locationWhenInUse.isPermanentlyDenied;
  if ((notifDenied || locDenied) && context.mounted) {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Permissions Required'),
        content: const Text(
          'Notifications and location are required for Fast Ride to work properly. Please enable them in app settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }
}
