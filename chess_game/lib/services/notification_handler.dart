import 'dart:ui';
import 'dart:convert';
import 'dart:isolate';

// @pragma('vm:entry-point') must be on top-level function
@pragma('vm:entry-point')
void notificationTapBackground(dynamic response) async {
  // Use dynamic to be safe with different version signatures
  print('🔔🔔🔔 [BG-FATAL] NOTIFICATION HANDLER WOKE UP!');
  
  try {
    // Extract data manually if it's a known object or Map
    String? actionId;
    String? rawPayload;
    int? notificationId;

    if (response is Map) {
      actionId = response['actionId'];
      rawPayload = response['payload'];
      notificationId = response['id'];
    } else {
      // It's likely a NotificationResponse object
      try {
        actionId = response.actionId;
        rawPayload = response.payload;
        notificationId = response.id;
      } catch (e) {
        print('❌ [BG-FATAL] Object extraction failed: $e');
      }
    }

    print('🔔 [BG-FATAL] Action: "$actionId", ID: $notificationId');
    print('🔔 [BG-FATAL] Raw Payload: $rawPayload');

    if (rawPayload == null) return;
    final Map<String, dynamic> rawData = json.decode(rawPayload);
    final type = rawData['type'];
    final payload = rawData['data'] ?? rawData['payload'];
    final String? roomId = (payload != null && payload['room_id'] != null) 
        ? payload['room_id'].toString() 
        : null;

    print('🔔 [BG-FATAL] Decoded: type=$type, roomId=$roomId');

    // 1. BROADCAST
    for (final portName in ['chess_game_main_port', 'chess_game_bg_port']) {
      final SendPort? sendPort = IsolateNameServer.lookupPortByName(portName);
      if (sendPort != null) {
        print('📡 [BG-FATAL] Signaling port: $portName');
        
        // Signal 1: Stop Audio
        sendPort.send({'action': 'stop_audio', 'roomId': roomId});
        sendPort.send({'action': 'dismiss_call'});

        // Signal 2: Handle Decline
        if (actionId == 'decline') {
          if ((type == 'call_invitation' || type == 'incoming_call') && payload != null) {
            final caller = payload['caller'] ?? payload['sender'];
            print('❌ [BG-FATAL] Dispatching Decline for Call: $caller');
            sendPort.send({
              'action': 'decline_call',
              'caller': caller,
              'roomId': roomId,
            });
          } else if ((type == 'game_invitation' || type == 'game_challenge') && payload != null) {
             final invitationId = int.tryParse(payload['id'].toString());
             print('❌ [BG-FATAL] Dispatching Decline for Game: $invitationId');
             if (invitationId != null) {
               sendPort.send({
                 'action': 'respond_invitation',
                 'invitationId': invitationId,
                 'action_type': 'decline',
               });
             }
          }
        }
        
        // Signal 3: Cancel Notification (Main Isolate can do this safely)
        if (notificationId != null) {
           sendPort.send({'action': 'cancel_notification', 'id': notificationId});
        }
        sendPort.send({'action': 'cancel_notification', 'id': 999});
        sendPort.send({'action': 'cancel_notification', 'id': 888});
      } else {
        print('⚠️ [BG-FATAL] Port NOT FOUND: $portName');
      }
    }

  } catch (e, stack) {
    print('❌ [BG-FATAL] ERROR: $e');
    print('❌ [BG-FATAL] STACK: $stack');
  }
}
