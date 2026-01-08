import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../services/signaling_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';
import '../../services/config.dart';
import 'dart:math';
import 'dart:async';

class ChessScreen extends StatefulWidget {
  const ChessScreen({Key? key}) : super(key: key);

  @override
  State<ChessScreen> createState() => _ChessGameScreenState();
}

class _ChessGameScreenState extends State<ChessScreen> {
  final User? user = FirebaseAuth.instance.currentUser;

  // Chess board state
  List<List<String>> board = [];
  String selectedPiece = '';
  int selectedRow = -1;
  int selectedCol = -1;
  bool isWhiteTurn = true;
  String status = "White's turn";
  List<List<bool>> validMoves = [];
  List<Map<String, dynamic>> moveHistory = [];

  // Audio Call State
  SignalingService _signalingService = SignalingService();
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool _isConnectedToRoom = false;
  bool _isAudioOn = false;
  bool _isMuted = false;
  bool _isIncomingCall = false;
  String _callStatus = "";
  String? _playerColor; // 'w' or 'b' in multiplayer mode
  Timer? _statusTimer;

  // New variables for check/checkmate detection
  bool whiteInCheck = false;
  bool blackInCheck = false;
  bool gameOver = false;
  String winner = '';

  final Map<String, String> pieceIcons = {
    'wp': '♙',
    'wr': '♖',
    'wn': '♘',
    'wb': '♗',
    'wq': '♕',
    'wk': '♔',
    'bp': '♟',
    'br': '♜',
    'bn': '♞',
    'bb': '♝',
    'bq': '♛',
    'bk': '♚',
  };

