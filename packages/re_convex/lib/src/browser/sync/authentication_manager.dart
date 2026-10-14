// Ported from convex/src/browser/sync/authentication_manager.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/local_state.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/vendor/jwt_decode/index.dart';

// Timers far in the future are pointless for a short-lived token.
const Duration _maximumRefreshDelay = Duration(days: 20);

const int _maxTokenConfirmationAttempts = 2;

/// Returns a JWT for the auth provider, or `null` (rather than throwing)
/// when there is none; [forceRefreshToken] asks to bypass any cache.
typedef AuthTokenFetcher =
    Future<String?> Function({required bool forceRefreshToken});

final class _AuthConfig {
  _AuthConfig({
    required this.fetchToken,
    required this.onAuthChange,
    this.onRefreshChange,
  });

  final AuthTokenFetcher fetchToken;
  final void Function(bool isAuthenticated) onAuthChange;
  final void Function(bool isRefreshing)? onRefreshChange;
}

// Sends a maybe-cached token, then a fresh one refetched before expiry.
sealed class _AuthState {
  const _AuthState();

  String get state;

  _AuthConfig? get config => null;
}

final class _NoAuth extends _AuthState {
  const _NoAuth();

  @override
  String get state => 'noAuth';
}

final class _WaitingForServerConfirmationOfCachedToken extends _AuthState {
  const _WaitingForServerConfirmationOfCachedToken(this.config);

  @override
  final _AuthConfig config;

  @override
  String get state => 'waitingForServerConfirmationOfCachedToken';
}

final class _InitialRefetch extends _AuthState {
  const _InitialRefetch(this.config);

  @override
  final _AuthConfig config;

  @override
  String get state => 'initialRefetch';
}

final class _WaitingForServerConfirmationOfFreshToken extends _AuthState {
  const _WaitingForServerConfirmationOfFreshToken(
    this.config, {
    required this.hadAuth,
    required this.token,
  });

  @override
  final _AuthConfig config;
  final bool hadAuth;
  final String token;

  @override
  String get state => 'waitingForServerConfirmationOfFreshToken';
}

final class _WaitingForScheduledRefetch extends _AuthState {
  const _WaitingForScheduledRefetch(this.config, this.refetchTokenTimer);

  @override
  final _AuthConfig config;
  final Timer refetchTokenTimer;

  @override
  String get state => 'waitingForScheduledRefetch';
}

// Special/weird state when we got a valid token but could not fetch a new one.
final class _NotRefetching extends _AuthState {
  const _NotRefetching(this.config);

  @override
  final _AuthConfig config;

  @override
  String get state => 'notRefetching';
}

/// Handles the state transitions for auth; the server is the source of
/// truth.
class AuthenticationManager {
  /// Creates the manager over the client's shared sync state.
  AuthenticationManager(
    this._syncState, {
    required IdentityVersion Function(String token) authenticate,
    required Future<void> Function() stopSocket,
    required void Function() tryRestartSocket,
    required void Function() pauseSocket,
    required void Function() resumeSocket,
    required void Function() clearAuth,
    required ConvexLogger logger,
    required Duration refreshTokenLeeway,
    required bool initialAuthTokenReuse,
  }) : _authenticate = authenticate,
       _stopSocket = stopSocket,
       _tryRestartSocket = tryRestartSocket,
       _pauseSocket = pauseSocket,
       _resumeSocket = resumeSocket,
       _clearAuth = clearAuth,
       _logger = logger,
       _refreshTokenLeeway = refreshTokenLeeway,
       _initialAuthTokenReuse = initialAuthTokenReuse;

  _AuthState _authState = const _NoAuth();
  // Detects `setConfig` calls racing a token fetch.
  int _configVersion = 0;
  final LocalSyncState _syncState;
  final IdentityVersion Function(String token) _authenticate;
  final Future<void> Function() _stopSocket;
  final void Function() _tryRestartSocket;
  final void Function() _pauseSocket;
  final void Function() _resumeSocket;
  final void Function() _clearAuth;
  final ConvexLogger _logger;
  final Duration _refreshTokenLeeway;
  final bool _initialAuthTokenReuse;
  // Track last value to avoid redundant calls
  bool _lastRefreshChange = false;
  // Attempts to confirm the latest token, up to the maximum.
  int _tokenConfirmationAttempts = 0;

