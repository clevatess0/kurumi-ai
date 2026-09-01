// =====================================================================
// KurumiAI — Sesli, Groq destekli, Android'e derin erişimli asistan
// Tek parça main.dart — eksiksiz, kopyala-yapıştır çalışır.
// =====================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:rive/rive.dart' as rive;
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF05070A),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const KurumiAIApp());
}

// =====================================================================
// APP ROOT
// =====================================================================

class KurumiAIApp extends StatelessWidget {
  const KurumiAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KurumiAI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: KColors.bgTop,
        colorScheme: ColorScheme.fromSeed(
          seedColor: KColors.neonCyan,
          brightness: Brightness.dark,
        ),
        fontFamily: GoogleFonts.rajdhani().fontFamily,
      ),
      home: const KurumiHomePage(),
    );
  }
}

// =====================================================================
// RENK PALETİ
// =====================================================================

class KColors {
  static const bgTop = Color(0xFF05070A);
  static const bgBottom = Color(0xFF0A0E14);
  static const neonCyan = Color(0xFF00F5FF);
  static const neonBlue = Color(0xFF3B82F6);
  static const neonGreen = Color(0xFF7CFFC7);
  static const glassFill = Color(0x14FFFFFF);
  static const glassBorder = Color(0x33FFFFFF);
  static const textPrimary = Color(0xFFEAF6FF);
  static const textSecondary = Color(0xFF8CA3B5);
  static const danger = Color(0xFFFF4D6D);
}

// =====================================================================
// SOHBET MESAJ MODELİ
// =====================================================================

enum ChatRole { user, assistant, system }

class ChatMessage {
  final ChatRole role;
  final String text;
  final DateTime time;
  ChatMessage({required this.role, required this.text, DateTime? time})
      : time = time ?? DateTime.now();
}

// =====================================================================
// AYARLAR (API anahtarı, model, ses tercihi) — SharedPreferences
// =====================================================================

class SettingsService {
  static const _keyApiKey = 'kurumi_api_key';
  static const _keyModel = 'kurumi_model';
  static const _keyVoice = 'kurumi_voice_enabled';

  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiKey);
  }

  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiKey, key);
  }

  static Future<String> getModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyModel) ?? 'openai/gpt-oss-20b';
  }

  static Future<void> setModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyModel, model);
  }

  static Future<bool> getVoiceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyVoice) ?? true;
  }

  static Future<void> setVoiceEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyVoice, value);
  }
}

// =====================================================================
// GROQ API SERVİSİ (OpenAI-uyumlu Chat Completions + Tool Use)
// =====================================================================

class GroqService {
  static const _endpoint = 'https://api.groq.com/openai/v1/chat/completions';

  static const String systemPrompt = '''
Senin adın KurumiAI. Kendini her zaman "KurumiAI" olarak tanıtırsın, başka bir isim kullanmazsın.
Türkçe konuşan, samimi, kısa ve net cevaplar veren; gerektiğinde telefondaki araçları
(uygulama açma, pil durumu, alarm kurma, web/URL açma) kullanan sesli bir asistansın.
Cevapların sesli okunacağı için kısa cümleler kur, gereksiz liste/markdown kullanma.
Bir araç kullanman gerektiğinde önce kısaca ne yapacağını belirt, sonra ilgili aracı çağır.
''';

