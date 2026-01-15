import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../services/config.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class AuthService {


  // Singleton pattern
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: '764791811000-kn05hpnb455ddt2l3ib414lgorv8pj14.apps.googleusercontent.com',
  );
  final CookieManager _cookieManager = CookieManager.instance();

  // Guest State
  bool _isGuest = false;
  String? _guestName;

  bool get isGuest => _isGuest;
  String? get guestName => _guestName;

  String get _baseUrl {
    return AppConfig.baseUrl;
  }

  // --- Auth Methods ---

  Future<void> loginAsGuest(String name) async {
    _isGuest = true;
    _guestName = name;
    print('👤 Logged in as Guest: $name');
  }

  void logoutGuest() {
    _isGuest = false;
    _guestName = null;
    print('👤 Guest logged out');
  }

  // Sign In with Email/Password
  Future<User?> signInWithEmailPassword(String email, String password) async {
    logoutGuest(); // Clear guest state if logging in
    print('🔐 Attempting sign in with email: $email');

    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      
      // Sync session with backend to get cookies
      await syncSessionWithBackend(userCredential.user);
      
      print('✅ Sign in successful: ${userCredential.user?.email}');
      return userCredential.user;
    } on FirebaseAuthException catch (e) {
      print('❌ Firebase Auth Error: ${e.code} - ${e.message}');

      if (e.code == 'user-not-found') {
        throw Exception(
            'No account found with this email. Please register first.');
      } else if (e.code == 'wrong-password') {
        throw Exception('Incorrect password. Please try again.');
      } else if (e.code == 'invalid-email') {
        throw Exception('Invalid email format.');
      } else if (e.code == 'user-disabled') {
        throw Exception('This account has been disabled.');
      } else if (e.code == 'too-many-requests') {
        throw Exception('Too many attempts. Please try again later.');
      }

      throw Exception('Login failed: ${e.message}');
    } catch (e) {
      print('❌ General Error: $e');
      throw Exception('Login failed. Please try again.');
    }
  }

  // Register with Email/Password
  Future<User?> registerWithEmailPassword(
      String email, String password, String username) async {
    print('📝 Starting registration for: $email');

    try {
      UserCredential userCredential =
          await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      if (username.isNotEmpty) {
        await userCredential.user!.updateDisplayName(username);
      }

      await userCredential.user!.reload();

      // Sync session with backend
      await syncSessionWithBackend(userCredential.user);

      print('✅ Registration successful: ${userCredential.user?.email}');
      return userCredential.user;
    } catch (e) {
      print('❌ Registration error: $e');

      if (e.toString().contains('email-already-in-use')) {
        throw Exception(
            'This email is already registered. Please login instead.');
      } else if (e.toString().contains('weak-password')) {
        throw Exception('Password is too weak. Use at least 6 characters.');
      }

      throw Exception('Registration failed: $e');
    }
  }

  // Sign In with Google
  Future<User?> signInWithGoogle() async {
    logoutGuest(); // Clear guest state
    print('🔄 Starting Google sign in');

    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      if (googleUser == null) {
        print('User cancelled Google sign in');
        return null;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential =
          await _auth.signInWithCredential(credential);

      // Sync session with backend to get cookies
      await syncSessionWithBackend(userCredential.user);

      print('✅ Google sign in successful: ${userCredential.user?.email}');
      return userCredential.user;
    } on FirebaseAuthException catch (e) {
      print('❌ Firebase Auth Error: ${e.code} - ${e.message}');

      if (e.code == 'invalid-credential') {
        throw Exception(
            'Google Sign-In configuration error. Please check Firebase setup.');
      } else if (e.code == 'account-exists-with-different-credential') {
        throw Exception(
            'This email is already registered with a different sign-in method.');
      }

      throw Exception('Google sign in failed: ${e.message}');
    } catch (e) {
      print('❌ Google sign in error: $e');
      throw Exception(
          'Google sign in failed. Please make sure Google Play Services are updated.');
    }
  }

  // Sync session with Django backend to inject cookies
  Future<void> syncSessionWithBackend(User? user) async {
    if (user == null) return;
    
    try {
      print('🔄 Syncing session with backend...');
      String? token = await user.getIdToken();
      if (token == null) return;

      final url = '${_baseUrl}firebase-login/';
      
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: json.encode({'firebase_token': token}),
      );

      if (response.statusCode == 200) {
        print('✅ Session synced with backend');
        print('📦 Response Body: ${response.body}');
        
        // Extract cookies from response headers
        String? rawCookie = response.headers['set-cookie'];
        if (rawCookie != null) {
           print('🍪 Found cookies to inject');
           await _injectCookies(rawCookie);
        } else {
           print('⚠️ No set-cookie header found in response');
        }
      } else {
        print('❌ Failed to sync session: ${response.statusCode}');
        print('📦 Error Body: ${response.body}');
        try {
          final errorData = json.decode(response.body);
          if (errorData['detail'] != null) {
            print('🔍 Backend Message: ${errorData['detail']}');
          }
        } catch (e) {
          print('Could not parse error body: $e');
        }
      }
    } catch (e) {
      print('❌ Error syncing session: $e');
    }
  }

  Future<void> _injectCookies(String rawCookie) async {
    try {
      // Basic parsing to split multiple cookies if present
      // Note: set-cookie header might be combined or separate depending on the http client and server.
      // 'http' package combines them with commas, but cookies themselves can contain commas (in dates).
      // A simple split might be risky, but common for simple session/csrf cookies.
      
      // Better approach: Regex or specialized parser. For now, we assume standard Django cookies.
      
      // Determine domain from baseUrl
      Uri uri = Uri.parse(_baseUrl);
      String domain = uri.host;
      
      // Split by comma only if it looks like a separator (followed by key=value)
      // This is a naive implementation; for production consider 'cookie_jar' or similar.
      List<String> cookies = rawCookie.split(RegExp(r',(?=\s*[a-zA-Z0-9_-]+=)')); 
      
      for (String cookie in cookies) {
        int equalsIndex = cookie.indexOf('=');
        if (equalsIndex == -1) continue;
        
        String key = cookie.substring(0, equalsIndex).trim();
        String valueAndAttributes = cookie.substring(equalsIndex + 1).trim();
        
        // Extract value (semicolon terminates value)
        int semiIndex = valueAndAttributes.indexOf(';');
        String value = semiIndex == -1 ? valueAndAttributes : valueAndAttributes.substring(0, semiIndex);
        
        print('🍪 Injecting Cookie: $key for domain: $domain');
        
        await _cookieManager.setCookie(
          url: WebUri(_baseUrl), 
          name: key, 
          value: value,
          domain: domain,
          path: "/",
          isHttpOnly: false, 
          isSecure: uri.scheme == 'https', 
        );
      }
    } catch (e) {
      print('❌ Error injecting cookies: $e');
    }
  }

  // NEW: Send Password Reset OTP via Django
  Future<Map<String, dynamic>> sendPasswordResetOTP(String email) async {
    print("📱 Sending OTP to: $email");

    try {
      final url = '${_baseUrl}send-otp/';
      print("🌐 Calling: $url");

      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'email': email}),
          )
          .timeout(const Duration(seconds: 20));

      print("📡 Response status: ${response.statusCode}");

      final responseData = json.decode(response.body);

      if (response.statusCode == 200) {
        if (responseData['success'] == true) {
          print("✅ OTP sent successfully!");
          return {
            'success': true,
            'message': responseData['message'] ?? 'OTP sent successfully!',
            'expires_in': responseData['expires_in'] ?? 600,
          };
        } else {
          return {
            'success': false,
            'message': responseData['message'] ?? 'Failed to send OTP',
          };
        }
      } else {
        return {
          'success': false,
          'message': 'Server error: ${response.statusCode}. ${responseData['message'] ?? ""}',
        };
      }
    } on TimeoutException {
      print("⏱️ Request timeout - backend might be slow or email sending delayed");
      return {
        'success': false,
        'message': 'Connection timeout. The server is taking too long to respond. Please try again.',
      };
    } catch (e) {
      print("❌ Network error: $e");
      return {
        'success': false,
        'message': 'Backend connection failed: ${e.toString()}',
      };
    }
  }

  // NEW: Verify OTP via Django
  Future<Map<String, dynamic>> verifyOTP(String email, String otp) async {
    try {
      final url = '${_baseUrl}verify-otp/';
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'otp': otp}),
      );

      final responseData = json.decode(response.body);

      if (response.statusCode == 200) {
        return {
          'success': responseData['success'] ?? false,
          'message': responseData['message'] ?? 'OTP verification completed',
        };
      } else {
        return {
          'success': false,
          'message': responseData['message'] ?? 'OTP verification failed',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  // NEW: Reset Password with OTP via Django
  Future<Map<String, dynamic>> resetPasswordWithOTP(
    String email,
    String otp,
    String newPassword,
    String confirmPassword,
  ) async {
    try {
      final url = '${_baseUrl}reset-password/';
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'email': email,
          'otp': otp,
          'new_password': newPassword,
          'confirm_password': confirmPassword,
        }),
      );

      final responseData = json.decode(response.body);

      if (response.statusCode == 200) {
        return {
          'success': responseData['success'] ?? false,
          'message': responseData['message'] ?? 'Password reset completed',
        };
      } else {
        return {
          'success': false,
          'message': responseData['message'] ?? 'Password reset failed',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  // Send Firebase password reset email
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      print('🔄 Sending password reset email to: $email');
      await _auth.sendPasswordResetEmail(email: email.trim());
      print('✅ Password reset email sent');
    } on FirebaseAuthException catch (e) {
      print('❌ Firebase password reset error: ${e.code} - ${e.message}');
      String errorMessage = 'Failed to send reset email';
      switch (e.code) {
        case 'user-not-found':
          errorMessage = 'No account found with this email';
          break;
        case 'invalid-email':
          errorMessage = 'Invalid email format';
          break;
        case 'too-many-requests':
          errorMessage = 'Too many attempts. Try again later';
          break;
        case 'network-request-failed':
          errorMessage = 'Network error. Check your internet connection';
          break;
      }
      throw Exception(errorMessage);
    } catch (e) {
      print('❌ Unexpected error: $e');
      throw Exception('Failed to send reset email. Please try again.');
    }
  }

  // Check if user is logged in
  bool get isLoggedIn => _auth.currentUser != null || _isGuest;

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Sign out
  Future<void> signOut() async {
    try {
      print('🔄 Signing out');
      if (_isGuest) {
        logoutGuest();
      } else {
        await _auth.signOut();
        await _googleSignIn.signOut();
      }
      print('✅ Signed out successfully');
    } catch (e) {
      print('❌ Sign out error: $e');
      throw Exception('Sign out failed: $e');
    }
  }
}