  void _notifyRefreshChange(bool isRefreshing) {
    final onRefreshChange = _authState.config?.onRefreshChange;
    if (_authState is! _InitialRefetch &&
        onRefreshChange != null &&
        _lastRefreshChange != isRefreshing) {
      _lastRefreshChange = isRefreshing;
      onRefreshChange(isRefreshing);
    }
  }

  /// Starts authenticating with tokens from [fetchToken].
  Future<void> setConfig(
    AuthTokenFetcher fetchToken,
    void Function(bool isAuthenticated) onChange, [
    void Function(bool isRefreshing)? onRefreshChange,
  ]) async {
    _resetAuthState();
    _logVerbose('pausing WS for auth token fetch');
    _pauseSocket();
    final token = await _fetchTokenAndGuardAgainstRace(
      fetchToken,
      forceRefreshToken: false,
    );
    if (token.isFromOutdatedConfig) {
      return;
    }
    final config = _AuthConfig(
      fetchToken: fetchToken,
      onAuthChange: onChange,
      onRefreshChange: onRefreshChange,
    );
    final value = token.value;
    if (value != null && value.isNotEmpty) {
      _setAuthState(_WaitingForServerConfirmationOfCachedToken(config));
      _authenticate(value);
    } else {
      _setAuthState(_InitialRefetch(config));
      // Try again with `forceRefreshToken: true`
      await _refetchToken();
    }
    _logVerbose('resuming WS after auth token fetch');
    _resumeSocket();
  }

  /// Handles a transition, which confirms a token when it advances the
  /// identity version.
  void onTransition(Transition serverMessage) {
    if (!_syncState.isCurrentOrNewerAuthVersion(
      serverMessage.endVersion.identity,
    )) {
      // A stale transition: the client moved on to a newer auth version.
      return;
    }
    if (serverMessage.endVersion.identity <=
        serverMessage.startVersion.identity) {
      // This transition did not change auth - it is not a response to Authenticate.
      return;
    }

    _logVerbose('auth state is ${_authState.state} when handling transition');

    // The auth version advanced: the token was valid and both sides agree.
    _syncState.markAuthCompletion();

    final authState = _authState;
    if (authState is _WaitingForServerConfirmationOfCachedToken) {
      _logVerbose('server confirmed auth token is valid');
      final cachedToken = _syncState.getAuth()?.value;
      if (_initialAuthTokenReuse && cachedToken != null) {
        _scheduleTokenRefetch(cachedToken, serverMessage.clientClockSkew);
      } else {
        unawaited(_refetchToken());
      }
      authState.config.onAuthChange(true);
      return;
    }
    if (authState is _WaitingForServerConfirmationOfFreshToken) {
      _logVerbose('server confirmed new auth token is valid');
      _notifyRefreshChange(false);
      _scheduleTokenRefetch(authState.token);
      _tokenConfirmationAttempts = 0;
      if (!authState.hadAuth) {
        authState.config.onAuthChange(true);
      }
    }
  }

  /// Handles the server rejecting the token.
  void onAuthError(AuthError serverMessage) {
    // Ignore errors unrelated to the token update we're waiting on.
    if (!serverMessage.authUpdateAttempted &&
        (_authState is _WaitingForServerConfirmationOfFreshToken ||
            _authState is _WaitingForServerConfirmationOfCachedToken)) {
      _logVerbose('ignoring non-auth token expired error');
      return;
    }
    // Ignore errors for an older identity; they carry the version before it.
    if (!_syncState.isCurrentOrNewerAuthVersion(
      serverMessage.baseVersion + 1,
    )) {
      _logVerbose('ignoring auth error for previous auth attempt');
      return;
    }
    unawaited(_tryToReauthenticate(serverMessage));
  }

