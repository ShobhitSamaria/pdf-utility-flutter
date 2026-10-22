/// A language the translator can work with.
///
/// Modelled as an immutable **value object** rather than an `enum` so the set
/// of supported languages can grow without touching call sites, and so a
/// language detected at runtime (by on-device language identification) can be
/// represented even if it is not part of the curated list.
///
/// Identity is the [code] alone: two instances with the same BCP-47 tag are
/// interchangeable regardless of their display names, which keeps list
/// selections and map lookups reliable.
class TranslationLanguage {
  const TranslationLanguage({
    required this.code,
    required this.englishName,
    required this.nativeName,
  });

  /// BCP-47 language tag, e.g. `'en'`, `'hi'`, `'zh'`.
  final String code;

  /// English display name, e.g. `'Hindi'`.
  final String englishName;

  /// Name in the language itself, e.g. `'हिन्दी'`.
  final String nativeName;

  /// Sentinel code used by the synthetic auto-detect source option.
  static const String autoCode = 'auto';

  /// Whether this is the synthetic *auto-detect* source option rather than a
  /// concrete language.
  bool get isAuto => code == autoCode;

  /// Whether this is a real language (the opposite of [isAuto]).
  bool get isConcrete => !isAuto;

  /// Whether this language is written right to left.
  ///
  /// The overlay measures and paints translated text in the direction of the
  /// **target** language, so an Arabic, Persian, Urdu or Hebrew translation is
  /// shaped and aligned the way its readers expect instead of inheriting the
  /// app's left-to-right paragraph direction.
  bool get isRtl => rtlCodes.contains(code);

  /// BCP-47 tags written right to left. `iw` is the legacy tag for Hebrew that
  /// some engines still return.
  static const Set<String> rtlCodes = <String>{'ar', 'fa', 'ur', 'he', 'iw'};

  /// Human-readable label for selectors, e.g. `'हिन्दी (Hindi)'`.
  String get label {
    if (isAuto) return englishName;
    return nativeName == englishName
        ? englishName
        : '$nativeName ($englishName)';
  }

  @override
  bool operator ==(Object other) =>
      other is TranslationLanguage && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'TranslationLanguage($code)';
}

/// The curated set of languages this app exposes, plus the auto-detect sentinel.
///
/// Every entry maps to a language that Google ML Kit ships an on-device
/// translation model for (see `MlKitTranslationEngine`). Anything outside this
/// list is reported as an unsupported language rather than failing silently.
abstract final class TranslationLanguages {
  /// Source option meaning "work it out from the text".
  static const TranslationLanguage auto = TranslationLanguage(
    code: TranslationLanguage.autoCode,
    englishName: 'Auto-detect',
    nativeName: 'Auto',
  );

  static const TranslationLanguage english = TranslationLanguage(
    code: 'en',
    englishName: 'English',
    nativeName: 'English',
  );

  static const TranslationLanguage hindi = TranslationLanguage(
    code: 'hi',
    englishName: 'Hindi',
    nativeName: 'हिन्दी',
  );

  static const TranslationLanguage bengali = TranslationLanguage(
    code: 'bn',
    englishName: 'Bengali',
    nativeName: 'বাংলা',
  );

  static const TranslationLanguage gujarati = TranslationLanguage(
    code: 'gu',
    englishName: 'Gujarati',
    nativeName: 'ગુજરાતી',
  );

  static const TranslationLanguage kannada = TranslationLanguage(
    code: 'kn',
    englishName: 'Kannada',
    nativeName: 'ಕನ್ನಡ',
  );

  static const TranslationLanguage marathi = TranslationLanguage(
    code: 'mr',
    englishName: 'Marathi',
    nativeName: 'मराठी',
  );

  static const TranslationLanguage tamil = TranslationLanguage(
    code: 'ta',
    englishName: 'Tamil',
    nativeName: 'தமிழ்',
  );

  static const TranslationLanguage telugu = TranslationLanguage(
    code: 'te',
    englishName: 'Telugu',
    nativeName: 'తెలుగు',
  );

  static const TranslationLanguage urdu = TranslationLanguage(
    code: 'ur',
    englishName: 'Urdu',
    nativeName: 'اردو',
  );

  static const TranslationLanguage arabic = TranslationLanguage(
    code: 'ar',
    englishName: 'Arabic',
    nativeName: 'العربية',
  );

  static const TranslationLanguage persian = TranslationLanguage(
    code: 'fa',
    englishName: 'Persian',
    nativeName: 'فارسی',
  );

  static const TranslationLanguage hebrew = TranslationLanguage(
    code: 'he',
    englishName: 'Hebrew',
    nativeName: 'עברית',
  );

  static const TranslationLanguage chinese = TranslationLanguage(
    code: 'zh',
    englishName: 'Chinese',
    nativeName: '中文',
  );

