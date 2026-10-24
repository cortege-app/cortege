/// Nettoie un pseudo reçu du maillage avant de l'afficher. N'importe qui dans un
/// groupe peut choisir n'importe quels caractères : on retire ceux de contrôle,
/// ceux qui changent le sens de lecture (un pseudo qui retournerait le texte
/// autour de lui) et les espaces de largeur nulle (deux pseudos qui auraient
/// l'air identiques).
String cleanName(String name) {
  if (name.isEmpty) return name;
  final buffer = StringBuffer();
  for (final rune in name.runes) {
    final control = rune < 0x20 || (rune >= 0x7f && rune <= 0x9f);
    final bidi = (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069) ||
        rune == 0x200e ||
        rune == 0x200f ||
        rune == 0x061c;
    final invisible = rune == 0x200b || rune == 0x2060 || rune == 0xfeff;
    if (!control && !bidi && !invisible) buffer.writeCharCode(rune);
  }
  final cleaned = buffer.toString().trim();
  return cleaned.isEmpty ? '?' : cleaned;
}
