import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/game_service.dart';
import '../../services/django_auth_service.dart';
import 'dart:async';

class UserListScreen extends StatefulWidget {
  const UserListScreen({super.key});

  @override
  State<UserListScreen> createState() => _UserListScreenState();
}

class _UserListScreenState extends State<UserListScreen> {
  final DjangoAuthService _authService = DjangoAuthService();
  List<dynamic> _onlineUsers = [];
  List<dynamic> _allUsers = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final Map<String, DateTime> _sentChallenges = {};
  Timer? _challengeTimer;

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _challengeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        setState(() {
          // Trigger rebuild to refresh "Sent" buttons
        });
      }
    });
  }

  Future<void> _loadUsers() async {
    setState(() {
      _isLoading = true;
    });

    try {
        final result = await GameService.getAllUsers();
        if (result['success']) {
          setState(() {
            _allUsers = result['users'];
          });
        }
    } catch (e) {
      print('Error loading users: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _challengeTimer?.cancel();
    super.dispose();
  }

  List<dynamic> get _filteredUsers {
    final users = _allUsers;
    if (_searchQuery.isEmpty) {
      return users;
    }
    
    return users.where((user) {
      final username = user['username']?.toString().toLowerCase() ?? '';
      final query = _searchQuery.toLowerCase();
      return username.contains(query);
    }).toList();
  }

  Future<void> _sendInvitation(dynamic user) async {
    final roomId = 'room_${DateTime.now().millisecondsSinceEpoch}';
    
    setState(() {
      _sentChallenges[user['username']] = DateTime.now();
    });

    final result = await GameService.sendInvitation(
      receiverUsername: user['username'],
      roomId: roomId,
    );

    if (mounted) {
      if (result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invitation sent to ${user['username']}'),
            backgroundColor: Colors.green,
          ),
        );
        // Navigate to the game room
        context.go('/chess?roomId=$roomId&color=w');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] ?? 'Failed to send invitation'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Players'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/chess'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadUsers,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search players...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
          
          // User list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredUsers.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.people,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No players found',
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.grey[600],
                              ),
                            ),
                            if (_searchQuery.isNotEmpty)
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _searchQuery = '';
                                  });
                                },
                                child: const Text('Clear search'),
                              ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadUsers,
                        child: ListView.builder(
                          itemCount: _filteredUsers.length,
                          itemBuilder: (context, index) {
                            final user = _filteredUsers[index];
                            final lastSent = _sentChallenges[user['username']];
                            bool isRecent = false;
                            if (lastSent != null) {
                              isRecent = DateTime.now().difference(lastSent).inMinutes < 1;
                            }
                            
                            return UserCard(
                              user: user,
                              onInvite: isRecent ? null : () => _sendInvitation(user),
                              isOnline: user['is_online'] ?? false,
                              isRecent: isRecent,
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class UserCard extends StatelessWidget {
  final dynamic user;
  final VoidCallback? onInvite;
  final bool isOnline;
  final bool isRecent;

  const UserCard({
    super.key,
    required this.user,
    required this.onInvite,
    required this.isOnline,
    required this.isRecent,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            // Profile picture
            CircleAvatar(
              radius: 24,
              backgroundColor: Colors.blue[100],
              backgroundImage: user['profile_picture'] != null
                  ? NetworkImage(user['profile_picture'])
                  : null,
              child: user['profile_picture'] == null
                  ? Icon(
                      Icons.person,
                      size: 24,
                      color: isOnline ? Colors.green : Colors.grey,
                    )
                  : null,
            ),
            
            const SizedBox(width: 16),
            
            // User info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        user['username'] ?? 'Unknown',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: isOnline ? Colors.green : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user['email'] ?? '',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            
            // Invite button
            // Actions
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Call Button
                IconButton(
                  icon: const Icon(Icons.call),
                  color: Colors.green,
                  onPressed: () {
                    // Generate a room ID for the call
                    final roomId = 'call_${DateTime.now().millisecondsSinceEpoch}';
                    MqttService().playSound('sounds/call_ringtone.mp3');
                    // Navigate to call screen as Caller
                    context.push(
                      '/call?roomId=$roomId&otherUserName=${user['username']}&isCaller=true'
                    );
                  },
                  tooltip: 'Call',
                ),
                // Challenge Button 
                IconButton(
                  icon: Icon(isRecent ? Icons.hourglass_empty : Icons.play_arrow),
                  color: isRecent ? Colors.grey : Colors.blue,
                  onPressed: onInvite,
                  tooltip: isRecent ? 'Sent (Expires in 1m)' : 'Challenge',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