  // Groq tool tanımları OpenAI ile birebir uyumludur:
  // { "type": "function", "function": { name, description, parameters } }
  static List<Map<String, dynamic>> get tools => [
        {
          "type": "function",
          "function": {
            "name": "open_app",
            "description":
                "Kullanıcının telefonundaki bir uygulamayı ismiyle açar. "
                "Örnek: WhatsApp, Instagram, YouTube, Spotify, Ayarlar, Kamera, Google Haritalar.",
            "parameters": {
              "type": "object",
              "properties": {
                "app_name": {
                  "type": "string",
                  "description": "Açılacak uygulamanın adı"
                }
              },
              "required": ["app_name"]
            }
          }
        },
        {
          "type": "function",
          "function": {
            "name": "get_battery_status",
            "description":
                "Telefonun anlık pil yüzdesini ve şarj durumunu döndürür.",
            "parameters": {"type": "object", "properties": {}}
          }
        },
        {
          "type": "function",
          "function": {
            "name": "set_alarm",
            "description":
                "Android saat uygulamasında belirtilen saat ve dakikaya alarm kurar.",
            "parameters": {
              "type": "object",
              "properties": {
                "hour": {"type": "integer", "description": "0-23 arası saat"},
                "minute": {"type": "integer", "description": "0-59 arası dakika"},
                "label": {
                  "type": "string",
                  "description": "Alarm etiketi (opsiyonel)"
                }
              },
              "required": ["hour", "minute"]
            }
          }
        },
        {
          "type": "function",
          "function": {
            "name": "open_url",
            "description":
                "Verilen bir web adresini tarayıcıda açar ya da bir konuyu Google'da arar.",
            "parameters": {
              "type": "object",
              "properties": {
                "query_or_url": {
                  "type": "string",
                  "description": "Açılacak URL ya da aranacak metin"
                }
              },
              "required": ["query_or_url"]
            }
          }
        },
      ];

  /// [messages] listesinin ilk elemanı 'system' rolündeki KurumiAI
  /// persona mesajını içermelidir (bkz. _bootstrap içindeki seed).
  static Future<Map<String, dynamic>> sendMessage({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    final response = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'messages': messages,
        'tools': tools,
        'tool_choice': 'auto',
        'temperature': 0.3,
        'max_completion_tokens': 1024,
        'parallel_tool_calls': true,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Groq API hatası (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
}

// =====================================================================
// ANDROID DERİN ERİŞİM ARAÇLARI (Tools)
// =====================================================================

class AndroidTools {
  static final Battery _battery = Battery();

  static const Map<String, String> _appPackages = {
    'whatsapp': 'com.whatsapp',
    'instagram': 'com.instagram.android',
    'youtube': 'com.google.android.youtube',
    'chrome': 'com.android.chrome',
    'gmail': 'com.google.android.gm',
    'e-posta': 'com.google.android.gm',
    'harita': 'com.google.android.apps.maps',
    'haritalar': 'com.google.android.apps.maps',
    'google haritalar': 'com.google.android.apps.maps',
    'spotify': 'com.spotify.music',
    'twitter': 'com.twitter.android',
    'x': 'com.twitter.android',
    'facebook': 'com.facebook.katana',
    'tiktok': 'com.zhiliaoapp.musically',
    'telegram': 'org.telegram.messenger',
    'ayarlar': 'com.android.settings',
    'settings': 'com.android.settings',
    'play store': 'com.android.vending',
    'mağaza': 'com.android.vending',
    'galeri': 'com.google.android.apps.photos',
    'fotoğraflar': 'com.google.android.apps.photos',
    'netflix': 'com.netflix.mediaclient',
    'takvim': 'com.google.android.calendar',
    'calendar': 'com.google.android.calendar',
    'hesap makinesi': 'com.google.android.calculator',
    'calculator': 'com.google.android.calculator',
  };

  /// Verilen uygulama adını en yakın bilinen paket adına eşler.
  static String? _resolvePackage(String appName) {
    final key = appName.trim().toLowerCase();
    if (_appPackages.containsKey(key)) return _appPackages[key];
    for (final entry in _appPackages.entries) {
      if (key.contains(entry.key) || entry.key.contains(key)) {
        return entry.value;
      }
    }
    return null;
  }

  static Future<String> openApp(String appName) async {
    if (!Platform.isAndroid) {
      return jsonEncode({'status': 'error', 'message': 'Sadece Android desteklenir.'});
    }
    final package = _resolvePackage(appName) ?? appName.trim();
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        package: package,
        category: 'android.intent.category.LAUNCHER',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
      return jsonEncode({'status': 'ok', 'app': appName, 'package': package});
    } catch (e) {
      return jsonEncode({
        'status': 'error',
        'message': '$appName açılamadı. Yüklü olmayabilir. ($e)'
      });
    }
  }

  static Future<String> getBatteryStatus() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      String stateText;
      switch (state) {
        case BatteryState.charging:
          stateText = 'şarj oluyor';
          break;
        case BatteryState.full:
          stateText = 'tam dolu';
          break;
        case BatteryState.discharging:
          stateText = 'şarjda değil';
          break;
        case BatteryState.connectedNotCharging:
          stateText = 'bağlı ama şarj olmuyor';
          break;
        default:
          stateText = 'bilinmiyor';
      }
      return jsonEncode({'level': level, 'state': stateText});
    } catch (e) {
      return jsonEncode({'status': 'error', 'message': 'Pil bilgisi alınamadı: $e'});
    }
  }

