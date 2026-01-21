import 'package:flutter/foundation.dart';

class AppConfig {
  // Update this with your Railway WebSocket backend URL
  // Use 10.0.2.2 for Android Emulator, or your local machine IP for physical devices
  static const String _localDevHost = '10.0.2.2:8000'; 
  
  // For development, you can override with environment variable
  static String get _host {
    const String envHost = String.fromEnvironment('WEBSOCKET_HOST', defaultValue: '');
    return envHost.isNotEmpty ? envHost : _localDevHost;
  }

  static String get baseUrl {
    if (kIsWeb) return 'http://localhost:8000/api/auth/';
    // Point to local server for Emulator
    return 'http://$_host/api/auth/';
  }

  static String get socketUrl {
    if (kIsWeb) return "wss://$_host/ws/call/";
    // Production Railway URL
    return "wss://$_host/ws/call/";
  }
}
