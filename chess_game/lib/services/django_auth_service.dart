import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../services/config.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_sign_in/google_sign_in.dart';

class DjangoAuthService {
  // Singleton pattern
  static final DjangoAuthService _instance = DjangoAuthService._internal();
  factory DjangoAuthService() => _instance;
  DjangoAuthService._internal();

  final CookieManager _cookieManager = CookieManager.instance();
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: '764791811000-uhnrqvpfe4euoaff3kmiekrc7p7c4obk.apps.googleusercontent.com',
  );
  
  // User data storage
  Map<String, dynamic>? _currentUser;
  bool _isGuest = false;
  String? _guestName;
  String? _accessToken;
  String? _refreshToken;

  // Getters
  Map<String, dynamic>? get currentUser => _currentUser;
  bool get isLoggedIn => _currentUser != null || _isGuest;
  bool get isGuest => _isGuest;
  String? get guestName => _guestName;

  String get _baseUrl {
    return AppConfig.baseUrl;
  }

  // Guest login
  Future<void> loginAsGuest(String name) async {
    _isGuest = true;
    _guestName = name;
    _currentUser = null;
    print('👤 Logged in as Guest: $name');
  }

  // Guest logout
  void logoutGuest() {
    _isGuest = false;
    _guestName = null;
    print('👤 Guest logged out');
  }

  // Email/Password Login
  Future<Map<String, dynamic>> signInWithEmailPassword(String email, String password) async {
    logoutGuest(); // Clear guest state
    print('🔐 Attempting Django sign in with email: $email');

    try {
      // Use standard Django login endpoint
      final url = '${_baseUrl}login/';
      print('🌐 Calling URL: $url');
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: json.encode({
          'email': email.trim(),
          'password': password,
        }),
      );

      print('📡 Registration response status: ${response.statusCode}');
      print('📦 Registration response body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        
        if (responseData['success'] == true) {
          _currentUser = responseData['user'];
          print('✅ Django login successful: ${responseData['user']['email']}');
          
          // Store tokens if available
          if (responseData['tokens'] != null) {
            _accessToken = responseData['tokens']['access'];
            _refreshToken = responseData['tokens']['refresh'];
          }
          
          return {
            'success': true,
            'user': responseData['user'],
            'tokens': responseData['tokens'] ?? {},
          };
        } else {
          final errorMessage = responseData['message'] ?? 'Login failed';
          print('❌ Django login error: $errorMessage');
          return {
            'success': false,
            'error': errorMessage,
          };
        }
      } else {
        // Handle error responses
        String errorMessage = 'Login failed';
        try {
          final errorData = json.decode(response.body);
          
          // Check for message field first
          if (errorData['message'] != null) {
            errorMessage = errorData['message'];
          }
          // Fallback to other error fields
          else if (errorData['detail'] != null) {
            errorMessage = errorData['detail'];
          } else if (errorData['email'] != null) {
            errorMessage = errorData['email'][0];
          } else if (errorData['password'] != null) {
            errorMessage = errorData['password'][0];
          } else if (errorData['non_field_errors'] != null) {
            errorMessage = errorData['non_field_errors'][0];
          }
        } catch (e) {
          errorMessage = 'Network error during login: ${response.statusCode}';
        }
        
        print('❌ Network error during login: $errorMessage');
        return {
          'success': false,
          'error': errorMessage,
        };
      }
    } catch (e) {
      print('❌ Exception during login: $e');
      return {
        'success': false,
        'error': 'Network error: $e',
      };
    }
  }

  // Email/Password Registration
  Future<Map<String, dynamic>> registerWithEmailPassword(
      String email, String password, String username) async {
    print('📝 Starting Django registration for: $email');

    try {
      final url = '${_baseUrl}register/';
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: json.encode({
          'email': email.trim(),
          'password': password,
          'username': username.trim(),
        }),
      );

      print('📡 Registration response status: ${response.statusCode}');
      print('📦 Registration response body: ${response.body}');

      if (response.statusCode == 201) {
        final responseData = json.decode(response.body);
        
        // Store user data
        _currentUser = responseData['user'];
        
        // Handle cookies for web view
        String? rawCookie = response.headers['set-cookie'];
        if (rawCookie != null) {
          print('🍪 Found cookies to inject');
          await _injectCookies(rawCookie);
        }
        
        print('✅ Django registration successful: ${_currentUser?['email']}');
        return {
          'success': true,
          'user': _currentUser,
          'tokens': responseData
        };
      } else {
        final errorData = json.decode(response.body);
        String errorMessage = 'Registration failed';
        
        if (errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        } else if (errorData['email'] != null) {
          errorMessage = errorData['email'][0];
        } else if (errorData['password'] != null) {
          errorMessage = errorData['password'][0];
        } else if (errorData['username'] != null) {
          errorMessage = errorData['username'][0];
        } else if (errorData['non_field_errors'] != null) {
          errorMessage = errorData['non_field_errors'][0];
        }
        
        print('❌ Django registration error: $errorMessage');
        return {
          'success': false,
          'error': errorMessage
        };
      }
    } catch (e) {
      print('❌ Network error during registration: $e');
      return {
        'success': false,
        'error': 'Network error. Please check your connection.'
      };
    }
  }

  // Google Sign-In
  Future<Map<String, dynamic>> signInWithGoogle() async {
    logoutGuest(); // Clear guest state
    print('🔄 Starting Google sign in');

    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      if (googleUser == null) {
        print('User cancelled Google sign in');
        return {'success': false, 'error': 'Sign in cancelled'};
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      // Send Google token to Django backend
      final url = '${_baseUrl}google-login/';
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: json.encode({
          'access_token': googleAuth.accessToken,
          'id_token': googleAuth.idToken,
        }),
      );

      print('📡 Google login response status: ${response.statusCode}');
      print('📦 Google login response body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        
        // Store user data
        _currentUser = responseData['user'];
        
        // Handle cookies for web view
        String? rawCookie = response.headers['set-cookie'];
        if (rawCookie != null) {
          print('🍪 Found cookies to inject');
          await _injectCookies(rawCookie);
        }
        
        print('✅ Google sign in successful: ${_currentUser?['email']}');
        return {
          'success': true,
          'user': _currentUser,
          'tokens': responseData
        };
      } else {
        final errorData = json.decode(response.body);
        String errorMessage = 'Google sign in failed';
        
        if (errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        } else if (errorData['error'] != null) {
          errorMessage = errorData['error'];
        }
        
        print('❌ Google sign in error: $errorMessage');
        return {
          'success': false,
          'error': errorMessage
        };
      }
    } catch (e) {
      print('❌ Google sign in error: $e');
      return {
        'success': false,
        'error': 'Google sign in failed. Please make sure Google Play Services are updated.'
      };
    }
  }

  // Send Password Reset OTP
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

  // Verify OTP
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

  // Reset Password with OTP
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

  // Sign out
  Future<void> signOut() async {
    try {
      print('🔄 Signing out from Django');
      
      // Capture refresh token before clearing
      final String? tokenToBlacklist = _refreshToken;

      // 1. CLEAR LOCAL STATE IMMEDIATELY (Instant UI response)
      _currentUser = null;
      _isGuest = false;
      _guestName = null;
      _accessToken = null;
      _refreshToken = null;
      
      // Clear cookies
      try {
        await _clearCookies();
      } catch (e) {
        print('⚠️ Cookie clearing failed: $e');
      }
      
      // Sign out from Google
      try {
        await _googleSignIn.signOut();
      } catch (e) {
        print('⚠️ Google sign out failed: $e');
      }

      // 2. INFORMLY CALL BACKEND (Don't block UI if this is slow)
      if (tokenToBlacklist != null) {
        final url = '${_baseUrl}logout/';
        print('📡 Sending blacklist request to: $url');
        
        try {
          await http.post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: json.encode({'refresh': tokenToBlacklist}),
          ).timeout(const Duration(seconds: 3));
        } catch (e) {
          print('ℹ️ Backend logout call result: User logged out locally ($e)');
        }
      }
      
      print('✅ Signed out successfully');
    } catch (e) {
      print('❌ Sign out error: $e');
      // Still clear local state even if logout fails
      _currentUser = null;
      _isGuest = false;
      _guestName = null;
    }
  }

  // Inject cookies for web view
  Future<void> _injectCookies(String rawCookie) async {
    try {
      Uri uri = Uri.parse(_baseUrl);
      String domain = uri.host;
      
      List<String> cookies = rawCookie.split(RegExp(r',(?=\s*[a-zA-Z0-9_-]+=)')); 
      
      for (String cookie in cookies) {
        int equalsIndex = cookie.indexOf('=');
        if (equalsIndex == -1) continue;
        
        String key = cookie.substring(0, equalsIndex).trim();
        String valueAndAttributes = cookie.substring(equalsIndex + 1).trim();
        
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

  // Clear cookies
  Future<void> _clearCookies() async {
    try {
      await _cookieManager.deleteCookies(url: WebUri(_baseUrl));
      print('🍪 Cookies cleared');
    } catch (e) {
      print('❌ Error clearing cookies: $e');
    }
  }

  // Get current user display name
  String get displayName {
    if (_isGuest && _guestName != null) {
      return _guestName!;
    }
    if (_currentUser != null) {
      return _currentUser!['username'] ?? _currentUser!['email'] ?? 'User';
    }
    return 'Guest';
  }

  // Get current user email
  String? get email {
    if (_currentUser != null) {
      return _currentUser!['email'];
    }
    return null;
  }

  // Check if user has specific role (for future use)
  bool hasRole(String role) {
    if (_currentUser != null && _currentUser!['roles'] != null) {
      List<String> roles = List<String>.from(_currentUser!['roles']);
      return roles.contains(role);
    }
    return false;
  }
}
