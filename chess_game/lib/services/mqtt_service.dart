import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:ui';
import 'dart:isolate';
import 'game_service.dart';
import 'django_auth_service.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  print('🔔 BACKGROUND: Notification tapped. Action: ${response.actionId}');
  
  try {
    // 1. STOP AUDIO IMMEDIATELY (Prioritize UX)
    for (final portName in ['chess_game_main_port', 'chess_game_bg_port']) {
      final SendPort? sendPort = IsolateNameServer.lookupPortByName(portName);
      if (sendPort != null) {
        print('🔔 BACKGROUND: Sending stop_audio to $portName');
        sendPort.send('stop_audio');
      }
    }

    // 2. Initialize services
    print('🔔 BACKGROUND: Initializing DjangoAuthService...');
    await DjangoAuthService().initialize(autoConnectMqtt: false);
    
    if (response.payload != null) {
      final data = json.decode(response.payload!);
      final type = data['type'];
      print('🔔 BACKGROUND: Type: $type, Action: ${response.actionId}');

      if (response.actionId == 'accept') {
        print('🔔 BACKGROUND: Accept tapped. App should be launching...');
        // The OS handles launching the app because showsUserInterface is true.
        // We just return here to avoid race conditions.
        return;
      }

      if (response.actionId == 'decline') {
        if (type == 'call_invitation') {
          final payload = data['payload'];
          final caller = payload['caller'];
          final roomId = payload['room_id'];
          if (caller != null && roomId != null) {
            print('🔔 BACKGROUND: Declining call from $caller');
            await GameService.declineCall(callerUsername: caller, roomId: roomId);
            print('🔔 BACKGROUND: Call decline signal sent');
          }
        } else if (type == 'game_invitation') {
          final payload = data['payload'];
          final invitationId = payload['id'];
          if (invitationId != null) {
            print('🔔 BACKGROUND: Declining game invite $invitationId');
            await GameService.respondToInvitation(invitationId: invitationId, action: 'decline');
            print('🔔 BACKGROUND: Game invite decline sent');
          }
        }
      }
    }
    
    // 3. Manual cancel since we removed cancelNotification: true
    if (response.notificationId != null) {
      print('🔔 BACKGROUND: Manually canceling notification ${response.notificationId}');
      final fln = FlutterLocalNotificationsPlugin();
      await fln.cancel(response.notificationId!);
    }

  } catch (e, stack) {
    print('❌ BACKGROUND ERROR: $e');
    print('❌ BACKGROUND STACK: $stack');
  }
}

class MqttService {
  // Static port to prevent GC
  static final ReceivePort _listenerPort = ReceivePort();

  static final MqttService _instance = MqttService._internal();
  factory MqttService() => _instance;
  MqttService._internal();

  MqttServerClient? client;
  final String broker = 'broker.emqx.io';
  final int port = 1883;
  bool isConnected = false;
  bool _isListening = false;

  final StreamController<Map<String, dynamic>> _notificationController = 
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get notifications => _notificationController.stream;

  // Buffer for the last notification event to solve race conditions on startup
  Map<String, dynamic>? _lastNotificationEvent;
  Map<String, dynamic>? get lastNotificationEvent => _lastNotificationEvent;

  void clearLastNotification() => _lastNotificationEvent = null;

