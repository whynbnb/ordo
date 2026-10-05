import '../i18n/i18n.dart';

/// 原生核心或服务层抛出的错误。
class OrdoException implements Exception {
  const OrdoException(this.message);

  final String message;

  @override
  String toString() => trError(message);
}
