import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';

class CallScreen extends StatefulWidget {
  final String roomId;
  final String host; // For testing, pass host (e.g. 10.0.2.2:8000)

  const CallScreen({Key? key, required this.roomId, required this.host}) : super(key: key);

  @override
  _CallScreenState createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
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
  }

  void _connect() async {
    // Ideally user ID or game ID is the room ID
    _signalingService.connect(widget.host, widget.roomId);
    
    // Auto-open user media on enter (optional, or wait for call button)
    // await _signalingService.openUserMedia(_localRenderer, _remoteRenderer);
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
                  await _signalingService.openUserMedia(_localRenderer, _remoteRenderer);
                  await _signalingService.call();
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
                  await _signalingService.hangUp();
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
