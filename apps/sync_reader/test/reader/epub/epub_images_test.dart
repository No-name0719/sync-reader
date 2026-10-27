/// resolveEpubImageDataUri 单元测试：相对 src → OPF 目录归一化 → data URI；
/// `../`、URL 编码、跨目录、外链/未命中的行为。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_images.dart';

final Uint8List _bytes = Uint8List.fromList(const [1, 2, 3, 4]);

Map<String, Uint8List> get _images => {'images/pic.png': _bytes};

Map<String, String> get _mimes => {'images/pic.png': 'image/png'};

void main() {
  group('命中与归一化', () {
    test('同目录相对 src → data URI（mime 取 manifest）', () {
      final uri = resolveEpubImageDataUri(
        src: 'images/pic.png',
        chapterHref: 'chapter1.xhtml',
        images: _images,
        imageMimes: _mimes,
      );
      expect(uri, 'data:image/png;base64,AQIDBA==');
    });

    test('`../` 相对路径与子目录章节', () {
      final uri = resolveEpubImageDataUri(
        src: '../images/pic.png',
        chapterHref: 'text/chapter1.xhtml',
        images: _images,
        imageMimes: _mimes,
      );
      expect(uri, isNotNull);
    });

    test('URL 编码 src（%20）与解码后的 zip 键匹配', () {
      final uri = resolveEpubImageDataUri(
        src: 'images/pic%2Epng',
        chapterHref: 'chapter1.xhtml',
        images: {'images/pic.png': _bytes},
        imageMimes: {'images/pic.png': 'image/png'},
      );
      expect(uri, isNotNull);
    });

    test('fragment 与 query 剥离', () {
      final uri = resolveEpubImageDataUri(
        src: 'images/pic.png#frag',
        chapterHref: 'chapter1.xhtml',
        images: _images,
        imageMimes: _mimes,
      );
      expect(uri, isNotNull);
    });

    test('mime 缺失按扩展名兜底', () {
      final uri = resolveEpubImageDataUri(
        src: 'images/pic.png',
        chapterHref: 'chapter1.xhtml',
        images: _images,
        imageMimes: const {},
      );
      expect(uri, startsWith('data:image/png;base64,'));
    });
  });

  group('保留原值', () {
    test('外链 http/https 返回 null（渲染层处理）', () {
      for (final src in ['http://a/b.png', 'https://a/b.png']) {
        expect(
          resolveEpubImageDataUri(
            src: src,
            chapterHref: 'c.xhtml',
            images: _images,
            imageMimes: _mimes,
          ),
          isNull,
        );
      }
    });

    test('已是 data URI 返回 null', () {
      expect(
        resolveEpubImageDataUri(
          src: 'data:image/png;base64,AQID',
          chapterHref: 'c.xhtml',
          images: _images,
          imageMimes: _mimes,
        ),
        isNull,
      );
    });

    test('未命中 zip 条目返回 null', () {
      expect(
        resolveEpubImageDataUri(
          src: 'images/missing.png',
          chapterHref: 'chapter1.xhtml',
          images: _images,
          imageMimes: _mimes,
        ),
        isNull,
      );
    });

    test('空 src 返回 null', () {
      expect(
        resolveEpubImageDataUri(
          src: '  ',
          chapterHref: 'c.xhtml',
          images: _images,
          imageMimes: _mimes,
        ),
        isNull,
      );
    });
  });

  test('EpubImagePath.normalize 折叠相对段', () {
    expect(EpubImagePath.normalize('a/./b/../c/'), 'a/c');
    expect(EpubImagePath.normalize(r'a\b.png'), 'a/b.png');
  });
}
