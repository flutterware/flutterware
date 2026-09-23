import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import 'design/design.dart';

export 'design/design.dart';

ThemeData? __theme;
ThemeData get appTheme {
  if (kDebugMode) {
    return buildAppTheme(defaultTokens);
  } else {
    return __theme ??= buildAppTheme(defaultTokens);
  }
}

ThemeData? __darkTheme;

/// The dark build of the same theme. [FwPalette.brightness] is read from the
/// palette's background, so [buildAppTheme] produces dark Material chrome from
/// this without a second code path.
ThemeData get appDarkTheme {
  if (kDebugMode) {
    return buildAppTheme(darkTokens);
  } else {
    return __darkTheme ??= buildAppTheme(darkTokens);
  }
}

/// Builds the app [ThemeData] for a given token set and attaches [tokens] as a
/// [ThemeExtension] so widgets can read it via `context.colors` / `context.type`.
/// Material-rendered chrome (inputs, cards, dialogs) is driven by the tokens too
/// — surfaces from the palette, corners from the radii — so it tracks the theme.
ThemeData buildAppTheme(FwTokens tokens) {
  var palette = tokens.palette;
  var type = tokens.typography;
  var radii = tokens.radii;

  var base = ThemeData(useMaterial3: true, colorScheme: palette.colorScheme);

  var textTheme = type.spec
      .applyFontTheme(base.textTheme)
      .apply(displayColor: palette.ink, bodyColor: palette.mut);

  var inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(radii.radius),
    borderSide: BorderSide(color: palette.line),
  );

  // Material's own tap targets, taught the house state.
  //
  // The app's primitive is [Tappable], but a few dozen `InkWell`s, `IconButton`s
  // and Material buttons remain, and they were the one family on the screen
  // that answered a pointer with a ripple. Teaching the theme is what makes
  // them read as the same control as everything beside them without editing
  // every call site — and the tokens are the same ones [Tappable] paints, so
  // the two can sit in one row.
  var overlay = WidgetStateProperty.resolveWith<Color?>((states) {
    if (states.contains(WidgetState.pressed)) return palette.pressedOverlay;
    if (states.contains(WidgetState.hovered)) return palette.hoverOverlay;
    if (states.contains(WidgetState.focused)) return palette.focusRing;
    return null;
  });
  // Laid over a primary fill, where the neutral ink of [overlay] disappears.
  var overlayOnFill = WidgetStateProperty.resolveWith<Color?>((states) {
    if (states.contains(WidgetState.pressed)) {
      return palette.pressedOverlayOnFill;
    }
    if (states.contains(WidgetState.hovered)) return palette.hoverOverlayOnFill;
    return null;
  });
  var buttonStyle = ButtonStyle(
    overlayColor: overlay,
    splashFactory: NoSplash.splashFactory,
  );
  // The labeled buttons, sized and shaped as the form family. Measured before
  // this block existed: a Material button stood on a 40px stadium beside a
  // 33px picker and a 33px field — another design system's control in the
  // middle of a form row. One height for all four, pinned by a standard
  // density and a shrink-wrapped tap target so the harness and a desktop
  // render agree about it.
  var labeledButton = buttonStyle.copyWith(
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radii.radius)),
    ),
    minimumSize: const WidgetStatePropertyAll(Size(10, FwControlSize.height)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: FwSpacing.lg),
    ),
    textStyle: WidgetStatePropertyAll(type.button),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  return base.copyWith(
    primaryColor: palette.primary,
    extensions: [tokens],
    // For the `InkWell`s, which read these off the theme rather than a style.
    splashFactory: NoSplash.splashFactory,
    splashColor: const Color(0x00000000),
    hoverColor: palette.hoverOverlay,
    highlightColor: palette.pressedOverlay,
    focusColor: palette.focusRing,
    iconButtonTheme: IconButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: labeledButton),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: labeledButton.copyWith(
        side: WidgetStatePropertyAll(BorderSide(color: palette.line)),
        foregroundColor: WidgetStatePropertyAll(palette.ink),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: labeledButton.copyWith(overlayColor: overlayOnFill),
    ),
    textTheme: textTheme.copyWith(
      displayLarge: textTheme.displayLarge!.copyWith(
        fontSize: type.sizeDisplayLarge,
      ),
      displayMedium: textTheme.displayMedium!.copyWith(
        fontSize: type.sizeDisplayMedium,
      ),
      displaySmall: textTheme.displaySmall!.copyWith(
        fontSize: type.sizeDisplaySmall,
      ),
      headlineLarge: textTheme.headlineLarge!.copyWith(
        fontWeight: type.spec.heading,
      ),
      headlineMedium: textTheme.headlineMedium!.copyWith(
        fontSize: type.sizeHeadlineMedium,
        fontWeight: type.spec.heading,
      ),
      headlineSmall: textTheme.headlineSmall!.copyWith(
        fontSize: type.sizeHeadlineSmall,
        fontWeight: type.spec.heading,
      ),
      titleLarge: textTheme.titleLarge!.copyWith(fontSize: type.sizeTitleLarge),
      // The slots Material controls default to, set onto the ramp. An
      // unstyled `TextField` reads bodyLarge, a `DropdownButton` titleMedium,
      // a `TextButton` labelLarge, a bare `Text` bodyMedium — at Material 3's
      // 16/16/14/14 those sat three sizes off the 13px everything styled
      // beside them wears (the Render workbench mixed 11.5 to 16 in one form
      // column). Taught here, a stray Material control degrades to the house
      // sizes instead of to another design system's.
      titleMedium: _onRamp(textTheme.titleMedium!, type.bodyStrong),
      bodyLarge: _onRamp(textTheme.bodyLarge!, type.body),
      bodyMedium: _onRamp(textTheme.bodyMedium!, type.body),
      bodySmall: _onRamp(textTheme.bodySmall!, type.bodySmall),
      labelLarge: _onRamp(textTheme.labelLarge!, type.button),
    ),
    scaffoldBackgroundColor: palette.scaffoldBackground,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: palette.scaffoldBackground,
      foregroundColor: palette.mut,
      elevation: 0,
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelColor: palette.primary,
      unselectedLabelColor: palette.mut,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: type.bodyStrong,
      unselectedLabelStyle: type.bodyStrong,
      indicator: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.primary, width: 3)),
      ),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      elevation: 3,
      color: palette.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radii.radius),
        side: BorderSide(color: palette.line),
      ),
      textStyle: type.body,
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: palette.primary, width: 2),
      ),
      filled: true,
      isDense: true,
      fillColor: palette.bg,
      hoverColor: palette.bg,
      hintStyle: TextStyle(color: palette.mut2),
      // Sized to the app's own controls, not to Material's default. At the
      // old `vertical: 13` a text field stood 42 tall next to a 33 picker and
      // a 32 button — on the New run page the three sit in one column, and
      // the field read as a different, heavier kind of control. The picker's
      // own padding is the reference, so a field and a picker are one family.
      contentPadding: const EdgeInsets.symmetric(
        vertical: FwSpacing.md,
        horizontal: FwSpacing.md,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: labeledButton.copyWith(
        foregroundColor: WidgetStatePropertyAll(palette.onPrimary),
        backgroundColor: WidgetStatePropertyAll(palette.primary),
        elevation: const WidgetStatePropertyAll(0),
        overlayColor: overlayOnFill,
      ),
    ),
    cardColor: palette.bg,
    cardTheme: base.cardTheme.copyWith(
      surfaceTintColor: palette.bg,
      color: palette.bg,
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radii.radius),
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radii.radiusLarge),
      ),
    ),
    dataTableTheme: base.dataTableTheme.copyWith(
      headingRowColor: WidgetStateProperty.all(palette.tableHeader),
      headingTextStyle: type.micro.copyWith(color: palette.mut),
    ),
    // The two raw `Checkbox`es (scenario params, the teardown dialog) rendered
    // Material 3's own control — its shape, its hover halo — beside rows drawn
    // from the tokens. Same move as the buttons above: taught once here rather
    // than styled per call site.
    checkboxTheme: base.checkboxTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radii.radiusSmall),
      ),
      side: BorderSide(color: palette.mut3, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? palette.primary : null,
      ),
      checkColor: WidgetStatePropertyAll(palette.onPrimary),
      overlayColor: overlay,
      splashRadius: 0,
    ),
    dividerTheme: base.dividerTheme.copyWith(color: palette.line, thickness: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: palette.ink,
        borderRadius: BorderRadius.circular(radii.radiusSmall),
      ),
      textStyle: type.caption.copyWith(color: palette.bg),
    ),
  );
}

/// A Material text slot, resized to a house token. Size, weight and tracking
/// come from the token; family, colour and metrics stay the slot's own, so the
/// result still composes the way Material expects.
TextStyle _onRamp(TextStyle slot, TextStyle token) => slot.copyWith(
  fontSize: token.fontSize,
  fontWeight: token.fontWeight,
  letterSpacing: token.letterSpacing,
);

/// Maps a plugin [Tone] to a palette colour. The single place tones become
/// pixels — everywhere else they stay data.
Color toneColor(FwPalette colors, Tone tone) => switch (tone) {
  Tone.neutral => colors.mut2,
  Tone.good => colors.grn,
  Tone.info => colors.info,
  Tone.warn => colors.amber,
  Tone.error => colors.red,
};
