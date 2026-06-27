import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

FirebaseFirestore get db => FirebaseFirestore.instance;

Future<T> dbRetry<T>(Future<T> Function() fn, {int maxAttempts = 4}) async {
  int attempt = 0;
  while (true) {
    try {
      return await fn();
    } on FirebaseException catch (e) {
      if (e.code != 'unavailable' || attempt >= maxAttempts - 1) rethrow;
      await Future.delayed(Duration(seconds: 1 << attempt));
      attempt++;
    }
  }
}
