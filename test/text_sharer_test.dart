import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_utility_flutter/ocr/data/text_sharer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pdf_utility/share');
  final calls = <MethodCall>[];

  void stub(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends the text and the subject', () async {
    stub((call) async {
      calls.add(call);
      return true;
    });

    final shown = await const TextSharer().shareText('hello', subject: 'Title');

    expect(shown, isTrue);
    expect(calls.single.method, 'shareText');
    expect(calls.single.arguments, <String, Object?>{
      'text': 'hello',
      'subject': 'Title',
    });
  });

  test('omits the subject when there is none', () async {
    stub((call) async {
      calls.add(call);
      return true;
    });

    await const TextSharer().shareText('hello');

    expect(calls.single.arguments, <String, Object?>{'text': 'hello'});
  });

  test('never sends blank text', () async {
    stub((call) async {
      calls.add(call);
      return true;
    });

    expect(await const TextSharer().shareText('   '), isFalse);
    expect(await const TextSharer().shareText(''), isFalse);
    expect(calls, isEmpty);
  });

  test(
    'reports false when the platform says the sheet never appeared',
    () async {
      stub((call) async {
        calls.add(call);
        return false;
      });

      expect(await const TextSharer().shareText('hello'), isFalse);
    },
  );

  test(
    'reports false instead of throwing when nothing handles the call',
    () async {
      // No stub at all: the call answers with MissingPluginException.
      expect(await const TextSharer().shareText('hello'), isFalse);
    },
  );

  test(
    'reports false instead of throwing when the native side fails',
    () async {
      stub((call) async => throw PlatformException(code: 'boom'));

      expect(await const TextSharer().shareText('hello'), isFalse);
    },
  );

  test('a null reply is treated as "no sheet shown"', () async {
    stub((call) async => null);

    expect(await const TextSharer().shareText('hello'), isFalse);
  });
}
