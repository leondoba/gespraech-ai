import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() => runApp(const GApp());

class GApp extends StatelessWidget {
  const GApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'Gespräch',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2F5BD8), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF2F5BD8), brightness: Brightness.dark, useMaterial3: true),
        home: const Chat(),
      );
}

// code : [nom pour l'IA, locale voix, nom affiché]
const langs = {
  'de': ['German', 'de-DE', 'Deutsch'],
  'en': ['English', 'en-US', 'English'],
  'fr': ['French', 'fr-FR', 'Français'],
};

class Msg {
  final bool me;
  String text;
  String? fix, tr;
  bool open = false;
  Msg(this.me, this.text);
}

class Chat extends StatefulWidget {
  const Chat({super.key});
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> with SingleTickerProviderStateMixin {
  final stt = SpeechToText();
  final tts = FlutterTts();
  final scroll = ScrollController();
  final input = TextEditingController();
  late final AnimationController pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..repeat(reverse: true);
  final List<Msg> msgs = [];
  List<String> sugg = [];
  final Set<String> vocab = {};
  String nat = 'fr', tgt = 'de', lvl = 'A2', state = 'idle', status = '', model = 'gemini-2.5-flash-lite', key = '';
  bool hints = false, auto = true, started = false, sttOk = false, busy = false;
  int gen = 0, idle = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    model = p.getString('model') ?? model;
    key = p.getString('gkey') ?? '';
    vocab.addAll(p.getStringList('vocab') ?? []);
    await tts.awaitSpeakCompletion(true);
    sttOk = await stt.initialize(
      onError: (e) => setState(() => status = 'Micro : ${e.errorMsg}'),
      onStatus: (s) {
        if (s == 'done' && state == 'listen' && !busy) {
          setState(() => state = 'idle');
          if (auto && ++idle < 3) {
            Future.delayed(const Duration(milliseconds: 300), listen);
          } else {
            setState(() => status = 'Touchez le micro pour parler');
          }
        }
      },
    );
    if (!sttOk) status = 'Micro indisponible : autorisez-le dans les réglages Android';
    if (key.isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _settings());
    setState(() {});
  }

  Future<void> _settings() async {
    final u = TextEditingController(text: key), t = TextEditingController(text: model);
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clé Gemini gratuite'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: u, decoration: const InputDecoration(labelText: 'Clé (aistudio.google.com/app/apikey)')),
          TextField(controller: t, decoration: const InputDecoration(labelText: 'Modèle (laisser par défaut)'),
        ]),
        actions: [
          FilledButton(
            onPressed: () async {
              key = u.text.trim();
              if (t.text.trim().isNotEmpty) model = t.text.trim();
              final p = await SharedPreferences.getInstance();
              await p.setString('gkey', key);
              await p.setString('model', model);
              if (c.mounted) Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    setState(() {});
  }

  Stream<String> _stream(String system, List<Map<String, String>> messages) async* {
    final req = http.Request('POST', Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?alt=sse&key=$key'))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'systemInstruction': {'parts': [{'text': system}]},
        'contents': messages.map((m) => {'role': m['role'] == 'assistant' ? 'model' : 'user', 'parts': [{'text': m['content']}]}).toList(),
        'generationConfig': {'temperature': 0.9, 'maxOutputTokens': 300},
      });
    final res = await http.Client().send(req).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw 'IA ${res.statusCode}${res.statusCode == 429 ? " (trop rapide, patientez)" : ""}';
    await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final d = line.substring(5).trim();
      if (d.isEmpty) continue;
      try {
        final parts = jsonDecode(d)['candidates'][0]['content']['parts'] as List;
        final t = parts.map((p) => p['text'] ?? '').join();
        if (t.isNotEmpty) yield t;
      } catch (_) {}
    }
  }

  String get _system =>
      'You are Fox, a warm, funny, curious friend helping someone practise ${langs[tgt]![0]} by voice. '
      'Speak ONLY ${langs[tgt]![0]}. The learner\'s native language is ${langs[nat]![0]}; level $lvl: keep words and grammar at that level. '
      'React to what they said, add a tiny personal remark, then ask ONE follow-up question. Max 2 short sentences. Plain text only, no markdown, no translation. Sound like a real person in spoken conversation: casual, natural reactions, never repeat the learner\'s sentence back, and do not end every turn with a question. '
      'If the user message is "(start)", greet them and ask a first question.';

