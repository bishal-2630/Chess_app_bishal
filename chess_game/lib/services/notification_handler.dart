import 'dart:ui';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'mqtt_service.dart';
import 'django_auth_service.dart';
import 'game_service.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  // NOTE: DartPluginRegistrant.ensureInitialized() is auto-called by Flutter 3.3+ for @pragma('vm:entry-point')
  
  final fln = FlutterLocalNotificationsPlugin();
  // Minimal initialization without callbacks for the background isolate
  await fln.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ));

  print('🔔 [BG] --- NOTIFICATION ACTION TRIGGERED ---');
  print('🔔 [BG] Action ID: "${response.actionId}"');
  print('🔔 [BG] Raw Payload: ${response.payload}');

  try {
    final rawPayload = response.payload;
    final rawData = rawPayload != null ? json.decode(rawPayload) : null;
    if (rawData == null) {
       print('⚠️ [BG] No payload data found');
       return;
    }

    final type = rawData['type'];
    final payload = rawData['data'] ?? rawData['payload'];
    final String? roomId = (payload != null && payload['room_id'] != null) 
        ? payload['room_id'].toString() 
        : null;

    // 1. BROADCAST STOP AUDIO IMMEDIATELY
    print('📡 [BG] Broadcasting dismissal signal...');
    for (final portName in ['chess_game_main_port', 'chess_game_bg_port']) {
      final sendPort = IsolateNameServer.lookupPortByName(portName);
      if (sendPort != null) {
        sendPort.send({'action': 'stop_audio', 'roomId': roomId});
        sendPort.send({'action': 'dismiss_call'});
        print('✅ [BG] Signal sent to $portName');
      }
    }

    // 2. HANDLE DECLINE
    if (response.actionId == 'decline') {
      print('❌ [BG] ACTION: DECLINE');
      
      // Initialize Auth manually for this isolate
      final authService = DjangoAuthService();
      await authService.initialize(autoConnectMqtt: false);
      print('🔐 [BG] Auth Initialized. LoggedIn: ${authService.isLoggedIn}');

      if ((type == 'call_invitation' || type == 'incoming_call') && payload != null) {
        final caller = payload['caller'] ?? payload['sender'];
        if (caller != null && roomId != null) {
          print('📡 [BG] Sending Decline Signal for Call to: $caller');
          await GameService.declineCall(callerUsername: caller, roomId: roomId);
          print('✅ [BG] Decline Signal SUCCESS');
        }
      } else if ((type == 'game_invitation' || type == 'game_challenge') && payload != null) {
        final rawId = payload['id'];
        final invitationId = int.tryParse(rawId.toString());
        if (invitationId != null) {
          print('📡 [BG] Sending Decline Signal for Game ID: $invitationId');
          await GameService.respondToInvitation(invitationId: invitationId, action: 'decline');
          print('✅ [BG] Decline Signal SUCCESS');
        }
      }
    }

    // 3. CLEANUP
    print('🧹 [BG] Cleaning up notifications...');
    if (response.id != null) {
      await fln.cancel(response.id!);
    }
    await fln.cancel(999);
    await fln.cancel(888);

  } catch (e) {
    print('❌ [BG] Error in handler: $e');
  }
}
