import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/foundation.dart';
import '../../services/config.dart';

import '../../services/django_auth_service.dart';
import './websocket_helper.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _notificationController = 
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get notifications => _notificationController.stream;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    if (_channel != null) {
      print('🔔 Notification service already connected');
      return;
    }

    try {
      final notificationUrl = '${AppConfig.socketUrl.replaceAll('/ws/call/', '/ws/notifications/')}';
      print('🔔 Connecting to notification service: $notificationUrl');

      // Get Authentication Token
      final token = await DjangoAuthService().accessToken;
      String urlWithToken = notificationUrl;
      final Map<String, String> headers = {};
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
        // Also add as query param for robustness (some proxies strip headers)
        urlWithToken += '?token=$token';
      }

      _channel = connectWithHeaders(urlWithToken, headers);

      _channel!.stream.listen(
        (message) {
          try {
            final data = json.decode(message) as Map<String, dynamic>;
            print('🔔 Received notification: ${data['type']}');
            _notificationController.add(data);
          } catch (e) {
            print('🔔 Error parsing notification: $e');
          }
        },
        onError: (error) {
          print('🔔 Notification service error: $error');
          _notificationController.addError(error);
        },
        onDone: () {
          print('🔔 Notification service disconnected');
          _channel = null;
        },
      );

      print('🔔 Notification service connected');
    } catch (e) {
      print('🔔 Failed to connect to notification service: $e');
      _notificationController.addError(e);
    }
  }

  void disconnect() {
    if (_channel != null) {
      _channel!.sink.close();
      _channel = null;
      print('🔔 Notification service disconnected');
    }
  }

  void clearNotifications() {
    // Clear any pending notifications
    _notificationController.add({'type': 'clear'});
  }
}
