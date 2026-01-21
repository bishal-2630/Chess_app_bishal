import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../services/config.dart';
import 'django_auth_service.dart';

class GameService {
  static String get _baseUrl => AppConfig.baseUrl;

  // Helper to get headers with JWT token
  static Future<Map<String, String>> _getAuthHeaders() async {
    final authService = DjangoAuthService();
    final token = authService.accessToken;
    
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // Get online users
  static Future<Map<String, dynamic>> getOnlineUsers() async {
    try {
      final response = await http.get(
        Uri.parse('${_baseUrl}users/online/'),
        headers: await _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'users': data['online_users'],
          'count': data['count']
        };
      } else {
        return {'success': false, 'error': 'Failed to load online users'};
      }
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  // Get all users
  static Future<Map<String, dynamic>> getAllUsers() async {
    try {
      final response = await http.get(
        Uri.parse('${_baseUrl}users/all/'),
        headers: await _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'users': data['users'],
          'count': data['count']
        };
      } else {
        return {'success': false, 'error': 'Failed to load users'};
      }
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  // Update online status
  static Future<Map<String, dynamic>> updateOnlineStatus({
    required bool isOnline,
    String? roomId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${_baseUrl}users/status/'),
        headers: await _getAuthHeaders(),
        body: json.encode({
          'is_online': isOnline,
          'room_id': roomId,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'status': data['status'],
          'is_online': data['is_online'],
          'current_room': data['current_room']
        };
      } else {
        return {'success': false, 'error': 'Failed to update status'};
      }
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  // Send game invitation
  static Future<Map<String, dynamic>> sendInvitation({
    required String receiverUsername,
    required String roomId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${_baseUrl}invitations/send/'),
        headers: await _getAuthHeaders(),
        body: json.encode({
          'receiver_username': receiverUsername,
          'room_id': roomId,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': data['success'],
          'invitation': data['invitation'],
          'message': data['message']
        };
      } else {
        final errorData = json.decode(response.body);
        return {
          'success': false,
          'error': errorData['error'] ?? 'Failed to send invitation'
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  // Get my invitations
  static Future<Map<String, dynamic>> getMyInvitations() async {
    try {
      final response = await http.get(
        Uri.parse('${_baseUrl}invitations/my/'),
        headers: await _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'invitations': data['invitations'],
          'count': data['count']
        };
      } else {
        return {'success': false, 'error': 'Failed to load invitations'};
      }
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  // Respond to invitation
  static Future<Map<String, dynamic>> respondToInvitation({
    required int invitationId,
    required String action, // 'accept' or 'decline'
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${_baseUrl}invitations/$invitationId/respond/'),
        headers: await _getAuthHeaders(),
        body: json.encode({
          'action': action,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': data['success'],
          'invitation': data['invitation'],
          'message': data['message']
        };
      } else {
        final errorData = json.decode(response.body);
        return {
          'success': false,
          'error': errorData['error'] ?? 'Failed to respond to invitation'
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  // Cancel invitation
  static Future<Map<String, dynamic>> cancelInvitation({
    required int invitationId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${_baseUrl}invitations/$invitationId/cancel/'),
        headers: await _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {'success': data['success'], 'message': data['message']};
      } else {
        final errorData = json.decode(response.body);
        return {
          'success': false,
          'error': errorData['error'] ?? 'Failed to cancel invitation'
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }
}