  @override
  void initState() {
    super.initState();
    _initializeBoard();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _signalingService.onAddRemoteStream = ((stream) {
      _remoteRenderer.srcObject = stream;
      _setEphemeralStatus("Voice Connected");
    });

    _signalingService.onGameMove = (data) {
      // Handle remote move
      print("Received move: $data");
      setState(() {
        _handleRemoteMove(data);
      });
    };
    
    _signalingService.onPlayerLeft = () {
       print("Opponent left");
       ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Opponent left the room."),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 5),
            )
       );
       _hangUp(); // Disconnect self
    };
    
    _signalingService.onConnectionState = (isConnected) {
       setState(() {
         _isConnectedToRoom = isConnected;
       });
       if (isConnected) {
         _setEphemeralStatus("Connected to Server");
       } else {
         _setEphemeralStatus("Disconnected");
       }
       if (!isConnected) {
         ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Warning: Disconnected from signaling server."))
         );
       }
    };
    
    _signalingService.onIncomingCall = () {
      setState(() {
        _isIncomingCall = true;
      });
      _setEphemeralStatus("Incoming Call...");
      _showIncomingCallDialog();
    };

    _signalingService.onCallAccepted = () {
       setState(() {
         _isAudioOn = true;
       });
       _setEphemeralStatus("Call Accepted");
    };

    _signalingService.onCallRejected = () {
       setState(() {
         _callStatus = "";
       });
       _setEphemeralStatus("Call Rejected by Opponent");
    };

    _signalingService.onEndCall = () async {
       if (_isAudioOn || _callStatus == "Calling...") {
          await _signalingService.stopAudio();
          setState(() {
            _isAudioOn = false;
            _isIncomingCall = false;
          });
          _setEphemeralStatus("Call Ended");
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Call ended."), duration: Duration(seconds: 2))
          );
       }
    };

    _signalingService.onNewGame = () {
       _initializeBoard();
       _setEphemeralStatus("Opponent started a new game");
    };

    _signalingService.onPlayerJoined = () {
       _setEphemeralStatus("Opponent joined the room");
    };
  }

  void _setEphemeralStatus(String message) {
    _statusTimer?.cancel();
    setState(() {
      _callStatus = message;
    });
    _statusTimer = Timer(Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _callStatus = "";
        });
      }
    });
  }
  
  void _showIncomingCallDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text("Incoming Audio Call"),
        content: Text("Opponent wants to start a voice chat."),
        actions: [
          TextButton(
            onPressed: () {
               Navigator.pop(context);
               _signalingService.sendCallRejected();
               // Reject / Ignore
               setState(() {
                 _isIncomingCall = false;
               });
               _setEphemeralStatus("Call Declined");
            }, 
            child: Text("Reject", style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton.icon(
            icon: Icon(Icons.call),
            label: Text("Accept"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () async {
              Navigator.pop(context);
              await _toggleAudio();
            },
          )
        ],
      )
    );
  }
  
  void _showOpponentLeftDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Disconnected"),
        content: Text("Opponent has left the room."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("OK"),
          )
        ],
      )
    );
  }
  
  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _signalingService.muteAudio(_isMuted);
  }
  
  void _onLogout() {
     if (_isConnectedToRoom) {
       _signalingService.sendBye();
       _hangUp();
     }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _signalingService.hangUp();
    super.dispose();
  }



  void _handleRemoteMove(Map<String, dynamic> data) {
    if (data['type'] == 'move') {
      int fromRow = data['fromRow'];
      int fromCol = data['fromCol'];
      int toRow = data['toRow'];
      int toCol = data['toCol'];
      String piece = data['movedPiece'];
      
      _executeMove(fromRow, fromCol, toRow, toCol, piece);
    }
  }

  // default server url suggestion
  String get _defaultServerUrl {
    return AppConfig.socketUrl;
  }

  void _connectRoom(String serverUrl, String roomId) async {
    // Ensure URL ends with slash if needed, logic depends on backend but typically yes
    String fullUrl = serverUrl;
    if (!fullUrl.endsWith("/")) fullUrl += "/";
    fullUrl += "$roomId/";
    
    setState(() {
      _callStatus = "Connecting...";
    });
    
    print("Connecting to $fullUrl");
    _signalingService.connect(fullUrl);
    
    // Notify room that we joined
    Future.delayed(Duration(milliseconds: 500), () {
       _signalingService.sendJoin();
    });
    
    // Note: Success state is set via onConnectionState callback
  }

  Future<void> _toggleAudio() async {
    if (_isAudioOn) {
       // End Call
       _signalingService.sendEndCall();
       await _signalingService.stopAudio();
       setState(() {
         _isAudioOn = false;
         _isIncomingCall = false;
       });
    } else {
       // Start or Accept Call
       if (_isIncomingCall) {
          // Accept
          await _signalingService.acceptCall(_localRenderer, _remoteRenderer);
          setState(() {
            _isAudioOn = true;
            _isIncomingCall = false;
          });
          _setEphemeralStatus("Call Connected");
       } else {
          // Start Call (Initiator part)
          await _signalingService.startCall(_localRenderer, _remoteRenderer);
          setState(() {
             // We don't set _isAudioOn yet! Wait for onCallAccepted
          });
          _setEphemeralStatus("Calling...");
       }
    }
  }

  void _showRoomDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Play Online'),
          content: Column(
             mainAxisSize: MainAxisSize.min,
             children: [
               const Text("Connect to the multiplayer server to play with others."),
               SizedBox(height: 20),
               ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _playerColor = 'w';
                  _createRoom(_defaultServerUrl);
                },
                child: Text('Create Room (Generate ID)'),
                style: ElevatedButton.styleFrom(minimumSize: Size(double.infinity, 40)),
              ),
              SizedBox(height: 10),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _playerColor = 'b';
                  _showJoinDialog(_defaultServerUrl);
                },
                child: Text('Join Room (Enter ID)'),
                 style: ElevatedButton.styleFrom(minimumSize: Size(double.infinity, 40)),
              ),
             ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  void _createRoom(String serverUrl) {
    // Generate random 4-digit ID
    final String roomId = (1000 + Random().nextInt(9000)).toString();
    _connectRoom(serverUrl, roomId);
    
    // Show ID to user
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Room Created'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Server: $serverUrl'),
            SizedBox(height: 8),
            Text('Room ID (Share this):'),
            SizedBox(height: 4),
            Text(
              roomId,
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 2),
            ),
             SizedBox(height: 20),
            Text('Waiting for opponent...'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showJoinDialog(String serverUrl) async {
    final TextEditingController _roomIdController = TextEditingController();
    
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Join Room'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
               Text("Server: $serverUrl", style: TextStyle(fontSize: 12, color: Colors.grey)),
               SizedBox(height: 10),
               TextField(
                controller: _roomIdController,
                decoration: InputDecoration(hintText: "Enter Room ID (e.g. 1234)"),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final roomId = _roomIdController.text.trim();
                if (roomId.isNotEmpty) {
                  Navigator.pop(context);
                  _connectRoom(serverUrl, roomId);
                }
              },
              child: Text('Join'),
            ),
          ],
        );
      },
    );
  }

  // Deprecated direct join (keeping helper but unused in main UI flow if prefered)
  Future<void> _showJoinCallDialog() async {
    // _showJoinDialog(_defaulturl);
  }

  void _hangUp() async {
    await _signalingService.hangUp();
    setState(() {
      _isConnectedToRoom = false;
      _isAudioOn = false;
      _isIncomingCall = false;
      _callStatus = "Room Disconnected";
      _playerColor = null; // Back to local mode
    });
    
    // Reset board for a fresh local start if desired, or keep as is.
    // _initializeBoard(); 
  }

  void _executeMove(int fromRow, int fromCol, int toRow, int toCol, String piece) {
     if (gameOver) return;

    final capturedPiece = board[toRow][toCol];

    // Record move
    moveHistory.add({
      'fromRow': fromRow,
      'fromCol': fromCol,
      'toRow': toRow,
      'toCol': toCol,
      'movedPiece': piece,
      'capturedPiece': capturedPiece,
      'wasWhiteTurn': isWhiteTurn,
    });

    if (moveHistory.length > 50) moveHistory.removeAt(0);

    // Execute move
    board[toRow][toCol] = piece;
    board[fromRow][fromCol] = '';

    // Switch turns
    isWhiteTurn = !isWhiteTurn;

    // Clear selection
    selectedPiece = '';
    selectedRow = -1;
    selectedCol = -1;

    // Clear valid moves
    for (int i = 0; i < 8; i++) {
      for (int j = 0; j < 8; j++) {
        validMoves[i][j] = false;
      }
    }

    // Update check status
    _updateCheckStatus();

    // Check for checkmate or stalemate
    final currentPlayerInCheck = isWhiteTurn ? whiteInCheck : blackInCheck;
    final hasLegalMoves = _hasAnyLegalMove(isWhiteTurn);

    if (currentPlayerInCheck && !hasLegalMoves) {
      // Checkmate!
      gameOver = true;
      winner = isWhiteTurn ? 'Black' : 'White';
      status = 'Checkmate! $winner wins!';
      _showGameOverDialog('Checkmate! $winner wins!');
    } else if (!currentPlayerInCheck && !hasLegalMoves) {
      // Stalemate
      gameOver = true;
      status = 'Stalemate! Game drawn.';
      _showGameOverDialog('Stalemate! Game drawn.');
    }
  }

  void _movePiece(int toRow, int toCol) {
     // Local move
     // Send move to opponent
     if (_isConnectedToRoom) {
       _signalingService.sendMove({
         'fromRow': selectedRow,
         'fromCol': selectedCol,
         'toRow': toRow,
         'toCol': toCol,
         'movedPiece': selectedPiece,
       });
     }

     setState(() {
        _executeMove(selectedRow, selectedCol, toRow, toCol, selectedPiece);
     });
  }

  void _initializeBoard() {
    board = List.generate(8, (_) => List.filled(8, ''));
    validMoves = List.generate(8, (_) => List.filled(8, false));
    moveHistory.clear();
    whiteInCheck = false;
    blackInCheck = false;
    gameOver = false;
    winner = '';

    // Set up initial pieces
    board[0] = ['br', 'bn', 'bb', 'bq', 'bk', 'bb', 'bn', 'br'];
    board[1] = List.filled(8, 'bp');
    board[6] = List.filled(8, 'wp');
    board[7] = ['wr', 'wn', 'wb', 'wq', 'wk', 'wb', 'wn', 'wr'];

    setState(() {
      status = "White's turn";
      isWhiteTurn = true;
      selectedPiece = '';
      selectedRow = -1;
      selectedCol = -1;
    });
  }

  // Helper functions
  bool _isWhitePiece(String piece) => piece.startsWith('w');
  String _getPieceType(String piece) =>
      piece.length > 1 ? piece.substring(1) : '';

  /// Find the position of a king
  List<int> _findKingPosition(bool findWhiteKing) {
    for (int row = 0; row < 8; row++) {
      for (int col = 0; col < 8; col++) {
        final piece = board[row][col];
        if (piece.isNotEmpty &&
            _getPieceType(piece) == 'k' &&
            _isWhitePiece(piece) == findWhiteKing) {
          return [row, col];
        }
      }
    }
    return [-1, -1]; // Should never happen
  }

  /// Check if a square is under attack by opponent's pieces
  bool _isSquareUnderAttack(int row, int col, bool isWhiteKing) {
    // Check all opponent's pieces and see if they can attack this square
    for (int r = 0; r < 8; r++) {
      for (int c = 0; c < 8; c++) {
        final piece = board[r][c];
        if (piece.isNotEmpty && _isWhitePiece(piece) != isWhiteKing) {
          if (_canPieceAttack(r, c, row, col, piece)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// Check if a piece can attack a specific square
  bool _canPieceAttack(
      int fromRow, int fromCol, int toRow, int toCol, String piece) {
    final pieceType = _getPieceType(piece);
    final isWhite = _isWhitePiece(piece);

    // Simulate the attack using existing movement logic
    if (pieceType == 'p') {
      // Pawn attack pattern (diagonal only)
      final direction = isWhite ? -1 : 1;
      final attackRow = fromRow + direction;
      return (attackRow == toRow &&
          (fromCol - 1 == toCol || fromCol + 1 == toCol));
    } else if (pieceType == 'r') {
      return _canRookAttack(fromRow, fromCol, toRow, toCol, isWhite);
    } else if (pieceType == 'n') {
      final moves = [
        [-2, -1],
        [-2, 1],
        [-1, -2],
        [-1, 2],
        [1, -2],
        [1, 2],
        [2, -1],
        [2, 1],
      ];
      for (final move in moves) {
        if (fromRow + move[0] == toRow && fromCol + move[1] == toCol) {
          return true;
        }
      }
      return false;
    } else if (pieceType == 'b') {
      return _canBishopAttack(fromRow, fromCol, toRow, toCol, isWhite);
    } else if (pieceType == 'q') {
      return _canRookAttack(fromRow, fromCol, toRow, toCol, isWhite) ||
          _canBishopAttack(fromRow, fromCol, toRow, toCol, isWhite);
    } else if (pieceType == 'k') {
      // King can attack adjacent squares
      final rowDiff = (fromRow - toRow).abs();
      final colDiff = (fromCol - toCol).abs();
      return rowDiff <= 1 && colDiff <= 1 && !(rowDiff == 0 && colDiff == 0);
    }

    return false;
  }

  bool _canRookAttack(
      int fromRow, int fromCol, int toRow, int toCol, bool isWhite) {
    // Must be same row or same column
    if (fromRow != toRow && fromCol != toCol) return false;

    // Check if path is clear
    if (fromRow == toRow) {
      // Horizontal movement
      final step = fromCol < toCol ? 1 : -1;
      for (int c = fromCol + step; c != toCol; c += step) {
        if (board[fromRow][c].isNotEmpty) return false;
      }
    } else {
      // Vertical movement
      final step = fromRow < toRow ? 1 : -1;
      for (int r = fromRow + step; r != toRow; r += step) {
        if (board[r][fromCol].isNotEmpty) return false;
      }
    }

    // Check if destination has opponent's piece or is empty
    final targetPiece = board[toRow][toCol];
    return targetPiece.isEmpty || _isWhitePiece(targetPiece) != isWhite;
  }

  bool _canBishopAttack(
      int fromRow, int fromCol, int toRow, int toCol, bool isWhite) {
    // Must be diagonal
    final rowDiff = (fromRow - toRow).abs();
    final colDiff = (fromCol - toCol).abs();
    if (rowDiff != colDiff) return false;

    // Check if diagonal path is clear
    final rowStep = fromRow < toRow ? 1 : -1;
    final colStep = fromCol < toCol ? 1 : -1;

    int r = fromRow + rowStep;
    int c = fromCol + colStep;
    while (r != toRow && c != toCol) {
      if (board[r][c].isNotEmpty) return false;
      r += rowStep;
      c += colStep;
    }

    // Check if destination has opponent's piece or is empty
    final targetPiece = board[toRow][toCol];
    return targetPiece.isEmpty || _isWhitePiece(targetPiece) != isWhite;
  }

  /// Check if the current player's king is in check
  void _updateCheckStatus() {
    // Find both kings
    final whiteKingPos = _findKingPosition(true);
    final blackKingPos = _findKingPosition(false);

    // Check if kings are under attack
    whiteInCheck = _isSquareUnderAttack(whiteKingPos[0], whiteKingPos[1], true);
    blackInCheck =
        _isSquareUnderAttack(blackKingPos[0], blackKingPos[1], false);

    // Update status message
    if (whiteInCheck) {
      status = "White is in check!";
    } else if (blackInCheck) {
      status = "Black is in check!";
    } else if (!gameOver) {
      status = isWhiteTurn ? "White's turn" : "Black's turn";
    }
  }

  /// Check if the current player has any legal moves
  bool _hasAnyLegalMove(bool isWhite) {
    // Check all pieces of the current player
    for (int row = 0; row < 8; row++) {
      for (int col = 0; col < 8; col++) {
        final piece = board[row][col];
        if (piece.isNotEmpty && _isWhitePiece(piece) == isWhite) {
          // Try all possible moves for this piece
          final pieceType = _getPieceType(piece);
          final moves =
              _getAllPossibleMoves(row, col, piece, pieceType, isWhite);

          // Try each move to see if it's legal (doesn't leave king in check)
          for (final move in moves) {
            // Simulate the move
            final originalPiece = board[move[0]][move[1]];
            board[move[0]][move[1]] = piece;
            board[row][col] = '';

            // Check if king is still in check after move
            final kingPos = _findKingPosition(isWhite);
            final stillInCheck =
                _isSquareUnderAttack(kingPos[0], kingPos[1], isWhite);

            // Undo the simulation
            board[row][col] = piece;
            board[move[0]][move[1]] = originalPiece;

            if (!stillInCheck) {
              return true; // Found at least one legal move
            }
          }
        }
      }
    }
    return false; // No legal moves found
  }

  /// Get all possible moves for a piece (without considering check)
  List<List<int>> _getAllPossibleMoves(
      int row, int col, String piece, String pieceType, bool isWhite) {
    List<List<int>> moves = [];

    if (pieceType == 'p') {
      final direction = isWhite ? -1 : 1;
      final newRow = row + direction;

      // Forward move
      if (newRow >= 0 && newRow < 8 && board[newRow][col].isEmpty) {
        moves.add([newRow, col]);

        // Double move
        final startRow = isWhite ? 6 : 1;
        if (row == startRow) {
          final doubleRow = row + 2 * direction;
          if (board[doubleRow][col].isEmpty) {
            moves.add([doubleRow, col]);
          }
        }
      }

      // Diagonal captures
      for (final dc in [-1, 1]) {
        final newCol = col + dc;
        if (newRow >= 0 && newRow < 8 && newCol >= 0 && newCol < 8) {
          final targetPiece = board[newRow][newCol];
          if (targetPiece.isNotEmpty && _isWhitePiece(targetPiece) != isWhite) {
            moves.add([newRow, newCol]);
          }
        }
      }
    } else if (pieceType == 'r') {
      moves.addAll(_getRookMoves(row, col, isWhite));
    } else if (pieceType == 'n') {
      moves.addAll(_getKnightMoves(row, col, isWhite));
    } else if (pieceType == 'b') {
      moves.addAll(_getBishopMoves(row, col, isWhite));
    } else if (pieceType == 'q') {
      moves.addAll(_getRookMoves(row, col, isWhite));
      moves.addAll(_getBishopMoves(row, col, isWhite));
    } else if (pieceType == 'k') {
      moves.addAll(_getKingMoves(row, col, isWhite));
    }

    return moves;
  }

  // Individual piece move generators
  List<List<int>> _getRookMoves(int row, int col, bool isWhite) {
    List<List<int>> moves = [];
    for (int dr in [-1, 0, 1]) {
      for (int dc in [-1, 0, 1]) {
        if ((dr == 0 && dc == 0) || (dr != 0 && dc != 0)) continue;

        for (int step = 1; step < 8; step++) {
          final newRow = row + dr * step;
          final newCol = col + dc * step;

          if (newRow < 0 || newRow >= 8 || newCol < 0 || newCol >= 8) break;

          final targetPiece = board[newRow][newCol];
          if (targetPiece.isEmpty) {
            moves.add([newRow, newCol]);
          } else {
            if (_isWhitePiece(targetPiece) != isWhite) {
              moves.add([newRow, newCol]);
            }
            break;
          }
        }
      }
    }
    return moves;
  }

  List<List<int>> _getKnightMoves(int row, int col, bool isWhite) {
    List<List<int>> moves = [];
    final knightMoves = [
      [-2, -1],
      [-2, 1],
      [-1, -2],
      [-1, 2],
      [1, -2],
      [1, 2],
      [2, -1],
      [2, 1],
    ];

    for (final move in knightMoves) {
      final newRow = row + move[0];
      final newCol = col + move[1];

      if (newRow >= 0 && newRow < 8 && newCol >= 0 && newCol < 8) {
        final targetPiece = board[newRow][newCol];
        if (targetPiece.isEmpty || _isWhitePiece(targetPiece) != isWhite) {
          moves.add([newRow, newCol]);
        }
      }
    }
    return moves;
  }

  List<List<int>> _getBishopMoves(int row, int col, bool isWhite) {
    List<List<int>> moves = [];
    for (int dr in [-1, 1]) {
      for (int dc in [-1, 1]) {
        for (int step = 1; step < 8; step++) {
          final newRow = row + dr * step;
          final newCol = col + dc * step;

          if (newRow < 0 || newRow >= 8 || newCol < 0 || newCol >= 8) break;

          final targetPiece = board[newRow][newCol];
          if (targetPiece.isEmpty) {
            moves.add([newRow, newCol]);
          } else {
            if (_isWhitePiece(targetPiece) != isWhite) {
              moves.add([newRow, newCol]);
            }
            break;
          }
        }
      }
    }
    return moves;
  }

  List<List<int>> _getKingMoves(int row, int col, bool isWhite) {
    List<List<int>> moves = [];
    for (int dr = -1; dr <= 1; dr++) {
      for (int dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;

        final newRow = row + dr;
        final newCol = col + dc;

        if (newRow >= 0 && newRow < 8 && newCol >= 0 && newCol < 8) {
          final targetPiece = board[newRow][newCol];
          if (targetPiece.isEmpty || _isWhitePiece(targetPiece) != isWhite) {
            // Check if the destination is not under attack
            if (!_isSquareUnderAttack(newRow, newCol, isWhite)) {
              moves.add([newRow, newCol]);
            }
          }
        }
      }
    }
    return moves;
  }

  void _calculateValidMoves(int row, int col, String piece) {
    // Reset all valid moves
    for (int i = 0; i < 8; i++) {
      for (int j = 0; j < 8; j++) {
        validMoves[i][j] = false;
      }
    }

    final pieceType = _getPieceType(piece);
    final isWhite = _isWhitePiece(piece);

    // Get all possible moves for this piece
    final moves = _getAllPossibleMoves(row, col, piece, pieceType, isWhite);

    // Filter moves that would leave king in check
    for (final move in moves) {
      final toRow = move[0];
      final toCol = move[1];

      // Simulate the move
      final originalPiece = board[toRow][toCol];
      board[toRow][toCol] = piece;
      board[row][col] = '';

      // Check if king is still in check after this move
      final kingPos = _findKingPosition(isWhite);
      final stillInCheck =
          _isSquareUnderAttack(kingPos[0], kingPos[1], isWhite);

      // Undo the simulation
      board[row][col] = piece;
      board[toRow][toCol] = originalPiece;

      // Only allow move if it doesn't leave king in check
      if (!stillInCheck) {
        validMoves[toRow][toCol] = true;
      }
    }
  }

  void _onSquareTap(int row, int col) {
    if (gameOver) return;

    final piece = board[row][col];

    if (selectedPiece.isEmpty) {
      // Selecting a piece
      if (piece.isNotEmpty) {
        final isPieceWhite = _isWhitePiece(piece);
        
        // Multiplayer movement restriction
        if (_isConnectedToRoom && _playerColor != null) {
           final isMyPiece = (isPieceWhite && _playerColor == 'w') || (!isPieceWhite && _playerColor == 'b');
           if (!isMyPiece) {
             ScaffoldMessenger.of(context).showSnackBar(
               SnackBar(content: Text("That is your opponent's piece!"), duration: Duration(milliseconds: 500))
             );
             return;
           }
        }

        if ((isPieceWhite && isWhiteTurn) || (!isPieceWhite && !isWhiteTurn)) {
          _calculateValidMoves(row, col, piece);
          setState(() {
            selectedPiece = piece;
            selectedRow = row;
            selectedCol = col;
          });
        }
      }
    } else if (validMoves[row][col]) {
      // Moving to a valid square
      _movePiece(row, col);
    } else if (piece.isNotEmpty &&
        _isWhitePiece(piece) == _isWhitePiece(selectedPiece)) {
      // Selecting a different piece of the same color
      _calculateValidMoves(row, col, piece);
      setState(() {
        selectedPiece = piece;
        selectedRow = row;
        selectedCol = col;
      });
    } else {
      // Clicking elsewhere - clear selection
      setState(() {
        selectedPiece = '';
        selectedRow = -1;
        selectedCol = -1;
        for (int i = 0; i < 8; i++) {
          for (int j = 0; j < 8; j++) {
            validMoves[i][j] = false;
          }
        }
      });
    }
  }

  void _undoMove() {
    if (moveHistory.isEmpty || gameOver) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No moves to undo')),
      );
      return;
    }

    final lastMove = moveHistory.removeLast();

    setState(() {
      // Restore captured piece
      board[lastMove['toRow']][lastMove['toCol']] = lastMove['capturedPiece'];
      // Move piece back
      board[lastMove['fromRow']][lastMove['fromCol']] = lastMove['movedPiece'];
      // Restore turn
      isWhiteTurn = lastMove['wasWhiteTurn'];

      // Update check status
      _updateCheckStatus();

      // Clear selection
      selectedPiece = '';
      selectedRow = -1;
      selectedCol = -1;

      // Clear valid moves
      for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 8; j++) {
          validMoves[i][j] = false;
        }
      }
    });
  }

  void _showGameOverDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Game Over'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _initializeBoard();
            },
            child: const Text('New Game'),
          ),
        ],
      ),
    );
  }

  Widget _buildChessSquare(int row, int col) {
    final piece = board[row][col];
    final isWhiteSquare = (row + col) % 2 == 0;
    final isSelected = row == selectedRow && col == selectedCol;
    final isValidMove = validMoves[row][col];

    // Check if this square contains a king in check
    bool isKingInCheck = false;
    if (piece.isNotEmpty && _getPieceType(piece) == 'k') {
      isKingInCheck = _isWhitePiece(piece) ? whiteInCheck : blackInCheck;
    }

    Color squareColor;
    if (isSelected) {
      squareColor = Colors.yellow.withOpacity(0.5);
    } else if (isValidMove) {
      squareColor = Colors.green.withOpacity(0.3);
    } else if (isKingInCheck) {
      squareColor = Colors.red.withOpacity(0.5); // Red for king in check
    } else {
      squareColor =
          isWhiteSquare ? const Color(0xFFF0D9B5) : const Color(0xFFB58863);
    }

    return GestureDetector(
      onTap: () => _onSquareTap(row, col),
      child: Container(
        decoration: BoxDecoration(
          color: squareColor,
          border: Border.all(color: Colors.black12, width: 0.5),
        ),
        child: Center(
          child: piece.isEmpty
              ? const SizedBox()
              : Text(
                  pieceIcons[piece] ?? '',
                  style: TextStyle(
                    fontSize: 30,
                    color: _isWhitePiece(piece) ? Colors.white : Colors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chess Game'),
        backgroundColor: Colors.blue[800],
        actions: [
          if (_isConnectedToRoom) ...[
             if (!_isAudioOn)
               IconButton(
                 icon: const Icon(Icons.call, color: Colors.white),
                 onPressed: _toggleAudio,
                 tooltip: "Start Audio Call",
               ),
             if (_isAudioOn) ...[
                 IconButton(
                   icon: Icon(_isMuted ? Icons.mic_off : Icons.mic),
                   color: _isMuted ? Colors.red : Colors.white,
                   onPressed: _toggleMute,
                   tooltip: _isMuted ? "Unmute" : "Mute",
                 ),
                 IconButton(
                   icon: const Icon(Icons.call_end, color: Colors.red),
                   onPressed: _toggleAudio, // Ends audio call
                   tooltip: 'End Call',
                 ),
             ],
             IconButton(
               icon: const Icon(Icons.logout, color: Colors.white),
               onPressed: _onLogout,
               tooltip: 'Leave Room',
             ),
          ]
        ],
      ),
      body: Column(
        children: [
          // User Profile Header
          GestureDetector(
            onTap: () => context.go('/profile'),
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.blue[50],
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.blue[100],
                    backgroundImage: user?.photoURL != null
                        ? NetworkImage(user!.photoURL!)
                        : null,
                    child: user?.photoURL == null
                        ? Icon(
                            Icons.person,
                            size: 24,
                            color: Colors.blue[800],
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.displayName ?? 'Chess Player',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          user?.email ?? 'No email',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: Colors.grey[500],
                  ),
                ],
              ),
            ),
          ),

          // Game Status with check indicator
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            color: isWhiteTurn ? Colors.white : Colors.black,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isWhiteTurn ? Colors.black : Colors.white,
                  ),
                ),
                if (whiteInCheck || blackInCheck)
                  Icon(
                    Icons.warning,
                    color: Colors.red,
                    size: 20,
                  ),
                Text(
                  'Moves: ${moveHistory.length}',
                  style: TextStyle(
                    fontSize: 14,
                    color: isWhiteTurn ? Colors.black54 : Colors.white70,
                  ),
                ),
              ],
            ),
          ),

          // Chess Board
          Expanded(
            child: Center(
              child: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                height: MediaQuery.of(context).size.width * 0.9,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.brown, width: 4),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 8,
                  ),
                  itemCount: 64,
                  itemBuilder: (context, index) {
                    final row = index ~/ 8;
                    final col = index % 8;
                    return _buildChessSquare(row, col);
                  },
                ),
              ),
            ),
          ),
          // Call Status Footer (Only show when message is active)
          if (_callStatus.isNotEmpty)
            Container(
              padding: EdgeInsets.all(8),
              width: double.infinity,
              color: Colors.green[100],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.green[800]),
                  SizedBox(width: 8),
                  Text(
                    _callStatus,
                    style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),

          // Controls
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _isConnectedToRoom ? null : _undoMove,
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo Move'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isConnectedToRoom ? Colors.grey : Colors.orange,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    if (_isConnectedToRoom) {
                       _signalingService.sendNewGame();
                    }
                    _initializeBoard();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('New Game'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _showRoomDialog,
                  icon: const Icon(Icons.videogame_asset),
                  label: const Text('Play Online'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