  static Future<String> setAlarm(int hour, int minute, [String? label]) async {
    if (!Platform.isAndroid) {
      return jsonEncode({'status': 'error', 'message': 'Sadece Android desteklenir.'});
    }
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.HOUR': hour,
          'android.intent.extra.alarm.MINUTES': minute,
          'android.intent.extra.alarm.MESSAGE': label ?? 'KurumiAI Alarmı',
          'android.intent.extra.alarm.SKIP_UI': true,
        },
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
      return jsonEncode({'status': 'ok', 'hour': hour, 'minute': minute});
    } catch (e) {
      return jsonEncode({'status': 'error', 'message': 'Alarm kurulamadı: $e'});
    }
  }

  static Future<String> openUrl(String queryOrUrl) async {
    try {
      final target = queryOrUrl.trim();
      final looksLikeUrl = target.startsWith('http://') ||
          target.startsWith('https://') ||
          (target.contains('.') && !target.contains(' '));
      final uri = looksLikeUrl
          ? Uri.parse(target.startsWith('http') ? target : 'https://$target')
          : Uri.parse('https://www.google.com/search?q=${Uri.encodeComponent(target)}');
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return jsonEncode({'status': ok ? 'ok' : 'error', 'url': uri.toString()});
    } catch (e) {
      return jsonEncode({'status': 'error', 'message': 'Açılamadı: $e'});
    }
  }
}

// =====================================================================
// ANA EKRAN
// =====================================================================

enum KurumiState { idle, listening, thinking, speaking }

class KurumiHomePage extends StatefulWidget {
  const KurumiHomePage({super.key});

  @override
  State<KurumiHomePage> createState() => _KurumiHomePageState();
}

