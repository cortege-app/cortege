import 'package:flutter/material.dart';

/// Fond noir pur (économise la batterie sur les écrans OLED), texte blanc,
/// un seul accent jaune de signalisation, rouge réservé au danger. Pas de
/// dégradé, pas d'ombre, pas de coins arrondis, pas d'animation.
class Palette {
  static const background = Color(0xFF000000);
  static const text = Color(0xFFFFFFFF);
  static const muted = Color(0xFFBDBDBD);
  static const accent = Color(0xFFFFD60A);
  static const danger = Color(0xFFFF6B5E);
  static const line = Color(0xFF8C8C8C);
}

const _square = RoundedRectangleBorder();

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Palette.accent,
    onPrimary: Colors.black,
    secondary: Palette.accent,
    onSecondary: Colors.black,
    surface: Palette.background,
    onSurface: Palette.text,
    error: Palette.danger,
    onError: Colors.black,
    outline: Palette.line,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.background,
    splashFactory: NoSplash.splashFactory,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const _NoTransition(),
      },
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
      titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
      bodyLarge: TextStyle(fontSize: 20, height: 1.3),
      bodyMedium: TextStyle(fontSize: 18, height: 1.3),
      labelLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.background,
      foregroundColor: Palette.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: Palette.text,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(72),
        shape: _square,
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(72),
        shape: _square,
        foregroundColor: Palette.text,
        side: const BorderSide(color: Palette.text, width: 2),
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Palette.line, thickness: 1),
  );
}

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
