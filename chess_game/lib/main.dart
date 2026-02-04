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
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MqttService.isMainIsolate = true;

  await DjangoAuthService().initialize();

  // Initialize MQTT Service (sets up local notifications)
  final mqttService = MqttService();
  await mqttService.initialize();
  mqttService.initializeIsolateListener(isBackground: false);

  // Initialize Background Service for persistent connection
  await BackgroundServiceInstance.initializeService();

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
  // Removed _isDialogShowing as dialogs are now disabled per user request

  @override
  void initState() {
    super.initState();
    _handleInitialNotification();
    _listenForNotifications();
    _checkInitialAuth();
    _setupGlobalSignals();
  }

  void _setupGlobalSignals() {
    // Signals (stopAudio, dismiss_call, etc.) are already routed 
    // through mqttService.notifications stream which we listen to in _listenForNotifications()
  }

  Future<void> _handleInitialNotification() async {
    final details = await MqttService().flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();
    if (details != null && details.didNotificationLaunchApp && details.notificationResponse != null) {
      // Immediately pass to MqttService to buffer it
      MqttService().onNotificationTapped(details.notificationResponse!);
    }
  }

  void _checkInitialAuth() async {
    final authService = DjangoAuthService();
    print('🔍 Checking initial auth. isLoggedIn: ${authService.isLoggedIn}');
    if (authService.isLoggedIn) {
      final username =
          authService.currentUser?['username'] ?? authService.guestName;
      print('🔍 Username: $username');
      if (username != null) {
        await MqttService().connect(username);
      }
    }
  }

  void _listenForNotifications() {
    final mqtt = MqttService();
    
    mqtt.notifications.listen((data) {
      _processNotificationData(data);
    });

    // Check for buffered event (e.g., from cold launch)
    if (mqtt.lastNotificationEvent != null) {
      final event = mqtt.lastNotificationEvent!;
      mqtt.clearLastNotification();
      
      // Safety delay to ensure GoRouter is fully ready
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) {
          _processNotificationData(event);
        }
      });
    }
  }

  void _processNotificationData(Map<String, dynamic> data) async {
    if (!mounted) return;

    final type = data['type'];
    final action = data['action'];
    final payload = data['data'] ?? data['payload'];

    if (type == 'call_ended' || type == 'call_declined' || type == 'call_cancelled' || type == 'dismiss_call') {
      // Stop audio immediately as this is a termination event
      final roomId = payload != null ? payload['room_id'] : null;
      print('🧹 [Main] Termination signal received ($type). Stopping audio and clearing notification...');
      MqttService().stopAudio(broadcast: false, roomId: roomId);
      MqttService().cancelCallNotification(roomId: roomId, broadcast: false);
    } else if (type == 'invitation_response') {
      _handleInvitationResponse(data);
    } else if (type == 'call_invitation') {
      if (action == 'accept') {
        // Cleanup in background without awaiting
        MqttService().stopAudio(broadcast: true);
        MqttService().cancelCallNotification();

        final caller = payload['caller'];
        final roomId = payload['room_id'];
        try {
          context.go('/call?roomId=$roomId&otherUserName=$caller&isCaller=false');
        } catch (e) {
        }
      } else {
        // PER USER REQUEST: Do not show dialog box anymore.
        // User must respond from the system notification.
      }
    } else if (type == 'game_invitation') {
      if (action == 'accept') {
        final roomId = payload['room_id'];
        
        // Navigate immediately
        context.go('/chess?roomId=$roomId&color=b');

        // Cleanup in background
        MqttService().stopAudio(broadcast: true);
        MqttService().cancelCallNotification();
        
        final invitationId = payload['id'];
        if (invitationId != null) {
          GameService.respondToInvitation(
            invitationId: invitationId,
            action: 'accept',
          );
        }
      } else {
        // PER USER REQUEST: Do not show dialog box anymore.
      }
    }
  }

  void _handleInvitationResponse(Map<String, dynamic> data) {
    if (!mounted) return;
    
    final payload = data['data'] ?? data['payload'];
    final action = payload['action'] ?? data['action'];
    final invitation = payload['invitation'] ?? payload;
    final receiver = invitation['receiver']['username'];
    final roomId = invitation['room_id'];

    if (action == 'accept') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$receiver accepted your challenge! Joining game...'),
          backgroundColor: Colors.green,
        ),
      );
      // Navigate to the room as White (since we sent the challenge)
      context.go('/chess?roomId=$roomId&color=w');
    } else if (action == 'decline') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$receiver declined your challenge'),
          backgroundColor: Colors.orange,
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
