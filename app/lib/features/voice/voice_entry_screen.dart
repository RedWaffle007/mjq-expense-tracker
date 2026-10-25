import 'dart:io';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../entries/entry_form_screen.dart';
import 'voice_parser.dart';
import 'voice_service.dart';

class VoiceEntryScreen extends StatefulWidget {
  const VoiceEntryScreen({required this.siteId, super.key});
  final String siteId;
  @override
  State<VoiceEntryScreen> createState() => _VoiceEntryScreenState();
}

class _VoiceEntryScreenState extends State<VoiceEntryScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final VoiceService _voice = VoiceService();
  bool _recording = false;
  bool _processing = false;
  bool _onDevice = false;
  String _transcript = '';
  String? _audioPath;
  String? _message;
  Timer? _recordingTimer;
  int _recordingSeconds = 0;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recorder.dispose();
    if (_audioPath != null) File(_audioPath!).delete().ignore();
    super.dispose();
  }

  Future<void> _start() async {
    final online = !(await Connectivity().checkConnectivity()).contains(
      ConnectivityResult.none,
    );
    if (!online) return _startOnDevice('Offline — listening on this phone');
    if (!await _recorder.hasPermission()) {
      setState(
        () => _message = 'Microphone permission is needed for voice entry.',
      );
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/expense_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000,
      ),
      path: path,
    );
    setState(() {
      _audioPath = path;
      _recording = true;
      _message = 'Listening…';
    });
    _startTimer();
  }

  Future<void> _stop() async {
    _recordingTimer?.cancel();
    if (_onDevice) {
      await _voice.stop();
      if (_transcript.trim().isNotEmpty) _finish(parseOnDevice(_transcript));
      return;
    }
    final path = await _recorder.stop();
    if (path == null) return;
    setState(() {
      _recording = false;
      _processing = true;
      _message = 'Understanding expense…';
    });
    try {
      _finish(await _voice.parseAudio(path));
    } catch (_) {
      if (mounted) await _startOnDevice("Couldn't reach Gemini — speak again");
    } finally {
      File(path).delete().ignore();
    }
  }

  Future<void> _startOnDevice(String message) async {
    setState(() {
      _processing = false;
      _onDevice = true;
      _transcript = '';
      _message = message;
    });
    final ready = await _voice.startOnDevice((text, isFinal) {
      if (!mounted) return;
      setState(() {
        _transcript = text;
        _recording = !isFinal;
      });
      if (isFinal) {
        _recordingTimer?.cancel();
        if (text.trim().isNotEmpty) _finish(parseOnDevice(text));
      }
    });
    if (!ready && mounted) {
      setState(
        () => _message = "Voice isn't available right now — use manual entry.",
      );
    }
    if (ready && mounted) {
      setState(() => _recording = true);
      _startTimer();
    }
  }

  void _startTimer() {
    _recordingTimer?.cancel();
    _recordingSeconds = 0;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _recordingSeconds++);
      if (_recordingSeconds >= 60) _stop();
    });
  }

  String get _elapsed =>
      '${(_recordingSeconds ~/ 60).toString().padLeft(2, '0')}:'
      '${(_recordingSeconds % 60).toString().padLeft(2, '0')}';

  void _finish(VoiceFields fields) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            EntryFormScreen(initialSiteId: widget.siteId, voiceFields: fields),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Voice expense')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_recording ? Icons.mic : Icons.mic_none, size: 72),
            const SizedBox(height: 20),
            Text(
              _message ??
                  'Speak naturally. You will review everything before it is saved.',
              textAlign: TextAlign.center,
            ),
            if (_recording)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('$_elapsed / 01:00'),
              ),
            if (_transcript.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_transcript, textAlign: TextAlign.center),
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _processing ? null : (_recording ? _stop : _start),
              icon: _processing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_recording ? Icons.stop : Icons.mic),
              label: Text(_recording ? 'Stop' : 'Start speaking'),
            ),
          ],
        ),
      ),
    ),
  );
}
