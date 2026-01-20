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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final GoRouter router = GoRouter(
      initialLocation: '/login',
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
            final roomId = state.uri.queryParameters['roomId'] ?? 'testroom';
            final callerName = state.uri.queryParameters['callerName'] ?? '';
            return CallScreen(roomId: roomId, callerName: callerName);
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
