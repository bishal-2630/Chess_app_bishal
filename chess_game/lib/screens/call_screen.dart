import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';
import '../services/config.dart';
import '../services/django_auth_service.dart';
import '../services/game_service.dart';

class CallScreen extends StatefulWidget {
  final String roomId;
  final String otherUserName;
  final bool isCaller;

  const CallScreen({
    Key? key,
    required this.roomId,
    required this.otherUserName,
    this.isCaller = false,
  }) : super(key: key);

  @override
  _CallScreenState createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final DjangoAuthService _authService = DjangoAuthService();
  SignalingService _signalingService = SignalingService();
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _inCall = false;
  String _status = "Connecting...";

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _connect();
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
    String fullUrl = baseUrl + widget.roomId + "/";
    
    print("📞 Connecting to call room: $fullUrl");
    final token = await _authService.accessToken;
    _signalingService.connect(fullUrl, token: token);
    
    // 2. If Caller, send notification to invitee
    if (widget.isCaller) {
      setState(() => _status = "Calling ${widget.otherUserName}...");
      
      // Delay slightly to ensure WS is connecting? sending via HTTP is independent.
      final result = await GameService.sendCallSignal(
        receiverUsername: widget.otherUserName,
        roomId: widget.roomId,
      );
      
      if (!result['success']) {
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
                      widget.otherUserName.isNotEmpty ? widget.otherUserName[0].toUpperCase() : '?',
                      style: TextStyle(fontSize: 40),
                    ),
                  ),
                  SizedBox(height: 20),
                  Text(
                     _status,
                     style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                     textAlign: TextAlign.center,
                  ),
                  if (_inCall) ...[
                    SizedBox(height: 20),
                    Icon(Icons.mic, size: 30, color: Colors.green),
                    Text("Audio Connected"),
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
                  backgroundColor: Colors.red,
                  onPressed: () {
                     _signalingService.sendEndCall();
                     _signalingService.hangUp();
                     Navigator.pop(context);
                  },
                  child: Icon(Icons.call_end),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
