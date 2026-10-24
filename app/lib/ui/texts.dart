import '../vault/pin_policy.dart';

String describePinProblem(PinProblem problem) => switch (problem) {
      PinProblem.tooShort => 'Il faut au moins ${PinPolicy.minLength} chiffres.',
      PinProblem.tooLong => 'Pas plus de ${PinPolicy.maxLength} chiffres.',
      PinProblem.notDigits => 'Seulement des chiffres.',
      PinProblem.tooGuessable =>
        'Trop facile à deviner. Évite les suites et les répétitions.',
      PinProblem.alreadyUsed =>
        'Ce code ne peut pas être utilisé. Choisis-en un autre.',
    };
