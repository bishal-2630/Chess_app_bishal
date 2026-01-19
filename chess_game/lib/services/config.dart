import 'package:flutter/foundation.dart';

class AppConfig {
  // Update this with your Railway WebSocket backend URL
  static const String _railwayHost = 'chess-game-app-production.up.railway.app';
  
  // For development, you can override with environment variable
  static String get _host {
    const String envHost = String.fromEnvironment('WEBSOCKET_HOST', defaultValue: '');
    return envHost.isNotEmpty ? envHost : _railwayHost;
  }

  static String get baseUrl {
    if (kIsWeb) return 'https://$_host/api/auth/';
    // Production Railway URL
    return 'https://$_host/api/auth/';
  }

  static String get socketUrl {
    if (kIsWeb) return "wss://$_host/ws/call/";
    // Production Railway URL
    return "wss://$_host/ws/call/";
  }
}
