import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:music_app/models.dart';
import 'package:music_app/ports.dart';

/// 按 store/server 鉴权契约访问文件与会话接口。
final class HttpStoreFiles implements StoreFiles {
  HttpStoreFiles({
    this.baseUrl = 'http://localhost:8080',
    http.Client? client,
  }) : client = client ?? http.Client();

  final String baseUrl;
  final http.Client client;

  @override
  Future<AuthTokens> register({
    required String username,
    required String password,
  }) {
    return _postTokens('/v1/auth/register', <String, String>{
      'username': username,
      'password': password,
    });
  }

  @override
  Future<AuthTokens> login({
    required String username,
    required String password,
  }) {
    return _postTokens('/v1/auth/login', <String, String>{
      'username': username,
      'password': password,
    });
  }

  @override
  Future<AuthTokens> refresh({required String refreshToken}) {
    return _postTokens(
      '/v1/auth/refresh',
      <String, String>{'refresh_token': refreshToken},
      fallbackRefresh: refreshToken,
    );
  }

  @override
  Future<void> logout({
    required String accessToken,
    String? refreshToken,
  }) async {
    await _postJson(
      '/v1/auth/logout',
      json: refreshToken == null
          ? null
          : <String, String>{'refresh_token': refreshToken},
      accessToken: accessToken,
    );
  }

  @override
  Future<AuthUser> me({required String accessToken}) async {
    final Map<String, dynamic> json = await _getJson(
      '/v1/auth/me',
      accessToken: accessToken,
    );
    return AuthUser.fromJson(json);
  }

  @override
  Future<StoreFile> uploadFile({
    required String accessToken,
    required String filename,
    required String contentType,
    required List<int> bytes,
  }) {
    if (bytes.length <= directUploadMaxBytes) {
      return _uploadDirect(
        accessToken: accessToken,
        filename: filename,
        contentType: contentType,
        bytes: bytes,
      );
    }
    return _uploadMultipart(
      accessToken: accessToken,
      filename: filename,
      contentType: contentType,
      bytes: bytes,
    );
  }

  @override
  Future<void> deleteFile({
    required String accessToken,
    required String fileId,
  }) {
    return _deletePath('/v1/files/$fileId', accessToken);
  }

  @override
  Future<List<StoreFile>> listFiles({
    required String accessToken,
    required String filename,
    int limit = 1,
  }) async {
    final http.Response response = await client.get(
      _uri('/v1/files', <String, String>{
        'filename': filename,
        'limit': '$limit',
      }),
      headers: _headers(accessToken: accessToken, hasBody: false),
    );
    if (response.statusCode == 404) {
      return const <StoreFile>[];
    }
    final Map<String, dynamic> json = _decodeSuccess(response);
    final Object? items = json['items'];
    if (items is! List) {
      return const <StoreFile>[];
    }
    return <StoreFile>[
      for (final Object? item in items)
        if (item is Map<String, dynamic>) StoreFile.fromJson(item),
    ];
  }

