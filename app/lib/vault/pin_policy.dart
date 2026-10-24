enum PinProblem {
  tooShort,
  tooLong,
  notDigits,
  tooGuessable,
  alreadyUsed,
}

class PinRejected implements Exception {
  PinRejected(this.problem);

  final PinProblem problem;

  @override
  String toString() => 'PinRejected(${problem.name})';
}

/// Un PIN court reste devinable même avec Argon2id : on impose 6 chiffres au
/// moins, et on refuse les codes que n'importe qui essaierait en premier.
class PinPolicy {
  static const minLength = 6;
  static const maxLength = 12;

  static PinProblem? check(String pin) {
    if (pin.length < minLength) return PinProblem.tooShort;
    if (pin.length > maxLength) return PinProblem.tooLong;
    if (!RegExp(r'^[0-9]+$').hasMatch(pin)) return PinProblem.notDigits;
    if (_isRepeat(pin) || _isRun(pin)) return PinProblem.tooGuessable;
    return null;
  }

  static void require(String pin) {
    final problem = check(pin);
    if (problem != null) throw PinRejected(problem);
  }

  static bool _isRepeat(String pin) => pin.split('').toSet().length == 1;

  /// 123456, 654321, 456789...
  static bool _isRun(String pin) {
    final digits = pin.codeUnits;
    final step = digits[1] - digits[0];
    if (step != 1 && step != -1) return false;
    for (var i = 2; i < digits.length; i++) {
      if (digits[i] - digits[i - 1] != step) return false;
    }
    return true;
  }
}
