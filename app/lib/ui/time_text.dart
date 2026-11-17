import '../l10n/language.dart';

/// La durée écoulée sans « il y a » : « 3 min », « 1 h 05 ».
String _elapsedText(Duration elapsed) {
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min';
  final minutes = elapsed.inMinutes % 60;
  return minutes == 0
      ? '${elapsed.inHours} h'
      : '${elapsed.inHours} h ${minutes.toString().padLeft(2, '0')}';
}

/// « à l'instant », « il y a 3 min », « il y a 1 h 05 ».
/// En anglais : « just now », « 3 min ago », « 1 h 05 ago ».
String agoText(DateTime? since, DateTime now) {
  if (since == null) return tr('no sign', 'aucun signe');
  final elapsed = now.difference(since);
  if (elapsed.inSeconds < 45) return tr('just now', 'à l\'instant');
  final text = _elapsedText(elapsed);
  return tr('$text ago', 'il y a $text');
}

/// « depuis 3 min » pour un silence. En anglais : « for 3 min ».
String sinceText(DateTime? since, DateTime now) {
  if (since == null) return tr('since the start', 'depuis le début');
  final elapsed = now.difference(since);
  if (elapsed.inSeconds < 45) return tr('just now', 'à l\'instant');
  final text = _elapsedText(elapsed);
  return tr('for $text', 'depuis $text');
}

/// « aujourd'hui à 14:30 », « demain à 08:00 », « le 21/10 à 14:30 ».
String clockText(DateTime local, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return tr('today at $time', "aujourd'hui à $time");
  if (diff == 1) return tr('tomorrow at $time', 'demain à $time');
  return tr('on ${two(local.day)}/${two(local.month)} at $time', 'le ${two(local.day)}/${two(local.month)} à $time');
}
