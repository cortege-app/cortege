/// « à l'instant », « il y a 3 min », « il y a 1 h 05 ».
String agoText(DateTime? since, DateTime now) {
  if (since == null) return 'aucun signe';
  final elapsed = now.difference(since);
  if (elapsed.inSeconds < 45) return 'à l\'instant';
  if (elapsed.inMinutes < 60) return 'il y a ${elapsed.inMinutes} min';
  final minutes = elapsed.inMinutes % 60;
  return minutes == 0
      ? 'il y a ${elapsed.inHours} h'
      : 'il y a ${elapsed.inHours} h ${minutes.toString().padLeft(2, '0')}';
}

/// « depuis 3 min » pour un silence.
String sinceText(DateTime? since, DateTime now) {
  if (since == null) return 'depuis le début';
  return agoText(since, now).replaceFirst('il y a', 'depuis').replaceFirst('à l\'instant', 'à l\'instant');
}

/// « aujourd'hui à 14:30 », « demain à 08:00 », « le 21/10 à 14:30 ».
String clockText(DateTime local, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return "aujourd'hui à $time";
  if (diff == 1) return 'demain à $time';
  return 'le ${two(local.day)}/${two(local.month)} à $time';
}
