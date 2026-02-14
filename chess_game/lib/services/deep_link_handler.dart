import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

class DeepLinkHandler {
  // Singleton pattern
  static final DeepLinkHandler _instance = DeepLinkHandler._internal();
  factory DeepLinkHandler() => _instance;
  DeepLinkHandler._internal();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  /// Initialize deep link listener
  Future<void> initialize(Function(Uri) onLinkReceived) async {
    // Handle initial link if app was opened via deep link
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        print('📎 Initial deep link: $initialUri');
        onLinkReceived(initialUri);
      }
    } catch (e) {
      print('❌ Failed to get initial link: $e');
    }

    // Listen for deep links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (Uri uri) {
        print('📎 Deep link received: $uri');
        onLinkReceived(uri);
      },
      onError: (err) {
        print('❌ Deep link error: $err');
      },
    );
  }

  /// Parse deep link and extract parameters
  DeepLinkData parseDeepLink(Uri uri) {
    final path = uri.path;
    final queryParams = uri.queryParameters;

    // Determine the type of deep link
    if (path.contains('/play')) {
      return DeepLinkData(
        type: DeepLinkType.play,
        gameId: queryParams['gameId'],
        roomId: queryParams['roomId'],
      );
    } else if (path.contains('/game/')) {
      // Extract game ID from path like /game/123
      final gameId = path.split('/').last;
      return DeepLinkData(
        type: DeepLinkType.game,
        gameId: gameId,
      );
    } else if (path.contains('/profile')) {
      return DeepLinkData(
        type: DeepLinkType.profile,
        username: queryParams['username'],
      );
    } else {
      return DeepLinkData(type: DeepLinkType.home);
    }
  }

  /// Dispose the listener
  void dispose() {
    _linkSubscription?.cancel();
  }
}

/// Deep link types
enum DeepLinkType {
  home,
  play,
  game,
  profile,
}

/// Deep link data model
class DeepLinkData {
  final DeepLinkType type;
  final String? gameId;
  final String? roomId;
  final String? username;

  DeepLinkData({
    required this.type,
    this.gameId,
    this.roomId,
    this.username,
  });

  @override
  String toString() {
    return 'DeepLinkData(type: $type, gameId: $gameId, roomId: $roomId, username: $username)';
  }
}
