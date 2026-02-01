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
import 'package:flutter_background_service/flutter_background_service.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  print('🔔 Notification Action: ${response.actionId}');
  
  // Initialize local plugin for this temporary isolate
  final fln = FlutterLocalNotificationsPlugin();
  await fln.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ));

  try {
      final rawPayload = response.payload;
      final rawData = rawPayload != null ? json.decode(rawPayload) : null;
      final type = rawData != null ? rawData['type'] : null;
      final payload = rawData != null ? rawData['payload'] : null;
      
      // Robust String extraction
      final String? roomId = (payload != null && payload['room_id'] != null) 
          ? payload['room_id'].toString() 
          : MqttService._currentCallRoomId;
      
      print('🔔 Background Task Action: ${response.actionId}, Room: $roomId');
      
      // 1. STOP AUDIO & CANCEL NOTIFICATION
      final mqtt = MqttService();
      await mqtt.cancelCallNotification(roomId: roomId);
      
      // 2. DISMISS DIALOGS (Main Isolate)
      FlutterBackgroundService().invoke('dismissCall');

      // 3. BROADCAST VIA PORTS (Fallback)
      for (final portName in ['chess_game_main_port', 'chess_game_bg_port']) {
        final sendPort = IsolateNameServer.lookupPortByName(portName);
        sendPort?.send({'action': 'stop_audio', 'roomId': roomId});
      }

      if (response.actionId == 'decline') {
        if (type == 'call_invitation' && payload != null) {
          final caller = payload['caller'];
          if (caller != null && roomId != null) {
            print('❌ Background Action: Declining call from $caller');
            await GameService.declineCall(callerUsername: caller, roomId: roomId);
          }
        } else if (type == 'game_invitation' && payload != null) {
          final invitationId = payload['id'];
          if (invitationId != null) {
            print('❌ Background Action: Declining game invite $invitationId');
            await GameService.respondToInvitation(invitationId: invitationId, action: 'decline');
          }
        }
      } else if (response.actionId == 'accept') {
        // For calls, we just stop audio and let the main app handle navigation.
        // For game invites, we also stop audio and let the main app handle navigation.
        print('🔔 Background Action: Accept tapped. Audio stopped, app will handle navigation.');
      }

      // 3. Manual cancel since we removed cancelNotification: true
      if (response.id != null) {
        final fln = FlutterLocalNotificationsPlugin();
        await fln.cancel(response.id!);
      }

    } catch (e) {
      print('❌ Background Action Error: $e');
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

  static final AudioPlayer _audioPlayer = AudioPlayer();
  static bool _isAudioLoading = false;
  static bool _isPlaying = false;
  static bool _isMutedWindow = false; // Prevents re-ring within a short window
  bool _isInCall = false; 
  static String? _currentCallRoomId;
  static final Set<String> _declinedRoomIds = {};

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

    // Create High Priority Channels
    const AndroidNotificationChannel challengeChannel = AndroidNotificationChannel(
      'chess_challenges_v2', // Updated ID
      'Chess Challenges',
      description: 'Notifications for chess game invitations',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
      showBadge: true,
    );

    const AndroidNotificationChannel callChannel = AndroidNotificationChannel(
      'chess_incoming_calls_v6', // Fresh v6
      'Incoming Calls',
      description: 'Notifications for incoming calls',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
      showBadge: true,
    );

    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
            
    // Set Audio Context for better control on physical devices
    try {
      // Simplified context for maximum compatibility
      const audioContext = AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
        ),
        android: AudioContextAndroid(
          usageType: AndroidUsageType.notificationRingtone,
          contentType: AndroidContentType.music,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      );
      AudioLogger.logLevel = AudioLogLevel.none;
      await AudioPlayer.global.setAudioContext(audioContext).catchError((_) {});
    } catch (e) {
      print('⚠️ MQTT: Global audio context error: $e');
    }

    await androidPlugin?.createNotificationChannel(challengeChannel);
    await androidPlugin?.createNotificationChannel(callChannel);
  }
  
  void initializeIsolateListener({bool isBackground = false}) {
    final portName = isBackground ? 'chess_game_bg_port' : 'chess_game_main_port';
    print("🔔 Initializing Isolate Listener: $portName");
    IsolateNameServer.removePortNameMapping(portName);
    IsolateNameServer.registerPortWithName(_listenerPort.sendPort, portName);
    
    _listenerPort.listen((message) async {
      print("🔔 [$portName] Isolate received: $message");
      if (message == 'stop_audio') {
        await stopAudio(broadcast: false);
      } else if (message is Map && message['action'] == 'stop_audio') {
        final roomId = message['roomId'];
        await stopAudio(broadcast: false, roomId: roomId);
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
          
          // Cleanup in background without awaiting
          stopAudio();
          cancelCallNotification();
          
          // Broadcast to open call screen immediately
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
      if (_declinedRoomIds.contains(roomId) || _isMutedWindow) {
        print('🚫 MQTT: Ignoring call invitation (declined or in mute window)');
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
      
      // RESTORED: Play sound immediately
      playSound('sounds/ringtone.mp3', roomId: roomId);

      _showCallNotification(
        '${payload['caller']}',
        roomId,
        json.encode(data),
      );
      print('✅ MQTT: Call notification sent to system');
    } else if (type == 'call_declined' || type == 'call_cancelled') {
      final String? roomId = payload != null ? payload['room_id']?.toString() : null;
      print('🔔 MQTT: Remote termination: $type for room: $roomId');
      
      if (roomId != null) {
        ignoreRoom(roomId);
        // FORCE stop audio for this room regardless of _currentCallRoomId
        stopAudio(broadcast: true, roomId: roomId);
        
        if (_currentCallRoomId == roomId) {
          cancelCallNotification(roomId: roomId);
        }
      } else {
        cancelCallNotification();
      }
    }
    
    print('🔔 MQTT: Broadcasting event type: $type');
    _notificationController.add(data);
  }

  Future<void> _showGameNotification(String title, String body, String payload) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'chess_challenges_v2', // Match channel creation ID
      'Chess Challenges',
      channelDescription: 'Notifications for chess game invitations',
      importance: Importance.max,
      priority: Priority.max,
      showWhen: true,
      fullScreenIntent: true, // Show on lock screen
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.public,
      ticker: title, // Ensures notification appears
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
      ),
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
          'decline',
          'Decline',
          showsUserInterface: false,
          cancelNotification: false, // Manual cancel
        ),
        const AndroidNotificationAction(
          'accept',
          'Accept',
          showsUserInterface: true,
          cancelNotification: false, // Manual cancel
        ),
      ],
    );
    final NotificationDetails platformChannelSpecifics =
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
    
    // Create notification with action buttons
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'chess_incoming_calls_v6', // v6
      'Incoming Calls',
      channelDescription: 'Notifications for incoming calls',
      importance: Importance.max,
      priority: Priority.max,
      showWhen: true,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      visibility: NotificationVisibility.public,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: true,
      ticker: 'Incoming call from $caller', // Ensures notification appears
      styleInformation: BigTextStyleInformation(
        '$caller is calling you...',
        contentTitle: 'Incoming Call',
      ),
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

  void ignoreRoom(String? roomId) {
    if (roomId != null) {
      _declinedRoomIds.add(roomId);
      print('🚫 MQTT: Added $roomId to ignored list (cross-isolate)');
      Future.delayed(const Duration(minutes: 1), () {
        _declinedRoomIds.remove(roomId);
        print('🚫 MQTT: Removed $roomId from ignored list (expired)');
      });
    }
  }

  Future<void> cancelCallNotification({String? roomId}) async {
    // Standardize IDs: game=888, call=999
    await flutterLocalNotificationsPlugin.cancel(888);
    await flutterLocalNotificationsPlugin.cancel(999);
    
    // Prioritize the passed roomId, then the current one
    final String? roomIdToStop = roomId ?? _currentCallRoomId;
    
    if (roomIdToStop != null) {
      _declinedRoomIds.add(roomIdToStop);
      print('🚫 MQTT: Added $roomIdToStop to declined list');
      
      // Auto-clear after 1 minute
      Future.delayed(const Duration(minutes: 1), () {
        _declinedRoomIds.remove(roomIdToStop);
        print('🚫 MQTT: Removed $roomIdToStop from declined list (expired)');
      });

      if (_currentCallRoomId == roomIdToStop) {
        _currentCallRoomId = null;
      }
    } else {
      _currentCallRoomId = null;
    }
    
    stopAudio(broadcast: true, roomId: roomIdToStop);
  }
  
  void setInCall(bool inCall) {
    _isInCall = inCall;
  }

  void onConnected() {
    print('✅ MQTT: OnConnected callback triggered');
    isConnected = true;
    if (_currentUsername != null && _isListening == false) {
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

  Future<void> playSound(String fileName, {String? roomId}) async {
    final isolateName = Isolate.current.debugName ?? 'unknown';
    
    // Safety check 0: Mute window active?
    if (_isMutedWindow) {
      print('MQTT [$isolateName]: Aborting playSound - Muted window');
      return;
    }

    // Safety check 1: already declined?
    if (roomId != null && _declinedRoomIds.contains(roomId)) {
      print('MQTT [$isolateName]: Blocking playSound - room $roomId already declined');
      return;
    }

    // Safety check 2: already in call?
    if (_isInCall) {
      print('MQTT [$isolateName]: Blocking playSound - user is in active call');
      return;
    }

    _isPlaying = true;
    _isAudioLoading = true;

    try {
      print('MQTT [$isolateName]: Playing $fileName');
      
      // Reset player mode
      await _audioPlayer.setReleaseMode(ReleaseMode.loop).catchError((_) {});
      await _audioPlayer.setVolume(1.0).catchError((_) {});

      if (!_isPlaying) return;

      // Play the asset
      await _audioPlayer.play(AssetSource(fileName)).catchError((e) {
        print('MQTT [$isolateName]: Play error: $e');
        _isPlaying = false;
      });
      
      _isAudioLoading = false;

      // Final Check in case stop was called while loading
      if (!_isPlaying) {
        await _audioPlayer.stop().catchError((_) {});
        await _audioPlayer.setVolume(0).catchError((_) {});
      }
    } catch (e) {
      print('MQTT [$isolateName]: Error in playSound: $e');
      _isPlaying = false;
      _isAudioLoading = false;
    }
  }

  Future<void> stopAudio({bool broadcast = false, String? roomId}) async {
    final isolateName = Isolate.current.debugName ?? 'unknown';
    
    print('🛑 MQTT [$isolateName]: ===== STOP AUDIO CALLED =====');
    print('🛑 MQTT [$isolateName]: Room: $roomId, Broadcast: $broadcast');
    print('🛑 MQTT [$isolateName]: Current _isPlaying: $_isPlaying');
    print('🛑 MQTT [$isolateName]: Current _isMutedWindow: $_isMutedWindow');
    
    _isPlaying = false; 
    _isMutedWindow = true; // Start mute window

    if (roomId != null) {
      _declinedRoomIds.add(roomId);
      print('🛑 MQTT [$isolateName]: Added $roomId to declined list');
    }
    _currentCallRoomId = null; 

    try {
      print('🛑 MQTT [$isolateName]: Executing pause...');
      await _audioPlayer.pause().catchError((e) {
        print('🛑 MQTT [$isolateName]: Pause error: $e');
      });
      
      print('🛑 MQTT [$isolateName]: Executing stop...');
      await _audioPlayer.stop().catchError((e) {
        print('🛑 MQTT [$isolateName]: Stop error: $e');
      });
      
      print('🛑 MQTT [$isolateName]: Setting volume to 0...');
      await _audioPlayer.setVolume(0).catchError((e) {
        print('🛑 MQTT [$isolateName]: Volume error: $e');
      });
      
      print('🛑 MQTT [$isolateName]: Executing release...');
      await _audioPlayer.release().catchError((e) {
        print('🛑 MQTT [$isolateName]: Release error: $e');
      });
      
      print('🛑 MQTT [$isolateName]: Audio hardware commands completed');
    } catch (e) {
      print('🛑 MQTT [$isolateName]: Stop error: $e');
    }
    
    // Clear mute window after 3 seconds to allow next call but block race conditions
    Future.delayed(const Duration(seconds: 3), () {
      _isMutedWindow = false;
      print('🛑 MQTT [$isolateName]: Mute window cleared');
    });

    if (broadcast) {
      print('MQTT [$isolateName]: Broadcasting stop_audio signal globally');
      
      // Signal all Isolates via Port Registry (Fastest)
      // This reaches the Main Isolate and the Background Isolate if they are listening
      for (final portName in ['chess_game_main_port', 'chess_game_bg_port']) {
        final sendPort = IsolateNameServer.lookupPortByName(portName);
        if (sendPort != null) {
          sendPort.send({'action': 'stop_audio', 'roomId': roomId});
        }
      }

      // Signal via Background Service (Alternative path)
      try {
        FlutterBackgroundService().invoke('stopAudio', {'roomId': roomId});
        FlutterBackgroundService().invoke('dismissCall');
      } catch (e) {
        // Service might not be running in this context
      }
    }
  }

  void disconnect() {
    if (client != null) {
      client!.disconnect();
    }
    isConnected = false;
    _isListening = false;
    stopAudio();
  }
}