  // Like `_refetchToken`, pausing the socket so mutations don't use bad auth.
  Future<void> _tryToReauthenticate(AuthError serverMessage) async {
    _logVerbose('attempting to reauthenticate: ${serverMessage.error}');
    final current = _authState;
    if (
    // No way to fetch another token, kaboom
    current is _NoAuth ||
        // A fresh token failed: give up after a few retries to avoid looping.
        (current is _WaitingForServerConfirmationOfFreshToken &&
            _tokenConfirmationAttempts >= _maxTokenConfirmationAttempts)) {
      _logger.error(
        'Failed to authenticate: "${serverMessage.error}", check your server '
        'auth config',
      );
      if (_syncState.hasAuth()) {
        _syncState.clearAuth();
      }
      final config = _authState.config;
      if (config != null) {
        _setAndReportAuthFailed(config.onAuthChange);
      }
      return;
    }
    if (current is _WaitingForServerConfirmationOfFreshToken) {
      _tokenConfirmationAttempts++;
      _logVerbose(
        'retrying reauthentication, '
        '${_maxTokenConfirmationAttempts - _tokenConfirmationAttempts} '
        'attempts remaining',
      );
    }

    _notifyRefreshChange(true);
    await _stopSocket();
    final config = _authState.config;
    if (config == null) {
      // setConfig() or stop() ran during the await.
      return;
    }
    final token = await _fetchTokenAndGuardAgainstRace(
      config.fetchToken,
      forceRefreshToken: true,
    );
    if (token.isFromOutdatedConfig) {
      return;
    }

    final value = token.value;
    if (value != null && value.isNotEmpty && _syncState.isNewAuth(value)) {
      _authenticate(value);
      _setAuthState(
        _WaitingForServerConfirmationOfFreshToken(
          _authState.config!,
          token: value,
          hadAuth:
              _authState is _NotRefetching ||
              _authState is _WaitingForScheduledRefetch,
        ),
      );
    } else {
      _logVerbose('reauthentication failed, could not fetch a new token');
      if (_syncState.hasAuth()) {
        _syncState.clearAuth();
      }
      _setAndReportAuthFailed(_authState.config!.onAuthChange);
    }
    _tryRestartSocket();
  }

  // Refetches the token and schedules the next refetch before it expires.
  Future<void> _refetchToken() async {
    final config = _authState.config;
    if (config == null) {
      return;
    }
    _logVerbose('refetching auth token');
    final token = await _fetchTokenAndGuardAgainstRace(
      config.fetchToken,
      forceRefreshToken: true,
    );
    if (token.isFromOutdatedConfig) {
      return;
    }

    final value = token.value;
    if (value != null && value.isNotEmpty) {
      if (_syncState.isNewAuth(value)) {
        _setAuthState(
          _WaitingForServerConfirmationOfFreshToken(
            _authState.config!,
            hadAuth: _syncState.hasAuth(),
            token: value,
          ),
        );
        _authenticate(value);
      } else {
        _setAuthState(_NotRefetching(_authState.config!));
      }
    } else {
      _logVerbose('refetching token failed');
      if (_syncState.hasAuth()) {
        _clearAuth();
      }
      _setAndReportAuthFailed(_authState.config!.onAuthChange);
    }
    // Restart in case a scheduled refetch ran during a reauthentication.
    _logVerbose('restarting WS after auth token fetch (if currently stopped)');
    _tryRestartSocket();
  }

