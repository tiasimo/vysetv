/// Client ids for the tracking services. While one is empty, that service shows "Not set up
/// yet" in Settings and can't be connected.
///
/// Client ids are public by design. Never put a client secret here: none of these sign-ins
/// needs one, and anything in the app can be read out of it.
class TrackerKeys {
  /// The fixed local port the browser comes back to after signing in on a computer. Register
  /// the redirect addresses below exactly as written (127.0.0.1, not localhost).
  static const loopbackPort = 47853;

  /// AniList: anilist.co/settings/developer → Create New Application.
  /// Redirect URL: http://127.0.0.1:47853/anilist
  static const anilistClientId = '56650';

  /// Optional second AniList application whose Redirect URL is
  /// https://anilist.co/api/v2/oauth/pin. It lets people paste a token instead of coming back
  /// through the browser (phones for now, or a computer whose browser can't reach the app).
  static const anilistPinClientId = '';

  /// Simkl: simkl.com/settings/developer → new app under AUTH V2, client type
  /// "Mobile, desktop & browser apps" (no secret). It asks for a redirect URI even though
  /// Lorewatch signs in with a code instead: http://127.0.0.1/auth/simkl
  static const simklClientId = ''; // Lorewatch: Simkl switched off

  /// Trakt: the verified (Production) app, so anyone can connect. No secret: Lorewatch signs in
  /// with a code. The redirect is never visited, but it must match the app's setting because
  /// Trakt checks it when a sign-in is renewed.
  static const traktClientId = ''; // Lorewatch: Trakt switched off
  static const traktRedirectUri = 'urn:ietf:wg:oauth:2.0:oob';

  /// Sent with every Simkl request (Simkl requires the app's name and version).
  static const appName = 'lorewatch';
  static const appVersion = '1.0.0'; // keep in step with pubspec.yaml
}
