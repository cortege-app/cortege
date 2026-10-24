import 'package:cortege/vault/pin_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('un code correct passe', () {
    expect(PinPolicy.check('483920'), isNull);
    expect(PinPolicy.check('48392017'), isNull);
  });

  test('trop court', () {
    expect(PinPolicy.check('48392'), PinProblem.tooShort);
    expect(PinPolicy.check(''), PinProblem.tooShort);
  });

  test('trop long', () {
    expect(PinPolicy.check('4839201748392'), PinProblem.tooLong);
  });

  test('que des chiffres', () {
    expect(PinPolicy.check('48392a'), PinProblem.notDigits);
    expect(PinPolicy.check('4839 20'), PinProblem.notDigits);
  });

  test('répétitions et suites refusées', () {
    for (final pin in ['000000', '111111', '123456', '654321', '234567', '987654']) {
      expect(PinPolicy.check(pin), PinProblem.tooGuessable, reason: pin);
    }
  });

  test('une suite brisée passe', () {
    expect(PinPolicy.check('123457'), isNull);
    expect(PinPolicy.check('121212'), isNull);
  });

  test('require lève PinRejected', () {
    expect(() => PinPolicy.require('12'), throwsA(isA<PinRejected>()));
    PinPolicy.require('483920');
  });
}
