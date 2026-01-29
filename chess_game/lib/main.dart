import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/register_screen.dart';
import 'screens/auth/forgot_password.dart';
import 'screens/game/chess_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/call_screen.dart';
import 'screens/users/user_list_screen.dart';
import 'screens/users/invitations_screen.dart';
import 'services/django_auth_service.dart';
import 'services/notification_service.dart';
import 'services/mqtt_service.dart';
import 'services/game_service.dart';
import 'services/background_service.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await DjangoAuthService().initialize();

  // Initialize MQTT Service (sets up local notifications)
  final mqttService = MqttService();
  await mqttService.initialize();

  // Initialize background service to keep MQTT alive when app is closed
  // Temporarily disabled for testing
  // await BackgroundServiceInstance.initializeService();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = DjangoAuthService();
    final GoRouter router = GoRouter(
      initialLocation: authService.isLoggedIn ? '/chess' : '/login',
      routes: [
        ShellRoute(
          builder: (context, state, child) {
            return IncomingCallWrapper(child: child);
          },
          routes: [
            GoRoute(
              path: '/login',
              builder: (context, state) => const LoginScreen(),
            ),
            GoRoute(
              path: '/register',
              builder: (context, state) => const RegisterScreen(),
            ),
            GoRoute(
              path: '/forgot-password',
              builder: (context, state) => const ForgotPasswordScreen(),
            ),
            GoRoute(
              path: '/chess',
              builder: (context, state) {
                final roomId = state.uri.queryParameters['roomId'];
                final color = state.uri.queryParameters['color'];
                return ChessScreen(roomId: roomId, color: color);
              },
            ),
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
            GoRoute(
              path: '/call',
              builder: (context, state) {
                final roomId =
                    state.uri.queryParameters['roomId'] ?? 'testroom';
                final otherUserName =
                    state.uri.queryParameters['otherUserName'] ??
                        state.uri.queryParameters['callerName'] ??
                        'Unknown';
                final isCaller =
                    state.uri.queryParameters['isCaller'] == 'true';

                return CallScreen(
                  roomId: roomId,
                  otherUserName: otherUserName,
                  isCaller: isCaller,
                );
              },
            ),
            GoRoute(
              path: '/users',
              builder: (context, state) => const UserListScreen(),
            ),
            GoRoute(
              path: '/invitations',
              builder: (context, state) => const InvitationsScreen(),
            ),
          ],
        ),
      ],
      redirect: (context, state) {
        final authService = DjangoAuthService();
        final isLoggedIn = authService.isLoggedIn;
        final currentPath = state.uri.path;
        final isAuthPage = currentPath == '/login' ||
            currentPath == '/register' ||
            currentPath == '/forgot-password';

        // Force authentication check
        if (!isLoggedIn && !isAuthPage) {
          return '/login';
        }

        // If logged in and trying to access auth pages, go to chess
        if (isLoggedIn && isAuthPage) {
          return '/chess';
        }
        return null;
      },
    );

    return MaterialApp.router(
      title: 'Chess Game',
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
    );
  }
}

class IncomingCallWrapper extends StatefulWidget {
  final Widget child;
  const IncomingCallWrapper({super.key, required this.child});

  @override
  _IncomingCallWrapperState createState() => _IncomingCallWrapperState();
}

class _IncomingCallWrapperState extends State<IncomingCallWrapper> {
  @override
  void initState() {
    super.initState();
    _listenForNotifications();
    _checkInitialAuth();
  }

  void _checkInitialAuth() async {
    final authService = DjangoAuthService();
    print('🔍 Checking initial auth. isLoggedIn: ${authService.isLoggedIn}');
    if (authService.isLoggedIn) {
      final username =
          authService.currentUser?['username'] ?? authService.guestName;
      print('🔍 Username: $username');
      if (username != null) {
        print('🔌 Attempting to connect MQTT for user: $username');
        await MqttService().connect(username);
        print('🔌 MQTT connect call completed');
      }
    }
  }