  static const TranslationLanguage japanese = TranslationLanguage(
    code: 'ja',
    englishName: 'Japanese',
    nativeName: '日本語',
  );

  static const TranslationLanguage korean = TranslationLanguage(
    code: 'ko',
    englishName: 'Korean',
    nativeName: '한국어',
  );

  static const TranslationLanguage thai = TranslationLanguage(
    code: 'th',
    englishName: 'Thai',
    nativeName: 'ไทย',
  );

  static const TranslationLanguage vietnamese = TranslationLanguage(
    code: 'vi',
    englishName: 'Vietnamese',
    nativeName: 'Tiếng Việt',
  );

  static const TranslationLanguage indonesian = TranslationLanguage(
    code: 'id',
    englishName: 'Indonesian',
    nativeName: 'Bahasa Indonesia',
  );

  static const TranslationLanguage malay = TranslationLanguage(
    code: 'ms',
    englishName: 'Malay',
    nativeName: 'Bahasa Melayu',
  );

  static const TranslationLanguage dutch = TranslationLanguage(
    code: 'nl',
    englishName: 'Dutch',
    nativeName: 'Nederlands',
  );

  static const TranslationLanguage french = TranslationLanguage(
    code: 'fr',
    englishName: 'French',
    nativeName: 'Français',
  );

  static const TranslationLanguage german = TranslationLanguage(
    code: 'de',
    englishName: 'German',
    nativeName: 'Deutsch',
  );

  static const TranslationLanguage italian = TranslationLanguage(
    code: 'it',
    englishName: 'Italian',
    nativeName: 'Italiano',
  );

  static const TranslationLanguage portuguese = TranslationLanguage(
    code: 'pt',
    englishName: 'Portuguese',
    nativeName: 'Português',
  );

  static const TranslationLanguage polish = TranslationLanguage(
    code: 'pl',
    englishName: 'Polish',
    nativeName: 'Polski',
  );

  static const TranslationLanguage russian = TranslationLanguage(
    code: 'ru',
    englishName: 'Russian',
    nativeName: 'Русский',
  );

  static const TranslationLanguage spanish = TranslationLanguage(
    code: 'es',
    englishName: 'Spanish',
    nativeName: 'Español',
  );

  static const TranslationLanguage swahili = TranslationLanguage(
    code: 'sw',
    englishName: 'Swahili',
    nativeName: 'Kiswahili',
  );

  static const TranslationLanguage turkish = TranslationLanguage(
    code: 'tr',
    englishName: 'Turkish',
    nativeName: 'Türkçe',
  );

  static const TranslationLanguage ukrainian = TranslationLanguage(
    code: 'uk',
    englishName: 'Ukrainian',
    nativeName: 'Українська',
  );

  /// All concrete languages, in the order they are offered in the UI.
  static const List<TranslationLanguage> all = <TranslationLanguage>[
    english,
    hindi,
    bengali,
    gujarati,
    kannada,
    marathi,
    tamil,
    telugu,
    urdu,
    arabic,
    persian,
    hebrew,
    chinese,
    japanese,
    korean,
    thai,
    vietnamese,
    indonesian,
    malay,
    dutch,
    french,
    german,
    italian,
    portuguese,
    polish,
    russian,
    spanish,
    swahili,
    turkish,
    ukrainian,
  ];

  /// Source options: the auto-detect sentinel followed by every concrete
  /// language.
  static const List<TranslationLanguage> sources = <TranslationLanguage>[
    auto,
    ...all,
  ];

  /// Source language used by default (auto-detect).
  static const TranslationLanguage defaultSource = auto;

  /// Target language used by default (Hindi).
  static const TranslationLanguage defaultTarget = hindi;

  /// Tags returned by language identification that need normalising to our
  /// canonical codes (legacy / region- or script-qualified variants).
  static const Map<String, String> _aliases = <String, String>{
    'iw': 'he', // legacy Hebrew
    'in': 'id', // legacy Indonesian
    'zh-hans': 'zh',
    'zh-hant': 'zh',
    'zh-cn': 'zh',
    'zh-tw': 'zh',
    'zh-hk': 'zh',
    'fil': 'tl',
    'nb': 'no',
    'nn': 'no',
  };

  /// Resolves a BCP-47 tag (as produced by language identification) to a
  /// registry entry, or `null` when the language is not one we expose.
  ///
  /// Region/script suffixes are dropped (`'en-GB'` → English) and known legacy
  /// tags are normalised first.
  static TranslationLanguage? byCode(String code) {
    final normalized = code.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    if (normalized == TranslationLanguage.autoCode) return auto;

    final aliased = _aliases[normalized] ?? normalized;
    final base = aliased.split('-').first;
    final resolved = _aliases[base] ?? base;

    for (final language in all) {
      if (language.code == resolved) return language;
    }
    return null;
  }
}
