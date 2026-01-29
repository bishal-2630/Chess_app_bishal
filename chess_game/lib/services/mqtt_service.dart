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

  Future<void> connect(String username) async {
    if (isConnected) return;

    final clientIdentifier = 'flutter_client_${username}_${DateTime.now().millisecondsSinceEpoch}';
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
      print('MQTT: Connecting...');
      await client!.connect();
    } on Exception catch (e) {
      print('MQTT: Connection failed - $e');
      disconnect();
      return;
    }

    if (client!.connectionStatus!.state == MqttConnectionState.connected) {
      isConnected = true;
      print('MQTT: Connected');
      _subscribeToNotifications(username);
      _listen();
    } else {
      print('MQTT: Connection failed - state is ${client!.connectionStatus!.state}');
      disconnect();
    }
  }

  void _subscribeToNotifications(String username) {
    final topic = 'chess/user/$username/notifications';
    print('MQTT: Subscribing to $topic');
    client!.subscribe(topic, MqttQos.atLeastOnce);
  }

  void _listen() {
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
    final type = data['type'];
    final payload = data['payload'];

    if (type == 'game_invitation') {
      _showLocalNotification(
        'New Challenge!',
        '${payload['sender']['username']} has challenged you to a game.',
        json.encode(data),
      );
    } else if (type == 'call_invitation') {
      playSound('sounds/ringtone.mp3');
      _showLocalNotification(
        'Incoming Call',
        '${payload['caller']} is calling you...',
        json.encode(data),
      );
    }
    
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
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    await flutterLocalNotificationsPlugin.show(
      0,
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );
  }

  void onConnected() {
    print('MQTT: OnConnected');
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
    stopAudio();
  }
}
