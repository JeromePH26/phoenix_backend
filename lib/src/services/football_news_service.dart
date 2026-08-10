import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../database/database.dart';
import 'firebase_push_service.dart';

class FootballNewsService {
  FootballNewsService({
    required this.database,
    required this.push,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final PhoenixDatabase database;
  final FirebasePushService push;
  final http.Client _client;
  Timer? _timer;
  DateTime? _lastRefresh;
  bool _refreshing = false;

  static const List<
      ({
        String name,
        String site,
        String feed,
        String? fixedLeagueId,
        String? fixedLeagueName,
        bool footballOnly,
      })> _sources = [
    (
      name: 'Quelle www.kicker.de',
      site: 'https://www.kicker.de',
      feed: 'https://newsfeed.kicker.de/news/aktuell',
      fixedLeagueId: null,
      fixedLeagueName: null,
      footballOnly: false,
    ),
    (
      name: 'Sportschau',
      site: 'https://www.sportschau.de',
      feed: 'https://www.sportschau.de/index~rss2.xml',
      fixedLeagueId: null,
      fixedLeagueName: null,
      footballOnly: false,
    ),
    (
      name: 'Tagesschau Sport',
      site: 'https://www.tagesschau.de/sport',
      feed: 'https://www.tagesschau.de/sport/index~rss2.xml',
      fixedLeagueId: null,
      fixedLeagueName: null,
      footballOnly: false,
    ),
    (
      name: '3. Liga Online',
      site: 'https://www.liga3-online.de',
      feed: 'https://www.liga3-online.de/feed/',
      fixedLeagueId: '80',
      fixedLeagueName: '3. Liga',
      footballOnly: true,
    ),
  ];

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(
        const Duration(minutes: 20), (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  Future<void> refreshIfStale() async {
    final last = _lastRefresh;
    if (last == null ||
        DateTime.now().difference(last) > const Duration(minutes: 15)) {
      await refresh();
    }
  }

  Future<void> refresh() async {
    if (_refreshing || !database.isConfigured) return;
    _refreshing = true;
    try {
      final entities = await database.footballNewsEntities();
      for (final source in _sources) {
        try {
          final response = await _client.get(
            Uri.parse(source.feed),
            headers: const {
              'user-agent': 'PHOENIX-News/1.0',
              'accept': 'application/rss+xml, application/xml'
            },
          );
          if (response.statusCode != 200) continue;
          final document = XmlDocument.parse(utf8.decode(response.bodyBytes));
          for (final item in document.findAllElements('item').take(80)) {
            final title = _text(item, 'title');
            final link = _text(item, 'link');
            if (title.isEmpty || link.isEmpty) continue;
            final summary = _clean(_text(item, 'description'));
            final haystack = '$title $summary'.toLowerCase();
            if (!source.footballOnly && !_isFootball(haystack)) continue;
            final published = _date(_text(item, 'pubDate'));
            if (published == null) continue;
            final age = DateTime.now().toUtc().difference(published);
            if (age.isNegative && age.abs() > const Duration(hours: 2)) {
              continue;
            }
            if (age > const Duration(days: 7)) continue;

            final teamIds = <String>[];
            final teamNames = <String>[];
            final leagueIds = <String>[
              if (source.fixedLeagueId != null) source.fixedLeagueId!,
            ];
            final leagueNames = <String>[
              if (source.fixedLeagueName != null) source.fixedLeagueName!,
            ];
            for (final entity in entities) {
              final name = entity['name']!;
              if (name.length < 4 || !haystack.contains(name.toLowerCase()))
                continue;
              if (entity['kind'] == 'team') {
                teamIds.add(entity['id']!);
                teamNames.add(name);
              } else {
                leagueIds.add(entity['id']!);
                leagueNames.add(name);
              }
            }
            // PHÖNIX-News gehören ausschließlich zu den freigegebenen Ligen.
            // Allgemeine WM-, Nationalmannschafts- und sonstige Fremdbeiträge
            // ohne Whitelist-Zuordnung werden nicht gespeichert.
            if (teamIds.isEmpty && leagueIds.isEmpty) continue;
            final category = _category(haystack);
            final importance = _importance(
              haystack: haystack,
              category: category,
              officialTeams: teamIds.isNotEmpty,
            );
            final article = <String, dynamic>{
              'id': sha256.convert(utf8.encode(link)).toString(),
              'sourceName': source.name,
              'sourceUrl': source.site,
              'articleUrl': link,
              'title': title,
              'summary': summary.length > 420
                  ? '${summary.substring(0, 417)}…'
                  : summary,
              'imageUrl': _image(item),
              'category': category,
              'importance': importance,
              'teamIds': teamIds.toSet().toList(),
              'teamNames': teamNames.toSet().toList(),
              'leagueIds': leagueIds.toSet().toList(),
              'leagueNames': leagueNames.toSet().toList(),
              'publishedAt': published,
            };
            final inserted = await database.upsertNewsArticle(article);
            if (inserted && importance >= 70 && push.isConfigured) {
              await _notifyFavorites(article);
            }
          }
        } catch (error) {
          stderr.writeln('[NEWS] ${source.name}: $error');
        }
      }
      _lastRefresh = DateTime.now();
    } finally {
      _refreshing = false;
    }
  }

  String _text(XmlElement item, String name) =>
      item.findElements(name).firstOrNull?.innerText.trim() ?? '';

  String _clean(String value) => value
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  DateTime? _date(String value) {
    try {
      return HttpDate.parse(value).toUtc();
    } catch (_) {
      return DateTime.tryParse(value)?.toUtc();
    }
  }

  String _image(XmlElement item) {
    for (final child in item.children.whereType<XmlElement>()) {
      final url = child.getAttribute('url') ?? '';
      final type = child.getAttribute('type') ?? '';
      if (url.startsWith('http') &&
          (type.startsWith('image/') || child.name.local == 'content'))
        return url;
    }
    return '';
  }

  bool _isFootball(String text) => const [
        'fußball',
        'bundesliga',
        'champions league',
        'europa league',
        'dfb',
        'premier league',
        'serie a',
        'la liga',
        'ligue 1',
        'conference league',
      ].any(text.contains);

  String _category(String text) {
    if (const ['verletzt', 'verletzung', 'fällt aus', 'ausfall']
        .any(text.contains)) return 'injury';
    if (const ['aufstellung', 'startelf', 'kader'].any(text.contains))
      return 'lineup';
    if (const ['trainer', 'entlassen', 'rücktritt'].any(text.contains))
      return 'coach';
    if (const ['transfer', 'wechselt', 'verpflichtet'].any(text.contains))
      return 'transfer';
    if (const ['abgesagt', 'verschoben', 'spielverlegung'].any(text.contains))
      return 'schedule';
    return 'general';
  }

  int _importance(
      {required String haystack,
      required String category,
      required bool officialTeams}) {
    var score = 42;
    if (officialTeams) score += 12;
    if (const {'injury', 'lineup', 'coach', 'schedule'}.contains(category))
      score += 22;
    if (const ['bestätigt', 'offiziell', 'fällt aus', 'entlassen']
        .any(haystack.contains)) score += 14;
    if (haystack.contains('gerücht') || haystack.contains('spekulation'))
      score -= 20;
    return score.clamp(0, 100);
  }

  Future<void> _notifyFavorites(Map<String, dynamic> article) async {
    final teamIds = (article['teamIds'] as List).cast<String>();
    final leagueIds = (article['leagueIds'] as List).cast<String>();
    if (teamIds.isEmpty && leagueIds.isEmpty) return;

    final targets = await database.newsPushTargets(
      teamIds: teamIds,
      leagueIds: leagueIds,
    );
    for (final target in targets) {
      final installationId = target['installationId'] as String;
      if (!await database.claimNewsPush(
        article['id'] as String,
        installationId,
      )) {
        continue;
      }
      try {
        await push.send(
          token: target['pushToken'] as String,
          title: 'PHÖNIX NEWS · Wichtig',
          body: article['title'] as String,
          androidChannelId: 'phoenix_news_v1',
          data: {
            'type': 'news',
            'articleId': article['id'] as String,
            'articleUrl': article['articleUrl'] as String,
          },
        );
      } catch (error) {
        stderr.writeln('[NEWS PUSH] $installationId: $error');
      }
    }
  }

  void close() {
    _timer?.cancel();
    _client.close();
  }
}
