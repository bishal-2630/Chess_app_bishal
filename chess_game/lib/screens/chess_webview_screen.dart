import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/cookie_injection_service.dart';
import '../services/config.dart';

class ChessWebViewScreen extends StatefulWidget {
  final String? gameId;
  final String? customUrl;

  const ChessWebViewScreen({
    super.key,
    this.gameId,
    this.customUrl,
  });

  @override
  State<ChessWebViewScreen> createState() => _ChessWebViewScreenState();
}

class _ChessWebViewScreenState extends State<ChessWebViewScreen> {
  final CookieInjectionService _cookieService = CookieInjectionService();
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  bool _cookiesInjected = false;
  String? _errorMessage;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _injectCookiesBeforeLoad();
  }

  Future<void> _injectCookiesBeforeLoad() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Inject cookies before loading the page
    final success = await _cookieService.injectAuthCookies(
      customUrl: widget.customUrl,
    );

    if (success) {
      setState(() {
        _cookiesInjected = true;
      });
    } else {
      setState(() {
        _errorMessage = 'Failed to authenticate. Please try logging in again.';
        _isLoading = false;
      });
    }
  }

  String get _webUrl {
    if (widget.customUrl != null) {
      return widget.customUrl!;
    }

    // Build URL based on game ID
    final baseUrl = AppConfig.baseUrl.replaceAll('/api/auth/', '');
    if (widget.gameId != null) {
      return '$baseUrl/game/${widget.gameId}';
    }
    return '$baseUrl/play';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chess Game'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _webViewController?.reload();
            },
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: _showDebugInfo,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _injectCookiesBeforeLoad,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (!_cookiesInjected) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Authenticating...'),
          ],
        ),
      );
    }

    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri(_webUrl),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            databaseEnabled: true,
            thirdPartyCookiesEnabled: true,
            supportZoom: true,
            useOnLoadResource: true,
            useShouldOverrideUrlLoading: true,
            mediaPlaybackRequiresUserGesture: false,
            allowFileAccessFromFileURLs: true,
            allowUniversalAccessFromFileURLs: true,
          ),
          onWebViewCreated: (controller) {
            _webViewController = controller;
          },
          onLoadStart: (controller, url) {
            setState(() {
              _isLoading = true;
            });
          },
          onLoadStop: (controller, url) async {
            setState(() {
              _isLoading = false;
            });
          },
          onProgressChanged: (controller, progress) {
            setState(() {
              _progress = progress / 100;
            });
          },
          onLoadError: (controller, url, code, message) {
            setState(() {
              _errorMessage = 'Failed to load page: $message';
              _isLoading = false;
            });
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            // Allow all navigation
            return NavigationActionPolicy.ALLOW;
          },
        ),
        if (_isLoading)
          LinearProgressIndicator(
            value: _progress,
            backgroundColor: Colors.grey[200],
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
          ),
      ],
    );
  }

  Future<void> _showDebugInfo() async {
    final cookies = await _cookieService.getCookies();
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Debug Info'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('URL: $_webUrl'),
              const SizedBox(height: 8),
              Text('Cookies Injected: $_cookiesInjected'),
              const SizedBox(height: 8),
              Text('Cookies Count: ${cookies.length}'),
              const SizedBox(height: 8),
              const Text('Cookies:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...cookies.map((cookie) => Text('${cookie.name}: ${cookie.value}')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
