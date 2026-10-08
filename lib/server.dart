/// Live inspection for Dart servers.
///
/// The server side is [FlutterwareServer] — four primitives (`event`,
/// `span`/`spanSync`, `handle`) plus zone correlation and a typed
/// self-description ([ServerInfo], published with `FlutterwareServer.info`),
/// inert in release builds and on machines without flutterware. Adapters for
/// shelf, SQL drivers and `package:logging` are snippets you copy, written
/// over these primitives; `fixtures/probe_app/bin/example_server.dart` in
/// flutterware's repository has them.
///
/// The attacher side — [scanServerHandles], [attachToServer],
/// [ServerAttachClient] — is what the GUI, `fw` and MCP read a live server
/// with. It is exported here too because it is the same protocol, and a
/// pure-Dart tool wanting to observe a server needs nothing else.
library;

export 'src/server/attach_client.dart'
    show
        ServerAttachClient,
        ServerEvent,
        ServerHello,
        ServerRequestException,
        attachToServer;
export 'src/server/info.dart'
    show
        ServerConnection,
        ServerInfo,
        ServerLink,
        infoChannel,
        isSecretLikeKey,
        maskDsn,
        resolveLinkUrl;
export 'src/server/inspector.dart'
    show FlutterwareServer, ServerCommandHandler, ServerInspector;
export 'src/server/normalize_sql.dart' show normalizeSql;
export 'src/server/protocol.dart'
    show ServerHandle, deleteServerHandle, existingRunDir, scanServerHandles;