  void _scheduleTokenRefetch(String token, [num? clientClockSkewMs]) {
    final config = _authState.config;
    if (config == null) {
      return;
    }
    final decodedToken = _decodeToken(token);
    if (decodedToken == null) {
      // No longer really possible: the server requires JWT tokens.
      _logger.error('Auth token is not a valid JWT, cannot refetch the token');
      return;
    }
    // iat/exp: UTC seconds at which the JWT was issued/expires.
    final iat = decodedToken['iat'];
    final exp = decodedToken['exp'];
    if (iat is! num || exp is! num || iat == 0 || exp == 0) {
      _logger.error(
        'Auth token does not have required fields, cannot refetch the token',
      );
      return;
    }
    final fullLifetimeSeconds = exp - iat;
    if (fullLifetimeSeconds <= 2) {
      _logger.error(
        'Auth token does not live long enough, cannot refetch the token',
      );
      return;
    }
    num tokenValiditySeconds;
    if (clientClockSkewMs != null) {
      // Cached token: estimate server time as now minus the clock skew.
      final estimatedServerNowSeconds =
          (clock.now().millisecondsSinceEpoch - clientClockSkewMs) / 1000;
      tokenValiditySeconds = exp - estimatedServerNowSeconds;
      if (tokenValiditySeconds <= 0) {
        tokenValiditySeconds = 0;
      }
    } else {
      // A fresh token's full lifetime starts now.
      tokenValiditySeconds = fullLifetimeSeconds;
    }
    // Refresh `refreshTokenLeeway` before expiry, or now if expiring soon.
    var delayMs = min(
      _maximumRefreshDelay.inMilliseconds.toDouble(),
      (tokenValiditySeconds - _refreshTokenLeeway.inMicroseconds / 1e6) * 1000,
    );
    if (delayMs <= 0) {
      // Refetch now; the leeway may exceed the token's lifetime.
      _logger.warn(
        'Refetching auth token immediately, configured leeway '
        '${_refreshTokenLeeway.inSeconds}s is larger than the token\'s '
        'lifetime ${tokenValiditySeconds}s',
      );
      delayMs = 0;
    }
    final refetchTokenTimer = Timer(
      Duration(microseconds: (delayMs * 1000).round()),
      () {
        _logVerbose('running scheduled token refetch');
        unawaited(_refetchToken());
      },
    );
    _setAuthState(_WaitingForScheduledRefetch(config, refetchTokenTimer));
    _logVerbose(
      'scheduled preemptive auth token refetching in ${delayMs.round()}ms',
    );
  }

  // Guards against `setConfig` calls made while a token is fetched.
  Future<({bool isFromOutdatedConfig, String? value})>
  _fetchTokenAndGuardAgainstRace(
    AuthTokenFetcher fetchToken, {
    required bool forceRefreshToken,
  }) async {
    final originalConfigVersion = ++_configVersion;
    _logVerbose('fetching token with config version $originalConfigVersion');
    final token = await fetchToken(forceRefreshToken: forceRefreshToken);
    if (_configVersion != originalConfigVersion) {
      // This is a stale config
      _logVerbose(
        'stale config version, expected $originalConfigVersion, got '
        '$_configVersion',
      );
      return (isFromOutdatedConfig: true, value: null);
    }
    return (isFromOutdatedConfig: false, value: token);
  }

  /// Forgets the auth config, abandoning any token fetch in progress.
  void stop() {
    _resetAuthState();
    // Bump this in case we are mid-token-fetch when we get stopped
    _configVersion++;
    _logVerbose('config version bumped to $_configVersion');
  }

  void _setAndReportAuthFailed(void Function(bool authenticated) onAuthChange) {
    onAuthChange(false);
    _resetAuthState();
  }

  // The only way to `noAuth`; reports refreshing `false` after any `true`.
  void _resetAuthState() {
    _notifyRefreshChange(false);
    _setAuthState(const _NoAuth());
  }

  void _setAuthState(_AuthState newAuth) {
    final authStateForLog = newAuth is _WaitingForServerConfirmationOfFreshToken
        ? {
            'hadAuth': newAuth.hadAuth,
            'state': newAuth.state,
            'token':
                '...${newAuth.token.substring(max(0, newAuth.token.length - 7))}',
          }
        : {'state': newAuth.state};
    _logVerbose('setting auth state to ${jsonEncode(authStateForLog)}');
    switch (newAuth) {
      case _WaitingForScheduledRefetch():
      case _NotRefetching():
      case _NoAuth():
        _tokenConfirmationAttempts = 0;
      case _WaitingForServerConfirmationOfFreshToken():
      case _WaitingForServerConfirmationOfCachedToken():
      case _InitialRefetch():
        break;
    }
    final previous = _authState;
    if (previous is _WaitingForScheduledRefetch) {
      previous.refetchTokenTimer.cancel();
    }
    _authState = newAuth;
  }

  Map<String, Object?>? _decodeToken(String token) {
    try {
      return jwtDecode(token);
    } on InvalidTokenError catch (e) {
      _logVerbose('Error decoding token: ${e.message}');
      return null;
    }
  }

  void _logVerbose(String message) {
    _logger.logVerbose('$message [v$_configVersion]');
  }
}
