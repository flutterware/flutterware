import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What the sync engine trusts: tokens this server signs with a secret they
/// share. HS256, the development setup; a real deployment uses a key pair.
class SyncAuth {
  const SyncAuth({
    required this.endpoint,
    required this.secret,
    this.audience = 'world-lab',
    this.keyId = 'world-lab',
  });

  /// Where apps sync from: the sync engine's own URL.
  final Uri endpoint;
  final String secret;
  final String audience;
  final String keyId;

  /// The secret as the engine's key set carries it (`k`, base64url).
  String get jwk => _b64(utf8.encode(secret));

  /// A token for [userId], who is [role]: the sync rules read both.
  String token(String userId, String role) {
    var now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var header = _b64(
      utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT', 'kid': keyId})),
    );
    var claims = _b64(
      utf8.encode(
        jsonEncode({
          'sub': userId,
          'aud': audience,
          'iat': now,
          'exp': now + 3600,
          'role': role,
        }),
      ),
    );
    var signature = Hmac(
      sha256,
      utf8.encode(secret),
    ).convert(utf8.encode('$header.$claims')).bytes;
    return '$header.$claims.${_b64(signature)}';
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
