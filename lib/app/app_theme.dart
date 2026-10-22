import 'package:flutter/material.dart';

/// Design tokens for the Figma redesign (Phase 1: Home + its action sheets).
///
/// These values were read **visually** from the approved Figma frames — the
/// design file is a view-only session, so Dev Mode/Inspect was unavailable and
/// no exact token could be exported. They are therefore close visual
/// approximations, not the designer's published values:
///
/// * `Home` (`2:1119`) — header, hero tile, headline, primary + ghost actions
/// * `Home · Scan document` (`7:1423`), `Home · Choose image` (`7:1500`),
///   `Home · Import PDF` (`7:1577`) — the three shared action sheets
///
/// Keeping them in one file means "make it match the design" is a single edit
/// rather than a hunt through widgets, and it is the only place a colour is
/// written down.
abstract final class AppColors {
  /// Near-white app background.
  ///
  /// Deliberately not pure white: the sheets are white, and the page needs to
  /// read as a separate surface behind them.
  static const Color page = Color(0xFFFAFAFC);

  /// Sheet and card surface.
  static const Color surface = Color(0xFFFFFFFF);

  /// Deep navy used for the primary button, headings and action icons.
  static const Color primary = Color(0xFF242A5C);

  /// Body ink for copy that is not a heading and not muted.
  static const Color ink = Color(0xFF1C2143);

  /// Restrained grey for subtitles, hints and captions.
  static const Color muted = Color(0xFF6B7186);

  /// Pale periwinkle: the hero icon tile and the icon tile inside a sheet row.
  static const Color tile = Color(0xFFEDEEFA);

  /// Subtle grey fill behind a sheet row / list card.
  static const Color rowTint = Color(0xFFF4F5F9);

  /// Hairline borders and dividers.
  static const Color hairline = Color(0xFFE6E8F0);
}

/// Corner radii, in the order they appear on the Home frame.
abstract final class AppRadii {
  /// The hero glyph tile (large, soft).
  static const double heroTile = 26;

  /// Top corners of a bottom sheet.
  static const double sheet = 24;

  /// Sheet rows and list cards.
  static const double card = 16;

  /// Icon tile inside a sheet row.
  static const double cardTile = 12;

  /// Buttons.
  static const double button = 14;
}

/// Spacing scale. The design works on a 4 px grid.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
}

/// The app theme.
///
/// Built from a seeded scheme so any Material 3 widget that is not explicitly
/// styled still lands in the same navy family, then overridden where the design
/// is specific (buttons, sheets, app bar).
ThemeData buildAppTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: Brightness.light,
  );
  final scheme = base.copyWith(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
    onSurfaceVariant: AppColors.muted,
    outlineVariant: AppColors.hairline,
  );

  final textTheme = ThemeData.light().textTheme
      .apply(bodyColor: AppColors.ink, displayColor: AppColors.ink)
      .copyWith(
        // "Your documents, ready to use."
        headlineMedium: const TextStyle(
          fontSize: 28,
          height: 1.22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: AppColors.primary,
        ),
        // "Scan, extract text and translate. All in one place."
        bodyMedium: const TextStyle(
          fontSize: 14.5,
          height: 1.5,
          color: AppColors.muted,
        ),
        // Sheet titles.
        titleMedium: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        // Sheet row titles and the ghost actions.
        titleSmall: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
        // Sheet row subtitles.
        bodySmall: const TextStyle(
          fontSize: 13,
          height: 1.4,
          color: AppColors.muted,
        ),
        // Primary button label.
        labelLarge: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        // "Script: Auto".
        labelMedium: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
        labelSmall: const TextStyle(fontSize: 12, color: AppColors.muted),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.page,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleMedium,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        // Full-width, comfortable primary action.
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.button),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        minimumSize: const Size(48, 44),
        textStyle: textTheme.titleSmall,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: AppColors.hairline,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.hairline,
      thickness: 1,
      space: 1,
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: AppColors.primary),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