class _KurumiHomePageState extends State<KurumiHomePage>
    with TickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  KurumiState _state = KurumiState.idle;
  bool _speechAvailable = false;
  bool _voiceEnabled = true;
  String _liveWords = '';
  String? _apiKey;
  String _model = 'openai/gpt-oss-20b';
  bool _isBusy = false;

  final List<ChatMessage> _display = [];
  final List<Map<String, dynamic>> _apiHistory = [];

  rive.SMINumber? _levelInput;
  rive.SMIBool? _activeInput;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _apiKey = await SettingsService.getApiKey();
    _model = await SettingsService.getModel();
    _voiceEnabled = await SettingsService.getVoiceEnabled();
    // Groq (OpenAI-uyumlu) API'de sistem mesajı, ayrı bir parametre değil,
    // messages listesinin ilk elemanıdır — bir kere burada ekleniyor.
    _apiHistory.add({'role': 'system', 'content': GroqService.systemPrompt});
    await _initTts();
    await _initSpeech();
    if (!mounted) return;
    setState(() {
      _display.add(ChatMessage(
        role: ChatRole.assistant,
        text:
            'Merhaba, ben KurumiAI. Çekirdeğime dokunup konuşabilir ya da aşağıya yazabilirsin.',
      ));
    });
    if (_apiKey == null || _apiKey!.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings());
    }
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('tr-TR');
    await _tts.setSpeechRate(0.48);
    await _tts.setPitch(1.05);
    _tts.setStartHandler(() {
      if (mounted) setState(() => _state = KurumiState.speaking);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _state = KurumiState.idle);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _state = KurumiState.idle);
    });
    _tts.setErrorHandler((msg) {
      if (mounted) setState(() => _state = KurumiState.idle);
    });
  }

  Future<void> _initSpeech() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _speechAvailable = false;
      return;
    }
    _speechAvailable = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (e) {
        if (mounted) setState(() => _state = KurumiState.idle);
      },
    );
    if (mounted) setState(() {});
  }

  void _onSpeechStatus(String status) {
    if (status == 'notListening' || status == 'done') {
      if (_state == KurumiState.listening) {
        setState(() => _state = KurumiState.idle);
        _activeInput?.value = false;
        final words = _liveWords.trim();
        _liveWords = '';
        if (words.isNotEmpty) {
          _handleUserText(words);
        }
      }
    }
  }

  void _onRiveInit(rive.Artboard artboard) {
    // vehicles.riv dosyasında bir State Machine varsa onu genel biçimde
    // bağlıyoruz; yoksa da hata vermeden geçiyoruz — çekirdek etrafındaki
    // neon glow zaten dokunma/ses tepkisini sağlıyor.
    if (artboard.stateMachines.isEmpty) return;
    final smName = artboard.stateMachines.first.name;
    final controller = rive.StateMachineController.fromArtboard(artboard, smName);
    if (controller == null) return;
    artboard.addController(controller);
    for (final input in controller.inputs) {
      if (input is rive.SMINumber && _levelInput == null) {
        _levelInput = input;
      }
      if (input is rive.SMIBool && _activeInput == null) {
        _activeInput = input;
      }
    }
  }

  Future<void> _toggleListening() async {
    if (_isBusy) return;

    if (_state == KurumiState.listening) {
      await _speech.stop();
      setState(() => _state = KurumiState.idle);
      _activeInput?.value = false;
      return;
    }

    if (_state == KurumiState.speaking) {
      await _tts.stop();
    }

    if (!_speechAvailable) {
      await _initSpeech();
      if (!_speechAvailable) {
        _showSnack('Mikrofon izni verilmedi.');
        return;
      }
    }

    setState(() {
      _state = KurumiState.listening;
      _liveWords = '';
    });
    _activeInput?.value = true;

    await _speech.listen(
      localeId: 'tr_TR',
      onResult: (SpeechRecognitionResult r) {
        setState(() => _liveWords = r.recognizedWords);
        if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
          _speech.stop();
        }
      },
      onSoundLevelChange: (level) {
        final normalized = (level / 10).clamp(0.0, 1.0).toDouble();
        _levelInput?.value = normalized * 100;
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  Future<void> _handleUserText(String text) async {
    if (text.trim().isEmpty) return;
    if (_apiKey == null || _apiKey!.isEmpty) {
      _showSnack('Önce ayarlardan Groq API anahtarını gir.');
      _openSettings();
      return;
    }

    setState(() {
      _display.add(ChatMessage(role: ChatRole.user, text: text));
      _apiHistory.add({'role': 'user', 'content': text});
      _state = KurumiState.thinking;
      _isBusy = true;
    });
    _scrollToEnd();

    try {
      final reply = await _runConversationTurn();
      if (!mounted) return;
      setState(() {
        _display.add(ChatMessage(role: ChatRole.assistant, text: reply));
      });
      _scrollToEnd();
      if (_voiceEnabled && reply.trim().isNotEmpty) {
        setState(() => _state = KurumiState.speaking);
        await _tts.speak(reply);
      } else {
        setState(() => _state = KurumiState.idle);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _display.add(ChatMessage(
          role: ChatRole.assistant,
          text: 'Bir hata oluştu: $e',
        ));
        _state = KurumiState.idle;
      });
      _scrollToEnd();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Groq ile tur(lar) çalıştırır: model bir araç çağırırsa (tool_calls)
  /// aracı yerel olarak çalıştırır, sonucu "tool" rolüyle API'ye geri
  /// gönderir ve nihai metin cevabını döndürür. Format OpenAI ile
  /// birebir uyumludur (choices[0].message.tool_calls).
  Future<String> _runConversationTurn() async {
    final buffer = StringBuffer();

    for (int turn = 0; turn < 5; turn++) {
      final data = await GroqService.sendMessage(
        apiKey: _apiKey!,
        model: _model,
        messages: _apiHistory,
      );

      final choices = data['choices'] as List;
      final message = Map<String, dynamic>.from(choices.first['message'] as Map);
      final content = message['content'];
      final toolCallsRaw = message['tool_calls'] as List?;

      final assistantMsg = <String, dynamic>{'role': 'assistant', 'content': content};
      if (toolCallsRaw != null) assistantMsg['tool_calls'] = toolCallsRaw;
      _apiHistory.add(assistantMsg);

      if (content is String && content.trim().isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(content);
      }

      if (toolCallsRaw == null || toolCallsRaw.isEmpty) break;

      for (final raw in toolCallsRaw) {
        final call = Map<String, dynamic>.from(raw as Map);
        final fn = Map<String, dynamic>.from(call['function'] as Map);
        final name = fn['name'] as String;
        final argsStr = fn['arguments'] as String? ?? '{}';
        Map<String, dynamic> input;
        try {
          input = Map<String, dynamic>.from(jsonDecode(argsStr) as Map);
        } catch (_) {
          input = {};
        }
        final id = call['id'] as String;

        if (mounted) {
          setState(() {
            _display.add(ChatMessage(role: ChatRole.system, text: _toolLabel(name, input)));
          });
          _scrollToEnd();
        }

        final result = await _executeTool(name, input);
        // OpenAI-uyumlu formatta her araç sonucu kendi "tool" mesajı
        // olarak, ilgili tool_call_id ile eşleşecek şekilde eklenir.
        _apiHistory.add({'role': 'tool', 'tool_call_id': id, 'content': result});
      }
    }

    final text = buffer.toString().trim();
    return text.isEmpty ? 'Hallettim.' : text;
  }

  String _toolLabel(String name, Map<String, dynamic> input) {
    switch (name) {
      case 'open_app':
        return '🔧 Açılıyor: ${input['app_name']}';
      case 'get_battery_status':
        return '🔋 Pil durumu kontrol ediliyor';
      case 'set_alarm':
        final h = input['hour'];
        final m = (input['minute'] as num?)?.toInt().toString().padLeft(2, '0') ?? '00';
        return '⏰ Alarm kuruluyor: $h:$m';
      case 'open_url':
        return '🌐 Açılıyor: ${input['query_or_url']}';
      default:
        return '🔧 $name çalıştırılıyor';
    }
  }

  Future<String> _executeTool(String name, Map<String, dynamic> input) async {
    switch (name) {
      case 'open_app':
        return AndroidTools.openApp((input['app_name'] ?? '').toString());
      case 'get_battery_status':
        return AndroidTools.getBatteryStatus();
      case 'set_alarm':
        final hour = (input['hour'] as num?)?.toInt() ?? 0;
        final minute = (input['minute'] as num?)?.toInt() ?? 0;
        final label = input['label']?.toString();
        return AndroidTools.setAlarm(hour, minute, label);
      case 'open_url':
        return AndroidTools.openUrl((input['query_or_url'] ?? '').toString());
      default:
        return jsonEncode({'status': 'error', 'message': 'Bilinmeyen araç: $name'});
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 140,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFF161B22)),
    );
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SettingsSheet(
        initialKey: _apiKey ?? '',
        initialModel: _model,
        initialVoice: _voiceEnabled,
        onSave: (key, model, voice) async {
          await SettingsService.setApiKey(key);
          await SettingsService.setModel(model);
          await SettingsService.setVoiceEnabled(voice);
          if (mounted) {
            setState(() {
              _apiKey = key;
              _model = model;
              _voiceEnabled = voice;
            });
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _textController.dispose();
    _scrollController.dispose();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  Color _glowColorForState() {
    switch (_state) {
      case KurumiState.listening:
        return KColors.neonCyan;
      case KurumiState.thinking:
        return KColors.neonBlue;
      case KurumiState.speaking:
        return KColors.neonGreen;
      case KurumiState.idle:
        return KColors.neonCyan.withOpacity(0.6);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KColors.bgTop,
      body: Stack(
        children: [
          _buildBackground(),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                const SizedBox(height: 10),
                _buildCore(),
                const SizedBox(height: 14),
                _buildStatusLabel(),
                const SizedBox(height: 8),
                Expanded(child: _buildTranscriptList()),
                _buildInputBar(),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- UI Parçaları ----------------

  Widget _buildBackground() {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [KColors.bgTop, Color(0xFF0A0E14), Color(0xFF07090C)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -90,
              left: -70,
              child: _glowBlob(KColors.neonCyan.withOpacity(0.16), 260),
            ),
            Positioned(
              bottom: -110,
              right: -70,
              child: _glowBlob(KColors.neonBlue.withOpacity(0.14), 300),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glowBlob(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color, blurRadius: 160, spreadRadius: 40)],
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fadeIn(duration: 1800.ms)
        .scaleXY(begin: 0.9, end: 1.05, duration: 3800.ms, curve: Curves.easeInOut);
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 0),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [KColors.neonCyan, KColors.neonBlue],
            ).createShader(bounds),
            child: Text(
              'KurumiAI',
              style: GoogleFonts.orbitron(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 1.1,
              ),
            ),
          ),
          const Spacer(),
          _iconGlassButton(
            icon: _voiceEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            onTap: () async {
              final v = !_voiceEnabled;
              setState(() => _voiceEnabled = v);
              await SettingsService.setVoiceEnabled(v);
              if (!v) _tts.stop();
            },
          ),
          const SizedBox(width: 10),
          _iconGlassButton(icon: Icons.tune_rounded, onTap: _openSettings),
        ],
      ),
    );
  }

  Widget _iconGlassButton({required IconData icon, required VoidCallback onTap}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Material(
          color: KColors.glassFill,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: KColors.glassBorder),
              ),
              child: Icon(icon, color: KColors.textPrimary, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCore() {
    final active = _state != KurumiState.idle;
    final glow = _glowColorForState();

    return Center(
      child: GestureDetector(
        onTap: _toggleListening,
        child: AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (context, child) {
            final pulse = active ? _pulseCtrl.value : 0.0;
            final scale = 1.0 + (pulse * 0.05);
            final spread1 = 6 + pulse * 16;
            final spread2 = 10 + pulse * 30;
            return Transform.scale(
              scale: scale,
              child: Container(
                width: 208,
                height: 208,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: glow.withOpacity(0.75), width: 1.6),
                  boxShadow: [
                    BoxShadow(color: glow.withOpacity(0.55), blurRadius: 46, spreadRadius: spread1),
                    BoxShadow(color: glow.withOpacity(0.22), blurRadius: 90, spreadRadius: spread2),
                  ],
                ),
                child: child,
              ),
            );
          },
          child: ClipOval(
            child: rive.RiveAnimation.network(
              'https://cdn.rive.app/animations/vehicles.riv',
              fit: BoxFit.cover,
              onInit: _onRiveInit,
              placeHolder: Container(
                color: const Color(0xFF0B0F14),
                child: const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2, color: KColors.neonCyan),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusLabel() {
    String label;
    switch (_state) {
      case KurumiState.listening:
        label = _liveWords.isEmpty ? 'Dinliyorum...' : _liveWords;
        break;
      case KurumiState.thinking:
        label = 'Düşünüyorum...';
        break;
      case KurumiState.speaking:
        label = 'Konuşuyorum...';
        break;
      case KurumiState.idle:
        label = 'Çekirdeğe dokun ve konuş';
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.rajdhani(
          color: KColors.textSecondary,
          fontSize: 15,
          letterSpacing: 0.4,
        ),
      ).animate(key: ValueKey(label)).fadeIn(duration: 250.ms),
    );
  }

  Widget _buildTranscriptList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      itemCount: _display.length,
      itemBuilder: (context, index) {
        final msg = _display[index];
        return _ChatBubble(message: msg)
            .animate()
            .fadeIn(duration: 260.ms)
            .slideY(begin: 0.08, end: 0, duration: 260.ms, curve: Curves.easeOut);
      },
    );
  }

  Widget _buildInputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: KColors.glassFill,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: KColors.glassBorder),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    _state == KurumiState.listening ? Icons.mic : Icons.mic_none_rounded,
                    color: _state == KurumiState.listening
                        ? KColors.neonCyan
                        : KColors.textSecondary,
                  ),
                  onPressed: _toggleListening,
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    style: GoogleFonts.rajdhani(color: KColors.textPrimary, fontSize: 15.5),
                    decoration: InputDecoration(
                      hintText: "KurumiAI'ye yaz...",
                      hintStyle: GoogleFonts.rajdhani(color: KColors.textSecondary),
                      border: InputBorder.none,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (v) {
                      _textController.clear();
                      _handleUserText(v);
                    },
                  ),
                ),
                _isBusy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: KColors.neonCyan),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.send_rounded, color: KColors.neonCyan),
                        onPressed: () {
                          final v = _textController.text;
                          _textController.clear();
                          _handleUserText(v);
                        },
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// SOHBET BALONU
// =====================================================================

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final isSystem = message.role == ChatRole.system;

    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: KColors.glassFill,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: KColors.glassBorder),
            ),
            child: Text(
              message.text,
              style: GoogleFonts.rajdhani(color: KColors.textSecondary, fontSize: 12.5),
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: isUser
                    ? LinearGradient(colors: [
                        KColors.neonBlue.withOpacity(0.28),
                        KColors.neonCyan.withOpacity(0.14),
                      ])
                    : null,
                color: isUser ? null : KColors.glassFill,
                border: Border.all(
                  color: isUser ? KColors.neonCyan.withOpacity(0.35) : KColors.glassBorder,
                ),
              ),
              child: Text(
                message.text,
                style: GoogleFonts.rajdhani(
                  color: KColors.textPrimary,
                  fontSize: 15.5,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// AYARLAR PANELİ (Glassmorphism bottom sheet)
// =====================================================================

class SettingsSheet extends StatefulWidget {
  final String initialKey;
  final String initialModel;
  final bool initialVoice;
  final Future<void> Function(String key, String model, bool voice) onSave;

  const SettingsSheet({
    super.key,
    required this.initialKey,
    required this.initialModel,
    required this.initialVoice,
    required this.onSave,
  });

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final TextEditingController _keyCtrl = TextEditingController(text: widget.initialKey);
  late String _model = widget.initialModel;
  late bool _voice = widget.initialVoice;
  bool _obscure = true;

  static const Map<String, String> _models = {
    'openai/gpt-oss-20b': 'GPT-OSS 20B (en hızlı)',
    'openai/gpt-oss-120b': 'GPT-OSS 120B (daha güçlü)',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
            decoration: BoxDecoration(
              color: const Color(0xE60B0F14),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: KColors.glassBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: KColors.glassBorder,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'KurumiAI Ayarları',
                  style: GoogleFonts.orbitron(
                      color: KColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 18),
                Text('Groq API Anahtarı',
                    style: GoogleFonts.rajdhani(color: KColors.textSecondary)),
                const SizedBox(height: 6),
                TextField(
                  controller: _keyCtrl,
                  obscureText: _obscure,
                  style: GoogleFonts.robotoMono(color: KColors.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'gsk_...',
                    hintStyle: const TextStyle(color: KColors.textSecondary),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: KColors.glassBorder),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        color: KColors.textSecondary,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Model', style: GoogleFonts.rajdhani(color: KColors.textSecondary)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: KColors.glassBorder),
                    color: Colors.white.withOpacity(0.04),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _model,
                      dropdownColor: const Color(0xFF10151C),
                      isExpanded: true,
                      style: GoogleFonts.rajdhani(color: KColors.textPrimary),
                      items: _models.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: (v) => setState(() => _model = v ?? _model),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: KColors.neonCyan,
                  title: Text('Sesli yanıt', style: GoogleFonts.rajdhani(color: KColors.textPrimary)),
                  value: _voice,
                  onChanged: (v) => setState(() => _voice = v),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KColors.neonCyan,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () async {
                      await widget.onSave(_keyCtrl.text.trim(), _model, _voice);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: Text('Kaydet', style: GoogleFonts.orbitron(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
