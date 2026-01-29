import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';

class MqttService {
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

  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
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
    print('MQTT: Subscribing to $topic');
    client!.subscribe(topic, MqttQos.atLeastOnce);
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
      final String pt =
          MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

      print('MQTT: Notification received: $pt');
      try {
        final data = json.decode(pt);
        _handleNotification(data);
      } catch (e) {
        print('MQTT: Error parsing message: $e');
      }
    });
  }

  void _handleNotification(Map<String, dynamic> data) {
    print('🔔 MQTT: _handleNotification called with data: $data');
    final type = data['type'];
    final payload = data['payload'];

    print('🔔 MQTT: Notification type: $type');

    if (type == 'game_invitation') {
      print('🔔 MQTT: Showing game invitation notification');
      _showLocalNotification(
        'New Challenge!',
        '${payload['sender']['username']} has challenged you to a game.',
        json.encode(data),
      );
    } else if (type == 'call_invitation') {
      print('🔔 MQTT: Showing call invitation notification');
      playSound('sounds/ringtone.mp3');
      _showLocalNotification(
        'Incoming Call',
        '${payload['caller']} is calling you...',
        json.encode(data),
      );
    }
    
    print('🔔 MQTT: Broadcasting to stream listeners');
    // Broadcast to internal listeners
    _notificationController.add(data);
  }

  Future<void> _showLocalNotification(String title, String body, String payload) async {
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
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    // Use a unique ID based on timestamp to avoid overwriting previous notifications
    final int notificationId = DateTime.now().millisecondsSinceEpoch.remainder(100000);

    await flutterLocalNotificationsPlugin.show(
      notificationId,
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );
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
    print('MQTT: OnSubscribed to topic $topic');
  }

  Future<void> playSound(String fileName) async {
    if (_isPlaying) await stopAudio();
    try {
      _isPlaying = true;
      print('MQTT: Playing sound $fileName');
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
      await _audioPlayer.stop();
      _isPlaying = false;
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
