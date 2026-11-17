import '../l10n/language.dart';
import '../vault/pin_policy.dart';

String describePinProblem(PinProblem problem) => switch (problem) {
      PinProblem.tooShort => tr('At least ${PinPolicy.minLength} digits.', 'Il faut au moins ${PinPolicy.minLength} chiffres.'),
      PinProblem.tooLong => tr('No more than ${PinPolicy.maxLength} digits.', 'Pas plus de ${PinPolicy.maxLength} chiffres.'),
      PinProblem.notDigits => tr('Digits only.', 'Seulement des chiffres.'),
      PinProblem.tooGuessable =>
        tr('Too easy to guess. Avoid sequences and repeats.', 'Trop facile à deviner. Évite les suites et les répétitions.'),
      PinProblem.alreadyUsed =>
        tr("This code can't be used. Choose another one.", 'Ce code ne peut pas être utilisé. Choisis-en un autre.'),
    };
