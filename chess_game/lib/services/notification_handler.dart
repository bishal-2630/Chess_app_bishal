import 'dart:ui';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// IMPORTANT: Do NOT import MqttService, DjangoAuthService, or GameService here.
// Loading those classes triggers plugin registration that crashes background isolates.

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  // We use a local instance of the plugin for cancellation only
  final fln = FlutterLocalNotificationsPlugin();
  await fln.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ));

  print('🔔 [BG-SIGNAL] --- NOTIFICATION ACTION TRIGGERED ---');
  print('🔔 [BG-SIGNAL] Action ID: "${response.actionId}"');

  try {
    final rawPayload = response.payload;
    final rawData = rawPayload != null ? json.decode(rawPayload) : null;
    if (rawData == null) return;

    final type = rawData['type'];
    final payload = rawData['data'] ?? rawData['payload'];
    final String? roomId = (payload != null && payload['room_id'] != null) 
        ? payload['room_id'].toString() 
        : null;

    // 1. BROADCAST TO ALL PORTS
    // The Main Isolate or the Background Service Isolate will catch these and do the actual work.
    for (final portName in ['chess_game_main_port', 'chess_game_bg_port']) {
      final sendPort = IsolateNameServer.lookupPortByName(portName);
      if (sendPort != null) {
        // Stop Audio
        sendPort.send({'action': 'stop_audio', 'roomId': roomId});
        sendPort.send({'action': 'dismiss_call'});

        // If Decline, tell the port to send the signal
        if (response.actionId == 'decline') {
          if ((type == 'call_invitation' || type == 'incoming_call') && payload != null) {
            final caller = payload['caller'] ?? payload['sender'];
            sendPort.send({
              'action': 'decline_call',
              'caller': caller,
              'roomId': roomId,
            });
          } else if ((type == 'game_invitation' || type == 'game_challenge') && payload != null) {
             final invitationId = int.tryParse(payload['id'].toString());
             if (invitationId != null) {
               sendPort.send({
                 'action': 'respond_invitation',
                 'invitationId': invitationId,
                 'action_type': 'decline',
               });
             }
          }
        }
        print('✅ [BG-SIGNAL] Dispatched to $portName');
      }
    }

    // 2. CLEANUP NOTIFICATION
    if (response.id != null) {
      await fln.cancel(response.id!);
    }
    // Nuclear clear
    await fln.cancel(999);
    await fln.cancel(888);

  } catch (e) {
    print('❌ [BG-SIGNAL] Error: $e');
  }
}
