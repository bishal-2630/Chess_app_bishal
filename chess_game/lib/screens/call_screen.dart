import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';
import '../services/config.dart';
import '../services/django_auth_service.dart';

class CallScreen extends StatefulWidget {
  final String roomId;
  final String callerName; 

  const CallScreen({Key? key, required this.roomId, required this.callerName}) : super(key: key);

  @override
  _CallScreenState createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final DjangoAuthService _authService = DjangoAuthService(); // Add Auth Service
  SignalingService _signalingService = SignalingService();
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _inCall = false;

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
    
    _signalingService.onIncomingCall = () {
       // Auto-accept in this simple call screen example if needed,
       // or show a dialog. For now, let's just let the user press the button.
    };
  }

  void _connect() async {
    // ALWAYS use the global socket URL for the connection host
    String baseUrl = AppConfig.socketUrl;
    if (!baseUrl.endsWith("/")) baseUrl += "/";
    
    // Append the roomId to form the full call room URL
    String fullUrl = baseUrl + widget.roomId + "/";
    
    print("📞 Connecting to call room: $fullUrl");
    final token = await _authService.accessToken;
    _signalingService.connect(fullUrl, token: token);
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
        title: Text('Audio Call'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Text(
                 _inCall ? "Connected to Call" : "Ready to Call",
                 style: TextStyle(fontSize: 24),
              ),
            ),
          ),
          SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!_inCall)
              ElevatedButton(
                onPressed: () async {
                  await _signalingService.startCall(_localRenderer, _remoteRenderer);
                  setState(() {
                    _inCall = true;
                  });
                },
                child: Text('Start Call'),
              ),
              if (_inCall)
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () async {
                  await _signalingService.stopAudio();
                  setState(() {
                    _inCall = false;
                  });
                  Navigator.pop(context);
                },
                child: Text('Hang Up'),
              ),
            ],
          ),
          SizedBox(height: 50),
        ],
      ),
    );
  }
}