  @override
  Future<List<int>> downloadFile({
    required String accessToken,
    required String fileId,
  }) async {
    final String fileAccess = await issueFileAccessToken(
      accessToken: accessToken,
      fileId: fileId,
    );
    final http.Response response = await client.get(
      _uri('/v1/files/$fileId/content'),
      headers: <String, String>{
        'Accept': '*/*',
        'Authorization': 'Bearer $fileAccess',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _authError(response);
    }
    return response.bodyBytes;
  }

  @override
  Future<String> issueFileAccessToken({
    required String accessToken,
    required String fileId,
  }) async {
    final Map<String, dynamic> issued = await _postJson(
      '/v1/files/$fileId/access-token',
      accessToken: accessToken,
    );
    final Object? fileAccess = issued['access_token'];
    if (fileAccess is! String) {
      throw const FormatException('缺少 access_token');
    }
    return fileAccess;
  }

  @override
  String fileContentUrl(String fileId) => '$baseUrl/v1/files/$fileId/content';

  @override
  Future<List<int>> downloadRange({
    required String fileAccessToken,
    required String fileId,
    String range = 'bytes=0-',
  }) async {
    final http.Response response = await client.get(
      _uri('/v1/files/$fileId/content'),
      headers: <String, String>{
        'Accept': '*/*',
        'Authorization': 'Bearer $fileAccessToken',
        'Range': range,
      },
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw _authError(response);
    }
    return response.bodyBytes;
  }

  Future<StoreFile> _uploadDirect({
    required String accessToken,
    required String filename,
    required String contentType,
    required List<int> bytes,
  }) async {
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      _uri('/v1/files'),
    );
    request.headers['Accept'] = 'application/json';
    request.headers['Authorization'] = 'Bearer $accessToken';
    request.fields['content_type'] = contentType;
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );
    final http.StreamedResponse streamed = await client.send(request);
    final http.Response response = await http.Response.fromStream(streamed);
    return StoreFile.fromJson(_decodeSuccess(response));
  }

  Future<StoreFile> _uploadMultipart({
    required String accessToken,
    required String filename,
    required String contentType,
    required List<int> bytes,
  }) async {
    final Map<String, dynamic> initiated = await _postJson(
      '/v1/files/uploads',
      json: <String, Object>{
        'filename': filename,
        'content_type': contentType,
        'size_bytes': bytes.length,
      },
      accessToken: accessToken,
    );
    final Object? uploadId = initiated['upload_id'];
    final Object? partSize = initiated['part_size_bytes'];
    final Object? parts = initiated['parts'];
    if (uploadId is! String || partSize is! int || parts is! List) {
      throw const FormatException('分片上传响应字段缺失');
    }
    try {
      final List<Map<String, Object>> completed = <Map<String, Object>>[];
      for (final Object? part in parts) {
        if (part is! Map<String, dynamic>) {
          throw const FormatException('分片描述无效');
        }
        final Object? number = part['part_number'];
        final Object? url = part['upload_url'];
        if (number is! int || url is! String) {
          throw const FormatException('分片描述无效');
        }
        final int start = (number - 1) * partSize;
        final int end = start + partSize > bytes.length
            ? bytes.length
            : start + partSize;
        completed.add(<String, Object>{
          'part_number': number,
          'etag': await _putPart(url, bytes.sublist(start, end)),
        });
      }
      return StoreFile.fromJson(
        await _postJson(
          '/v1/files/uploads/$uploadId/complete',
          json: <String, Object>{'parts': completed},
          accessToken: accessToken,
        ),
      );
    } catch (_) {
      try {
        await _deletePath('/v1/files/uploads/$uploadId', accessToken);
      } catch (_) {
        // 中止未完成的分片上传。
      }
      rethrow;
    }
  }

  Future<String> _putPart(String url, List<int> chunk) async {
    final http.Response response = await client.put(
      Uri.parse(url),
      body: chunk,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const AuthException(code: 'STORE_REQUEST_FAILED', message: '请求失败');
    }
    return response.headers['etag'] ?? '';
  }

  Future<void> _deletePath(String path, String accessToken) async {
    final http.Response response = await client.delete(
      _uri(path),
      headers: _headers(accessToken: accessToken, hasBody: false),
    );
    _decodeSuccess(response);
  }

  Future<AuthTokens> _postTokens(
    String path,
    Map<String, String> json, {
    String? fallbackRefresh,
  }) async {
    final Map<String, dynamic> body = await _postJson(path, json: json);
    return AuthTokens.fromApi(body, fallbackRefresh: fallbackRefresh);
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    Object? json,
    String? accessToken,
  }) async {
    final http.Response response = await client.post(
      _uri(path),
      headers: _headers(accessToken: accessToken, hasBody: json != null),
      body: json == null ? null : jsonEncode(json),
    );
    return _decodeSuccess(response);
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    required String accessToken,
  }) async {
    final http.Response response = await client.get(
      _uri(path),
      headers: _headers(accessToken: accessToken, hasBody: false),
    );
    return _decodeSuccess(response);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final Uri uri = Uri.parse('$baseUrl$path');
    if (query == null) {
      return uri;
    }
    return uri.replace(queryParameters: query);
  }

  Map<String, String> _headers({
    required String? accessToken,
    required bool hasBody,
  }) {
    return <String, String>{
      'Accept': 'application/json',
      if (hasBody) 'Content-Type': 'application/json; charset=utf-8',
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    };
  }

  Map<String, dynamic> _decodeSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _authError(response);
    }
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    return _jsonObject(response.body);
  }
}

Map<String, dynamic> _jsonObject(String text) {
  final Object? decoded = jsonDecode(text);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  throw const FormatException('响应体不是 JSON 对象');
}

AuthException _authError(http.Response response) {
  try {
    final Map<String, dynamic> json = _jsonObject(response.body);
    final Object? error = json['error'];
    if (error is Map<String, dynamic>) {
      final Object? code = error['code'];
      final Object? message = error['message'];
      if (code is String) {
        return AuthException(
          code: code,
          message: message is String ? message : code,
        );
      }
    }
  } on FormatException {
    // 非 JSON 错误体时回落到通用失败。
  }
  return const AuthException(code: 'AUTH_REQUEST_FAILED', message: '请求失败');
}
