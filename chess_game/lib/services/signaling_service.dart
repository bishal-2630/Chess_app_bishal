import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef void StreamStateCallback(MediaStream stream);

class SignalingService {
  WebSocketChannel? _channel;
  String? _roomId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  List<RTCIceCandidate> _remoteCandidates = [];
  
  StreamStateCallback? onLocalStream;
  StreamStateCallback? onAddRemoteStream;
  StreamStateCallback? onRemoveRemoteStream;
  
  // Stun servers
  Map<String, dynamic> configuration = {
    'iceServers': [
      {
        'urls': [
          'stun:stun1.l.google.com:19302',
          'stun:stun2.l.google.com:19302'
        ]
      }
    ]
  };

  void connect(String host, String roomId) {
    _roomId = roomId;
    // Assuming 'ws' for local dev, wss for production. Adjust port/host as needed.
    // e.g. ws://10.0.2.2:8000/ws/call/ROOMID/ if using Android Emulator
    _channel = WebSocketChannel.connect(Uri.parse('ws://$host/ws/call/$roomId/'));

    _channel!.stream.listen((message) {
      print('Received message: $message');
      _onMessage(jsonDecode(message));
    });
  }

  Future<void> _onMessage(Map<String, dynamic> data) async {
    String type = data['type'];
    Map<String, dynamic> payload = data['payload'] ?? data; // handle structure variations

    switch (type) {
      case 'offer':
        await _handleOffer(payload);
        break;
      case 'answer':
        await _handleAnswer(payload);
        break;
      case 'candidate':
        await _handleCandidate(payload);
        break;
      default:
        print('Unknown message type: $type');
    }
  }

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection(configuration);

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        _send('candidate', {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty && onAddRemoteStream != null) {
          onAddRemoteStream!(event.streams[0]);
        }
    };

    // Add local stream
    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
         _peerConnection!.addTrack(track, _localStream!);
      });
    }
  }

  Future<void> openUserMedia(RTCVideoRenderer localVideo, RTCVideoRenderer remoteVideo) async {
     final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': false, // Audio only call
    };

    try {
      var stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localStream = stream;
      if (onLocalStream != null) {
          onLocalStream!(stream);
      }
    } catch (e) {
      print(e);
    }
  }

  Future<void> call() async {
    await _createPeerConnection();
    
    RTCSessionDescription offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    
    _send('offer', {
      'sdp': offer.sdp,
      'type': offer.type,
    });
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
     await _createPeerConnection();

     var description = RTCSessionDescription(data['sdp'], data['type']);
     await _peerConnection!.setRemoteDescription(description);

     RTCSessionDescription answer = await _peerConnection!.createAnswer();
     await _peerConnection!.setLocalDescription(answer);

     _send('answer', {
       'sdp': answer.sdp,
       'type': answer.type,
     });
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
     var description = RTCSessionDescription(data['sdp'], data['type']);
     await _peerConnection!.setRemoteDescription(description);
  }

  Future<void> _handleCandidate(Map<String, dynamic> data) async {
    var candidate = RTCIceCandidate(
      data['candidate'], 
      data['sdpMid'], 
      data['sdpMLineIndex']
    );
    
    if (_peerConnection != null) {
       await _peerConnection!.addCandidate(candidate);
    }
  }

  void _send(String type, Map<String, dynamic> data) {
     if (_channel != null) {
       _channel!.sink.add(jsonEncode({
         'type': type,
         ...data
       }));
     }
  }

  Future<void> hangUp() async {
      try {
        if (_localStream != null) {
          _localStream!.dispose();
          _localStream = null;
        }
        if (_peerConnection != null) {
          _peerConnection!.close();
          _peerConnection = null;
        }
        if (_channel != null) {
           _channel!.sink.close();
        }
      } catch (e) {
        print(e.toString());
      }
  }
}
