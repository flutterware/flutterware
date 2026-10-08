import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puts a picture on the system clipboard.
///
/// Flutter's own [Clipboard] carries text and nothing else, so this goes
/// through a channel of our own — `macos/Runner/ClipboardImagePlugin.swift`
/// says why that beat taking a package for it.
///
/// macOS only, and not as a stopgap: the preview being copied is composited by
/// the embedder host, which is Metal and IOSurface throughout, so anywhere else
/// there is no picture to copy in the first place. [isSupported] is what a
/// button asks so it can disable itself rather than fail under the pointer.
class ImageClipboard {
  static const _channel = MethodChannel('flutterware/clipboard');

  // The web guard first: dart2js compiles `dart:io` but `Platform` *throws*
  // when touched, and this getter runs inside `build` on any page a capture
  // button shares with the scenario web export.
  static bool get isSupported => !kIsWeb && Platform.isMacOS;

  /// Replaces the clipboard's contents with [png].
  ///
  /// Throws where there is no implementation rather than returning quietly: a
  /// caller that skipped [isSupported] should find out, and a copy that reports
  /// success and puts nothing on the clipboard is discovered at the paste.
  static Future<void> setPng(Uint8List png) async {
    if (!isSupported) {
      throw UnsupportedError('Copying an image works only on macOS.');
    }
    var written = await _channel.invokeMethod<bool>('setImage', {'png': png});
    if (written != true) {
      throw StateError('the clipboard refused the image');
    }
  }
}
