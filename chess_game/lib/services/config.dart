import 'package:flutter/foundation.dart';

class AppConfig {
  static String get baseUrl {
    if (kIsWeb) return 'http://127.0.0.1:8000/api/auth/';
    if (defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:8000/api/auth/';
    return 'http://127.0.0.1:8000/api/auth/';
  }

  static String get socketUrl {
    if (kIsWeb) return "ws://127.0.0.1:8000/ws/call/";
    if (defaultTargetPlatform == TargetPlatform.android) return "wss://nonordered-nonfreezable-lionel.ngrok-free.dev/ws/call/";
    return "ws://127.0.0.1:8000/ws/call/";
  }
}
