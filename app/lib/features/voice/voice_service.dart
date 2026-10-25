import 'dart:convert';
import 'dart:io';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_parser.dart';

class VoiceService {
  final SpeechToText _speech = SpeechToText();

  Future<VoiceFields> parseAudio(String path) async {
    final bytes = await File(path).readAsBytes();
    final schema = Schema.object(
      properties: {
        'item': Schema.string(nullable: true),
        'category': Schema.enumString(
          enumValues: ['material', 'labour', 'equipment', 'transport', 'other'],
          nullable: true,
        ),
        'quantity': Schema.number(nullable: true),
        'unit': Schema.string(nullable: true),
        'rate': Schema.number(nullable: true),
        'amount': Schema.number(nullable: true),
        'vendor': Schema.string(nullable: true),
        'note': Schema.string(nullable: true),
      },
      optionalProperties: [
        'item',
        'category',
        'quantity',
        'unit',
        'rate',
        'amount',
        'vendor',
        'note',
      ],
    );
    final model = FirebaseAI.googleAI().generativeModel(
      model: 'gemini-3.8-flash',
      systemInstruction: Content.system(
        'Extract a construction expense from English, Hindi, or mixed Hindi-English audio. Understand lakh, crore, hazaar and Indian construction units. Never guess. Use null when not spoken. Amount and rate are rupees. Category must be material, labour, equipment, transport, or other.',
      ),
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json',
        responseSchema: schema,
      ),
    );
    final response = await model
        .generateContent([
          Content.multi([
            TextPart('Extract the expense.'),
            InlineDataPart('audio/mp4', bytes),
          ]),
        ])
        .timeout(const Duration(seconds: 15));
    return VoiceFields.fromJson(
      jsonDecode(response.text ?? '{}') as Map<String, dynamic>,
    );
  }

  Future<bool> startOnDevice(
    void Function(String text, bool finalResult) onResult, {
    String locale = 'en_IN',
  }) async {
    final available = await _speech.initialize();
    if (!available) return false;
    await _speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        localeId: locale,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
      ),
    );
    return true;
  }

  Future<void> stop() => _speech.stop();
}