  void _listenForNotifications() {
    MqttService().notifications.listen((data) {
      if (!mounted) return;

      final type = data['type'];
      final payload = data['data'] ?? data['payload'];
      final action = data['action']; // Check if this came from a notification action

      if (type == 'call_invitation') {
        // If user tapped Accept on notification, go directly to call screen
        if (action == 'accept') {
          final caller = payload['caller'];
          final roomId = payload['room_id'];
          print('📞 Auto-accepting call from notification');
          try {
            GoRouter.of(context).push(
                '/call?roomId=$roomId&otherUserName=$caller&isCaller=false');
          } catch (e) {
            print("Navigation failed: $e");
          }
        } else {
          // Show dialog for normal MQTT notification
          _showIncomingCallDialog(payload);
        }
      } else if (type == 'game_invitation') {
        _showGameInvitationDialog(payload);
      } else if (type == 'invitation_response') {
        _handleInvitationResponse(payload);
      }
    });
  }

  void _handleInvitationResponse(Map<String, dynamic> data) {
    final action = data['action'];
    final invitation = data['invitation'];
    final receiver = invitation['receiver']['username'];
    final roomId = invitation['room_id'];

    if (action == 'accept' && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$receiver accepted your challenge! Joining game...'),
          backgroundColor: Colors.green,
        ),
      );
      // Navigate to the room as White (since we sent the challenge)
      context.go('/chess?roomId=$roomId&color=w');
    }
  }

  Future<void> _declineInvitation(int invitationId) async {
    try {
      await GameService.respondToInvitation(
        invitationId: invitationId,
        action: 'decline',
      );
    } catch (e) {
      print('Error declining invitation: $e');
    }
  }

  void _showIncomingCallDialog(Map<String, dynamic> callData) {
    if (!mounted) return;

    final caller = callData['caller'];
    final roomId = callData['room_id'];

    showDialog(
      context:
          context, // This context works because it's inside MaterialApp builder?
      // Actually, this context is ABOVE the Navigator if wrapping child.
      // We need a context that has a Material ancestor?
      // MaterialApp -> builder -> IncomingCallWrapper -> child(Navigator).
      // So IncomingCallWrapper is inside MaterialApp. It should work.
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Incoming Call'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              child: Text(caller[0].toUpperCase()),
            ),
            const SizedBox(height: 16),
            Text('$caller is calling you...'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              MqttService().cancelCallNotification();
              Navigator.of(dialogContext).pop();
              
              // Send decline signal to caller
              GameService.declineCall(
                callerUsername: caller,
                roomId: roomId,
              );
            },
            child: const Text('Decline', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () {
              MqttService().cancelCallNotification();
              Navigator.of(dialogContext).pop();
              // Navigate to call screen as Callee (isCaller=false)
              try {
                GoRouter.of(context).push(
                    '/call?roomId=$roomId&otherUserName=$caller&isCaller=false');
              } catch (e) {
                print("Navigation failed: $e");
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  void _showGameInvitationDialog(Map<String, dynamic> invData) {
    if (!mounted) return;

    final sender = invData['sender']['username'] ?? invData['sender'];
    final roomId = invData['room_id'];
    final invitationId = invData['id'];

    Timer? expiryTimer;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        // Auto-dismiss after 1 minute
        expiryTimer = Timer(const Duration(minutes: 1), () {
          if (mounted) {
            Navigator.of(dialogContext).pop();
            _declineInvitation(invitationId);
          }
        });

        return AlertDialog(
          title: const Text('Game Challenge'),
          content: Text(
              '$sender has challenged you to a game!\n\nThis invitation expires in 60 seconds.'),
          actions: [
            TextButton(
              onPressed: () {
                expiryTimer?.cancel();
                MqttService().cancelCallNotification();
                Navigator.of(dialogContext).pop();
                _declineInvitation(invitationId);
              },
              child: const Text('Decline', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () {
                expiryTimer?.cancel();
                MqttService().cancelCallNotification();
                Navigator.of(dialogContext).pop();
                // Directly Accept
                GameService.respondToInvitation(
                  invitationId: invitationId,
                  action: 'accept',
                ).then((result) {
                  if (result['success']) {
                    context.go('/chess?roomId=$roomId&color=b');
                  }
                });
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Accept'),
            ),
          ],
        );
      },
    ).then((_) => expiryTimer?.cancel());
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
