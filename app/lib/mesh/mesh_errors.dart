/// Le QR vient d'un autre événement que celui où se trouve déjà ce téléphone.
class DifferentEventException implements Exception {
  @override
  String toString() => 'DifferentEventException';
}

/// Il faut un pseudo avant d'écrire ou de s'appairer.
class NeedsDisplayNameException implements Exception {
  @override
  String toString() => 'NeedsDisplayNameException';
}

/// Un binôme tient au plus à quatre personnes.
class BuddyFullException implements Exception {
  @override
  String toString() => 'BuddyFullException';
}

/// Le canal des medics est inconnu de ce téléphone : aucune invitation reçue ne
/// le contenait.
class NoMedicChannelException implements Exception {
  @override
  String toString() => 'NoMedicChannelException';
}