  Future<void> turn(String text, {bool first = false}) async {
    text = text.trim();
    if (busy || (text.isEmpty && !first)) return;
    if (key.isEmpty) return _settings();
    busy = true;
    started = true;
    idle = 0;
    final my = ++gen;
    await stt.cancel();
    Msg? um;
    if (!first) {
      um = Msg(true, text);
      msgs.add(um);
    }
    final history = msgs.where((m) => m.text.isNotEmpty).toList();
    final ai = Msg(false, '');
    msgs.add(ai);
    sugg = [];
    state = 'think';
    status = '';
    setState(() {});
    _down();

    final api = <Map<String, String>>[
      {'role': 'user', 'content': '(start)'},
      ...history.skip(history.length > 14 ? history.length - 14 : 0).map((m) => {'role': m.me ? 'user' : 'assistant', 'content': m.text}),
    ];
    final re = RegExp(r'^[\s\S]*?[.!?…]+\s');
    var sp = 0;
    Future<void> chain = Future.value();
    void q(String s) => chain = chain.then<void>((_) async {
          if (my == gen) await _say(s);
        });
    try {
      await for (final d in _stream(_system, api)) {
        if (my != gen) return;
        ai.text += d;
        setState(() {});
        _down();
        Match? m;
        while ((m = re.firstMatch(ai.text.substring(sp))) != null) {
          sp += m!.group(0)!.length;
          q(m.group(0)!);
        }
      }
    } catch (e) {
      busy = false;
      state = 'idle';
      status = 'Erreur : $e';
      setState(() {});
      return;
    }
    if (sp < ai.text.length) q(ai.text.substring(sp));
    busy = false;
    _analyze(um, ai, first ? '' : text, my);
    await chain;
    if (my != gen) return;
    state = 'idle';
    setState(() {});
    if (auto && sttOk) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (my == gen) listen();
    } else {
      setState(() => status = 'À vous : touchez le micro ou écrivez');
    }
  }

  Future<void> _say(String s) async {
    setState(() => state = 'talk');
    await tts.setLanguage(langs[tgt]![1]);
    await tts.setSpeechRate(0.48);
    await tts.speak(s);
  }

  Future<void> _analyze(Msg? um, Msg ai, String ut, int my) async {
    final N = langs[nat]![0], T = langs[tgt]![0];
    final prompt = 'Language learning analysis. Target language: $T. Learner native language: $N; level $lvl.\n'
        '${ut.isEmpty ? '(no learner sentence yet)' : 'Learner said: "$ut"'}\nPartner replied: "${ai.text}"\n'
        'Return ONLY JSON: {"fix":"${ut.isEmpty ? 'empty string' : 'if the learner made mistakes, short correction with the right sentence, in $N; else empty string'}",'
        '"tr":"translation of the reply in $N","vocab":[{"w":"useful $T word","t":"translation in $N"}],"sugg":["3 natural answers the learner could say next, in $T"]} (max 3 vocab)';
    try {
      final r = await http
          .post(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'contents': [{'role': 'user', 'parts': [{'text': prompt}]}],
                'generationConfig': {'responseMimeType': 'application/json', 'temperature': 0.4},
              }))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 || my != gen) return;
      final t = jsonDecode(utf8.decode(r.bodyBytes))['candidates'][0]['content']['parts'][0]['text'] as String;
      final j = jsonDecode(t.substring(t.indexOf('{'), t.lastIndexOf('}') + 1));
      setState(() {
        ai.tr = j['tr']?.toString();
        final f = (j['fix'] ?? '').toString();
        if (um != null && f.isNotEmpty) um.fix = f;
        sugg = hints ? List<String>.from((j['sugg'] ?? []).map((e) => e.toString())) : [];
        for (final v in (j['vocab'] ?? [])) {
          vocab.add('${v['w']} = ${v['t']}');
        }
      });
      final p = await SharedPreferences.getInstance();
      await p.setStringList('vocab', vocab.toList());
    } catch (_) {}
  }

  Future<void> listen() async {
    if (!sttOk || busy || stt.isListening) return;
    setState(() {
      state = 'listen';
      status = 'Je vous écoute… parlez en ${langs[tgt]![2]}';
    });
    await stt.listen(
      localeId: langs[tgt]![1].replaceAll('-', '_'),
      pauseFor: const Duration(seconds: 2),
      listenFor: const Duration(seconds: 30),
      listenOptions: SpeechListenOptions(partialResults: true, cancelOnError: true),
      onResult: (r) {
        input.text = r.recognizedWords;
        if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
          final t = r.recognizedWords;
          input.clear();
          turn(t);
        }
      },
    );
  }

  void _mic() {
    if (!started) return _start();
    if (stt.isListening) {
      stt.stop();
      return;
    }
    tts.stop();
    idle = 0;
    listen();
  }

  void _start() => turn('', first: true);

  void _reset() {
    gen++;
    busy = false;
    stt.cancel();
    tts.stop();
    msgs.clear();
    sugg = [];
    started = false;
    state = 'idle';
    status = '';
    setState(() {});
  }

  void _down() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.animateTo(scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      });

  @override
  void dispose() {
    pulse.dispose();
    scroll.dispose();
    input.dispose();
    super.dispose();
  }

  Widget _avatar() {
    final c = state == 'listen' ? Colors.green.shade200 : Theme.of(context).colorScheme.primaryContainer;
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, __) => Transform.scale(
        scale: (state == 'talk' || state == 'listen') ? 1 + 0.08 * pulse.value : 1.0,
        child: CircleAvatar(radius: 44, backgroundColor: c, child: Text(state == 'think' ? '🤔' : '🦊', style: const TextStyle(fontSize: 46))),
      ),
    );
  }

  Widget _dd(String label, String v, void Function(String) f) => Expanded(
        child: DropdownButtonFormField<String>(
          value: v,
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
          items: langs.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value[2]))).toList(),
          onChanged: (x) {
            if (x != null) {
              f(x);
              _reset();
            }
          },
        ),
      );

  Widget _bubble(Msg m, ColorScheme cs) {
    final fg = m.me ? cs.onPrimary : cs.onSecondaryContainer;
    return Align(
      alignment: m.me ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => setState(() => m.open = !m.open),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          decoration: BoxDecoration(color: m.me ? cs.primary : cs.secondaryContainer, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.text.isEmpty ? '…' : m.text, style: TextStyle(color: fg, fontSize: 16)),
            if (m.fix != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('✏️ ${m.fix}', style: TextStyle(fontSize: 12, color: m.me ? Colors.amber.shade200 : cs.error))),
            if (!m.me && m.open && m.tr != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(m.tr!, style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: fg))),
            if (!m.me && m.text.isNotEmpty) InkWell(onTap: () => _say(m.text), child: Icon(Icons.volume_up, size: 18, color: fg)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Gespräch'), actions: [
        Center(child: Text('📚 ${vocab.length}')),
        IconButton(icon: const Icon(Icons.settings), onPressed: _settings),
      ]),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              _dd('Je parle', nat, (v) => nat = v),
              const SizedBox(width: 8),
              _dd('Je pratique', tgt, (v) => tgt = v),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: lvl,
                items: ['A1', 'A2', 'B1', 'B2', 'C1'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (x) {
                  if (x != null) {
                    lvl = x;
                    _reset();
                  }
                },
              ),
            ]),
          ),
          _avatar(),
          Padding(padding: const EdgeInsets.all(6), child: Text(status, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
            child: !started
                ? Center(child: FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_arrow), label: const Text('Démarrer')))
                : ListView.builder(controller: scroll, padding: const EdgeInsets.all(12), itemCount: msgs.length, itemBuilder: (_, i) => _bubble(msgs[i], cs)),
          ),
          if (sugg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 6, children: sugg.map((s) => ActionChip(label: Text(s), onPressed: () => turn(s))).toList()),
            ),
          Row(children: [
            const SizedBox(width: 8),
            Switch(value: auto, onChanged: (v) => setState(() => auto = v)),
            const Text('Mains libres', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            Switch(value: hints, onChanged: (v) => setState(() => hints = v)),
            const Text('Suggestions', style: TextStyle(fontSize: 12)),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: input,
                  onSubmitted: (t) {
                    input.clear();
                    turn(t);
                  },
                  decoration: InputDecoration(hintText: 'Ou écrivez ici…', border: OutlineInputBorder(borderRadius: BorderRadius.circular(24))),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () {
                  final t = input.text;
                  input.clear();
                  turn(t);
                },
              ),
              FloatingActionButton(onPressed: _mic, child: Icon(state == 'listen' ? Icons.stop : Icons.mic)),
            ]),
          ),
        ]),
      ),
    );
  }
}
