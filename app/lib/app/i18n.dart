import 'i18n_strings.dart';

/// App interface language (My page → 언어). Korean is the source text: every UI string is written in
/// Korean and doubles as its key, so a missing translation falls back to Korean.
class I18n {
  static String lang = 'ko';
}

/// Translates a UI string. Numbers and names go in [args] and replace `{0}`, `{1}`… in the template.
String tr(String ko, [List<Object?> args = const []]) {
  var s = I18n.lang == 'ko' ? ko : (uiStrings[I18n.lang]?[ko] ?? ko);
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}
