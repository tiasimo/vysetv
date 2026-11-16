// Where this build's own servers are.
//
// Copy this file to `server_config.dart`, next to it (git ignores that name), and fill it in.
// The build needs the copy to exist, even if you leave both values as they are here.
//
// VyseTV's official builds talk to the author's server. Its address is not part of this
// repository: a build of your own needs a server of your own.

/// The account server: PocketBase with the Party hooks, as `https://accounts.example.com`
/// (no slash at the end). Left empty, the app has no accounts and no Party; everything else
/// works.
const accountServer = '';

/// Where your signed `latest.json` is published, asked in order (see scripts/make_update.py).
/// Left empty, the app never looks for an update.
const updateListAddresses = <String>[];
