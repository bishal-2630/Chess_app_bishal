import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';
import '../services/config.dart';
import '../services/django_auth_service.dart';
import '../services/game_service.dart';
import '../services/mqtt_service.dart';
import 'package:audioplayers/audioplayers.dart';

class CallScreen extends StatefulWidget {
  final String roomId;
  final String otherUserName;
  final bool isCaller;

  const CallScreen({
    super.key,
    required this.roomId,
    required this.otherUserName,
    this.isCaller = false,
  });

  @override
  _CallScreenState createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final DjangoAuthService _authService = DjangoAuthService();
  final SignalingService _signalingService = SignalingService();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _inCall = false;
  String _status = "Connecting...";
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    // Stop any incoming ringtone from MqttService and cancel notification
    MqttService().cancelCallNotification();
    _initRenderers();
    _connect();
    _listenForDecline();
  }

  void _listenForDecline() {
    MqttService().notifications.listen((data) {
      if (!mounted) return;
      
      final type = data['type'];
      if (type == 'call_declined') {
        final decliner = data['data'] != null ? data['data']['decliner'] : data['payload']['decliner'];
        print("❌ Call declined by $decliner");
        
        // Stop audio immediately
        MqttService().stopAudio();
        
        // Show a dialog instead of just a snackbar for better visibility
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            // Auto-close dialog after 2 seconds
            Future.delayed(const Duration(seconds: 2), () {
              // Use 'context' (CallScreen context) which is stable if mounted.
              // If dialog is closed, mounted is false (because we popped screen in .then).
              // If dialog is open, mounted is true, and pop() closes the dialog.
              if (mounted) {
                 Navigator.of(context).pop(); 
              }
            });
            
            return AlertDialog(
              title: const Text('Call Declined'),
              content: Text('$decliner declined the call.'),
              actions: [
                TextButton(
                  onPressed: () {
                    // Close dialog immediately
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('OK'),
                ),
              ],
            );
          },
        ).then((_) {
          // Once dialog is closed (by user or timer), close the screen
          if (mounted) {
             Navigator.of(context).pop();
          }
        });
      }
    });
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _signalingService.onLocalStream = ((stream) {
      _localRenderer.srcObject = stream;
      setState(() {});
    });

    _signalingService.onAddRemoteStream = ((stream) {
      _remoteRenderer.srcObject = stream;
      setState(() {});
    });

    _signalingService.onPlayerJoined = () {
      print("👋 Peer joined the room");
      if (widget.isCaller) {
        setState(() => _status = "Peer joined. Calling...");
        _startCall(); // Auto-start call when peer joins
      }
    };

    _signalingService.onIncomingCall = () async {
      print("📞 Incoming call offer received");
      if (!widget.isCaller) {
        setState(() => _status = "Accepting call...");
        await _signalingService.acceptCall(_localRenderer, _remoteRenderer);
        setState(() {
          _inCall = true;
          _status = "Connected";
        });
      }
    };

    _signalingService.onCallAccepted = () {
      print("✅ Call accepted by peer");
      MqttService().stopAudio();
      setState(() {
        _inCall = true;
        _status = "Connected";
      });
    };

    _signalingService.onEndCall = () {
      print("❌ Call ended by peer");
      if (mounted) {
        Navigator.pop(context);
      }
    };
  }

  void _connect() async {
    // 1. Connect to WebSocket Room
    String baseUrl = AppConfig.socketUrl;
    if (!baseUrl.endsWith("/")) baseUrl += "/";
    String fullUrl = "$baseUrl${widget.roomId}/";

    print("📞 Connecting to call room: $fullUrl");
    final token = _authService.accessToken;
    _signalingService.connect(fullUrl, token: token);

    // 2. If Caller, send notification to invitee and play calling tone
    if (widget.isCaller) {
      setState(() => _status = "Calling ${widget.otherUserName}...");
      // Sound already started in UserListScreen

      // Delay slightly to ensure WS is connecting? sending via HTTP is independent.
      final result = await GameService.sendCallSignal(
        receiverUsername: widget.otherUserName,
        roomId: widget.roomId,
      );

      if (!result['success']) {
        MqttService().stopAudio();
        setState(() => _status = "Failed to call: ${result['error']}");
      }
    } else {
      setState(() => _status = "Joining call with ${widget.otherUserName}...");
    }
  }

  Future<void> _startCall() async {
    try {
      await _signalingService.startCall(_localRenderer, _remoteRenderer);
    } catch (e) {
      print("Start call failed: $e");
    }
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _signalingService.hangUp();
    MqttService().stopAudio();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Call with ${widget.otherUserName}'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 50,
                    child: Text(
                      widget.otherUserName.isNotEmpty
                          ? widget.otherUserName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(fontSize: 40),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _status,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  if (_inCall) ...[
                    const SizedBox(height: 20),
                    const Icon(Icons.mic, size: 30, color: Colors.green),
                    const Text("Audio Connected"),
                  ]
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 50.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FloatingActionButton(
                  backgroundColor: _isMuted ? Colors.blueGrey : Colors.blue,
                  onPressed: () {
                    setState(() {
                      _isMuted = !_isMuted;
                      _signalingService.muteAudio(_isMuted);
                    });
                  },
                  heroTag: 'mute_btn',
                  child: Icon(_isMuted ? Icons.mic_off : Icons.mic),
                ),
                const SizedBox(width: 32),
                FloatingActionButton(
                  backgroundColor: Colors.red,
                  onPressed: () {
                    _signalingService.sendEndCall();
                    _signalingService.hangUp();
                    Navigator.pop(context);
                  },
                  heroTag: 'hangup_btn',
                  child: const Icon(Icons.call_end),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