  void _emitNotification(Map<String, dynamic> data) {
    _lastNotificationEvent = data;
    _notificationController.add(data);
  }

  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  bool _isInCall = false; // Prevents ringing if we are already in a call
  String? _currentCallRoomId;
  final Set<String> _declinedRoomIds = {};

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: onNotificationTapped,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    
    // Setup Isolate communication
    // Note: main.dart calls this once. Background service calls this as well.
    // We check if we are in background service to register a second port.
  }
  
  void initializeIsolateListener({bool isBackground = false}) {
    final portName = isBackground ? 'chess_game_bg_port' : 'chess_game_main_port';
    print("🔔 Initializing Isolate Listener: $portName");
    IsolateNameServer.removePortNameMapping(portName);
    IsolateNameServer.registerPortWithName(_listenerPort.sendPort, portName);
    
    _listenerPort.listen((message) async {
      print("🔔 $portName received: $message");
      if (message == 'stop_audio') {
        print("🔔 STOPPING AUDIO in isolate via $portName");
        await stopAudio();
      }
    });
  }

  void onNotificationTapped(NotificationResponse response) async {
    print('🔔 Notification tapped: ${response.actionId}');
    print('🔔 Payload: ${response.payload}');
    
    if (response.payload != null) {
      try {
        final data = json.decode(response.payload!);
        final payloadType = data['type'];

        // Handle Game Invitation Actions
        if (payloadType == 'game_invitation') {
          if (response.actionId == 'decline') {
            print('❌ User declined game from notification');
            final invitationId = data['payload']['id'];
            if (invitationId != null) {
              await GameService.respondToInvitation(
                invitationId: invitationId,
                action: 'decline',
              );
              print('✅ Decline signal sent for game invite');
            }
            return;
          } else if (response.actionId == 'accept') {
            print('✅ User accepted game from notification');
            _emitNotification({
              ...data,
              'action': 'accept',
            });
            return;
          }
        }
        
        // Handle Call Invitation Actions
        if (response.actionId == 'decline') {
          print('❌ User declined call from notification');
          
          try {
            final payloadMap = data['payload'] as Map<String, dynamic>;
            final caller = payloadMap['caller'];
            final roomId = payloadMap['room_id'];
            
            if (caller != null && roomId != null) {
               await GameService.declineCall(
                  callerUsername: caller,
                  roomId: roomId,
                );
                print('✅ Decline signal sent from notification');
            }
          } catch (e) {
            print('⚠️ Error parsing payload for decline: $e');
          }
          
          await cancelCallNotification();
          return;
        } else if (response.actionId == 'accept') {
          print('✅ User accepted call from notification');
          
          
          _isInCall = true; // Mark as in-call to prevent further ringing
          
          // Force stop audio before canceling notification (redundant but safe)
          await stopAudio();
          await cancelCallNotification();
          
          // Broadcast to open call screen
          _emitNotification({
            ...data,
            'action': 'accept',
          });
          return;
        }
        
        // Handle regular notification tap (no action body)
        print('👆 User tapped notification body');
        _emitNotification(data);
      } catch (e) {
        print('Error parsing notification payload: $e');
      }
    }
  }

  String? _currentUsername;

  Future<void> connect(String username) async {
    print('🔌 MQTT: connect() called for username: $username');
    if (isConnected) {
      print('⚠️ MQTT: Already connected, skipping');
      return;
    }

    _currentUsername = username;
    final clientIdentifier = 'flutter_client_${username}_${DateTime.now().millisecondsSinceEpoch}';
    print('🔌 MQTT: Creating client with ID: $clientIdentifier');
    client = MqttServerClient(broker, clientIdentifier);
    client!.port = port;
    client!.keepAlivePeriod = 20;
    client!.onDisconnected = onDisconnected;
    client!.onConnected = onConnected;
    client!.onSubscribed = onSubscribed;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientIdentifier)
        .withWillTopic('willtopic')
        .withWillMessage('My Will message')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    client!.connectionMessage = connMess;

    try {
      print('🔌 MQTT: Attempting connection to $broker:$port...');
      await client!.connect();
      print('🔌 MQTT: Connection attempt completed');
    } on Exception catch (e) {
      print('❌ MQTT: Connection failed - $e');
      disconnect();
      return;
    }

    // Wait a bit for the connection to stabilize
    await Future.delayed(Duration(milliseconds: 500));

    if (client!.connectionStatus!.state == MqttConnectionState.connected) {
      isConnected = true;
      print('✅ MQTT: Connected successfully');
      _subscribeToNotifications(username);
      _listen();
    } else {
      print('❌ MQTT: Connection failed - state is ${client!.connectionStatus!.state}');
      disconnect();
    }
    
    print('🔌 MQTT connect call completed');
  }

  void _subscribeToNotifications(String username) {
    final topic = 'chess/user/$username/notifications';
    print('📬 MQTT: Subscribing to topic: $topic');
    print('📬 MQTT: Username for subscription: $username');
    client!.subscribe(topic, MqttQos.atLeastOnce);
    print('📬 MQTT: Subscribe request sent for $topic');
  }

  void _listen() {
    if (_isListening) {
      print('⚠️ MQTT: Already listening, skipping');
      return;
    }
    
    _isListening = true;
    print('👂 MQTT: Setting up message listener');
    client!.updates!.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
      final MqttPublishMessage recMess = c![0].payload as MqttPublishMessage;
      final String topic = c[0].topic;
      final String pt =
          MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

      print('📨 MQTT: Message received on topic: $topic');
      print('📨 MQTT: Raw message payload: $pt');
      try {
        final data = json.decode(pt);
        print('📨 MQTT: Parsed message type: ${data['type']}');
        _handleNotification(data);
      } catch (e) {
        print('❌ MQTT: Error parsing message: $e');
        print('❌ MQTT: Failed payload was: $pt');
      }
    });
  }

  Future<void> _handleNotification(Map<String, dynamic> data) async {
    print('🔔 MQTT: _handleNotification called with data: $data');
    final type = data['type'];
    final payload = data['payload'];

    print('🔔 MQTT: Notification type: $type');

    if (type == 'game_invitation') {
      print('🔔 MQTT: Showing game invitation notification');
      _showGameNotification(
        'New Challenge!',
        '${payload['sender']['username']} has challenged you to a game.',
        json.encode(data),
      );
    } else if (type == 'call_invitation') {
      final roomId = payload['room_id'];
      
      // Check if we already suspended/declined this call
      if (_declinedRoomIds.contains(roomId)) {
        print('🚫 MQTT: Ignoring call invitation for declined room: $roomId');
        return;
      }
      
      // Check if we are already in a call
      if (_isInCall) {
        print('🚫 MQTT: Ignoring call invitation - already in a call');
        return;
      }
      
      // Check if we are already ringing for this exact room
      if (_isPlaying && _currentCallRoomId == roomId) {
        print('⚠️ MQTT: Already ringing for room $roomId, skipping duplicate notification');
        return;
      }

      print('🔔 MQTT: Showing call invitation notification');
      _currentCallRoomId = roomId;
      playSound('sounds/ringtone.mp3');
      _showCallNotification(
        '${payload['caller']}',
        roomId,
        json.encode(data),
      );
      print('✅ MQTT: Call notification sent to system');
    } else if (type == 'call_declined') {
      print('🔔 MQTT: Call declined by user via signaling');
      await cancelCallNotification(); // Stop ringtone if we were ringing
      // Broadcast to listeners (CallScreen will pick this up)
      _notificationController.add(data);
    }
    
    print('🔔 MQTT: Broadcasting to stream listeners');
    // Broadcast to internal listeners
    _notificationController.add(data);
  }

  Future<void> _showGameNotification(String title, String body, String payload) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'chess_notifications_high',
      'Chess High Priority',
      channelDescription: 'Notifications for chess challenges and calls',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      visibility: NotificationVisibility.public,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'decline',
          'Decline',
          showsUserInterface: false,
          cancelNotification: false, // Manual cancel
        ),
        AndroidNotificationAction(
          'accept',
          'Accept',
          showsUserInterface: true,
          cancelNotification: false, // Manual cancel
        ),
      ],
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    // Use a fixed ID for game notifications so they are manageable
    const int gameNotificationId = 888;

    await flutterLocalNotificationsPlugin.show(
      gameNotificationId,
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );
  }

  Future<void> _showCallNotification(String caller, String roomId, String payload) async {
    print('📱 Creating call notification for $caller');
    
    // Create notification channel for calls if it doesn't exist
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'chess_incoming_calls_v2', // Changed ID to ensure update
      'Incoming Calls',
      description: 'Notifications for incoming calls',
      importance: Importance.max,
      playSound: false, // We're playing our own ringtone
      enableVibration: true,
      showBadge: true,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Create notification with action buttons
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: Importance.max,
      priority: Priority.max, // Increased to max
      showWhen: true,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      visibility: NotificationVisibility.public,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: true,
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
          'decline',
          'Decline',
          showsUserInterface: false,
          cancelNotification: false,
        ),
        const AndroidNotificationAction(
          'accept',
          'Accept',
          showsUserInterface: true,
          cancelNotification: false,
        ),
      ],
    );

    final NotificationDetails notificationDetails =
        NotificationDetails(android: androidDetails);

    // Use a fixed ID for call notifications so we can cancel it later
    const int callNotificationId = 999;

    await flutterLocalNotificationsPlugin.show(
      callNotificationId,
      'Incoming Call',
      '$caller is calling you...',
      notificationDetails,
      payload: payload,
    );
    
    print('✅ Call notification shown for $caller');
  }

  Future<void> cancelCallNotification() async {
    const int callNotificationId = 999;
    await flutterLocalNotificationsPlugin.cancel(callNotificationId);
    
    // Add current room to declined set so we don't ring again for it
    if (_currentCallRoomId != null) {
      final roomId = _currentCallRoomId!;
      _declinedRoomIds.add(roomId);
      print('🚫 MQTT: Added $roomId to declined list');
      
      // Auto-clear after 1 minute to keep set size small
      // We use the captured 'roomId' variable, not the field which becomes null
      Future.delayed(const Duration(minutes: 1), () {
        _declinedRoomIds.remove(roomId);
        print('🚫 MQTT: Removed $roomId from declined list (expired)');
      });
      
      _currentCallRoomId = null;
    }
    
    await stopAudio();
    
    // Broadcast clean up event to close any open dialogs
    _notificationController.add({
      'type': 'call_ended',
    });
  }
  
  void setInCall(bool inCall) {
    _isInCall = inCall;
  }

  void onConnected() {
    print('✅ MQTT: OnConnected callback triggered');
    isConnected = true;
    if (_currentUsername != null) {
      _subscribeToNotifications(_currentUsername!);
      _listen();
    }
  }

  void onDisconnected() {
    print('MQTT: OnDisconnected');
    isConnected = false;
  }

  void onSubscribed(String topic) {
    print('✅ MQTT: Successfully subscribed to topic: $topic');
    print('✅ MQTT: Now listening for messages on: $topic');
  }

  Future<void> playSound(String fileName) async {
    // Ensure any previous audio is completely stopped
    await stopAudio();
    
    try {
      _isPlaying = true;
      print('MQTT: Playing sound $fileName');
      
      // Reset player mode just in case
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      // The path should be relative to the assets folder, e.g., 'sounds/ringtone.mp3'
      await _audioPlayer.play(AssetSource(fileName));
    } catch (e) {
      print('MQTT: Error playing sound $fileName: $e');
      _isPlaying = false;
    }
  }

  Future<void> stopAudio() async {
    try {
      print('MQTT: Stopping audio aggressively...');
      await _audioPlayer.stop();
      await _audioPlayer.release(); // Force release resources and silence
      _isPlaying = false;
      print('MQTT: Audio stopped and released.');
    } catch (e) {
      print('MQTT: Error stopping audio: $e');
    }
  }

  void disconnect() {
    client?.disconnect();
    isConnected = false;
    _isListening = false;
    stopAudio();
  }
}
