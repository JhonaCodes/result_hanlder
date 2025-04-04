import 'dart:convert';
import 'dart:developer';

import 'package:result_controller/src/result_controller.dart';

import 'api_err_handler.dart';
import 'api_response_handler.dart';

/// ApiResult: A specialized Result type for HTTP API operations
///
/// Provides an elegant way to handle API responses following a functional pattern.
/// Encapsulates both success and error cases in a single type, making error
/// handling easier without relying on exceptions.
///
/// Basic example:
/// ```dart
/// // Create a successful result
/// final success = ApiResult.ok(User(id: '123', name: 'John'));
///
/// // Create an error result
/// final failure = ApiResult.err(
///   ApiErr(
///     statusCode: 404,
///     message: HttpMessage(
///       success: false,
///       title: 'Not Found',
///       details: 'The requested user does not exist'
///     )
///   )
/// );
///
/// // Process the result with when()
/// success.when(
///   ok: (user) => print('User found: ${user.name}'),
///   err: (error) => print('Error: ${error.message?.details}')
/// );
/// ```
class ApiResult<T> extends Result<T, ApiErr> {
  final T? _data;
  final ApiErr? _error;
  final bool _isOk;

  /// Private constructor used internally by factories
  ApiResult._internal(this._data, this._error, this._isOk);

  /// Creates a successful API result
  ///
  /// Use this constructor when you have successfully retrieved and processed data
  /// from an API call.
  ///
  /// Example:
  /// ```dart
  /// final user = User.fromJson(userData);
  /// return ApiResult.ok(user);
  /// ```
  factory ApiResult.ok(T data) {
    return ApiResult._internal(data, null, true);
  }

  /// Creates an API result with an error
  ///
  /// Use this constructor when an API call has failed or when data processing
  /// encounters an error.
  ///
  /// Example:
  /// ```dart
  /// return ApiResult.err(
  ///   ApiErr(
  ///     statusCode: 500,
  ///     message: HttpMessage(
  ///       success: false,
  ///       title: 'Server Error',
  ///       details: 'An unexpected error occurred'
  ///     )
  ///   )
  /// );
  /// ```
  factory ApiResult.err(ApiErr error) {
    return ApiResult._internal(null, error, false);
  }

  /// Processes this result by applying the appropriate function
  ///
  /// This method allows you to handle both success and error cases with a single call.
  /// The appropriate function will be called based on whether this result is a success or failure.
  ///
  /// Example:
  /// ```dart
  /// final displayName = userResult.when(
  ///   ok: (user) => '${user.firstName} ${user.lastName}',
  ///   err: (error) => 'Unknown User'
  /// );
  /// ```
  @override
  R when<R>({required R Function(T) ok, required R Function(ApiErr) err}) {
    return _isOk ? ok(_data as T) : err(_error as ApiErr);
  }

  /// Transforms the success value while preserving the Result structure
  ///
  /// Use this method to transform data inside a successful result without
  /// handling error cases. If this result is an error, the error is preserved.
  ///
  /// Example:
  /// ```dart
  /// final userResult = ApiResult.ok(User(name: 'John', age: 30));
  /// final nameResult = userResult.map((user) => user.name);
  /// // nameResult is ApiResult<String>.ok('John')
  /// ```
  @override
  Result<R, ApiErr> map<R>(
    R Function(T value) transform, [
    ApiErr Function(ApiErr error)? errorTransform,
  ]) {
    if (_isOk) {
      return ApiResult<R>.ok(transform(_data as T));
    } else {
      final error = _error as ApiErr;
      return ApiResult<R>.err(
        errorTransform != null ? errorTransform(error) : error,
      );
    }
  }

  /// Chains another Result-returning operation based on a successful value
  ///
  /// This method is useful for sequential operations that might fail at any step.
  /// If this result is a success, the transform function is applied. If this result
  /// is an error, the error is preserved (or transformed if errorTransform is provided).
  ///
  /// Example:
  /// ```dart
  /// Future<ApiResult<User>> fetchUser(String id) async { /* ... */ }
  /// Future<ApiResult<List<Post>>> fetchUserPosts(User user) async { /* ... */ }
  ///
  /// // Chain operations
  /// final postsResult = await fetchUser('123').flatMap((user) => fetchUserPosts(user));
  /// ```
  @override
  Result<R, ApiErr> flatMap<R>(
    Result<R, ApiErr> Function(T value) transform, [
    Result<R, ApiErr> Function(ApiErr error)? errorTransform,
  ]) {
    if (_isOk) {
      return transform(_data as T);
    } else {
      final error = _error as ApiErr;
      return errorTransform != null
          ? errorTransform(error)
          : ApiResult<R>.err(error);
    }
  }

  /// Creates an ApiResult from a raw API response
  ///
  /// This static method processes an ApiResponse and converts it to an ApiResult,
  /// handling potential errors and data conversion.
  ///
  /// Parameters:
  /// - `response`: The API response to process
  /// - `onData`: A function that converts a JSON map to your domain object
  ///
  /// Example:
  /// ```dart
  /// ApiResponse response = await _api.get(
  ///   params: Params(path: 'users/123'),
  /// );
  ///
  /// ApiResult<User> result = ApiResult.from(
  ///   response: response,
  ///   onData: (data) => User.fromJson(data),
  /// );
  ///
  /// return result.when(
  ///   ok: (user) => user,
  ///   err: (error) => throw error, // Or handle differently
  /// );
  /// ```
  static ApiResult<T> from<T>({
    required ApiResponse response,
    required T Function(Map<String, dynamic> data) onData,
  }) {
    try {
      if (response.error != null) {
        return ApiResult.err(ApiErr.fromHttpError(response.error!));
      }

      if (response.data == null) {
        return ApiResult.err(
          ApiErr(
            exception: Exception('No data in response'),
            statusCode: response.statusCode,
            stackTrace: StackTrace.current,
          ),
        );
      }

      final jsonData = _ensureJsonMap(response.data);
      final result = onData(jsonData);
      return ApiResult.ok(result);
    } catch (e, stackTrace) {
      log('Error parsing API response ${e.toString()}');
      log(stackTrace.toString());

      if (e is ApiErr) {
        return ApiResult.err(e);
      }

      return ApiResult.err(
        ApiErr(
          exception: e,
          message: HttpMessage(
            success: false,
            title: 'Data Processing Error',
            details: 'Could not process the server response: ${e.toString()}',
          ),
          statusCode: response.statusCode,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// Creates an ApiResult from an API response containing a list
  ///
  /// Similar to `from()`, but specifically designed for handling responses that
  /// contain a list of items that need to be converted to domain objects.
  ///
  /// Parameters:
  /// - `response`: The API response to process
  /// - `onData`: A function that converts a list of JSON maps to your domain objects
  ///
  /// Example:
  /// ```dart
  /// ApiResponse response = await _api.get(
  ///   params: Params(path: 'users'),
  /// );
  ///
  /// ApiResult<List<User>> result = ApiResult.fromList(
  ///   response: response,
  ///   onData: (items) => items.map((item) => User.fromJson(item)).toList(),
  /// );
  ///
  /// return result.when(
  ///   ok: (users) => users,
  ///   err: (error) {
  ///     log('Error fetching users: $error');
  ///     return []; // Return empty list on error
  ///   },
  /// );
  /// ```
  static ApiResult<List<T>> fromList<T>({
    required ApiResponse response,
    required List<T> Function(List<Map<String, dynamic>> data) onData,
  }) {
    try {
      if (response.error != null) {
        return ApiResult.err(ApiErr.fromHttpError(response.error!));
      }

      if (response.data == null) {
        return ApiResult.err(
          ApiErr(
            exception: Exception('No data in response'),
            statusCode: response.statusCode,
            stackTrace: StackTrace.current,
          ),
        );
      }

      final jsonList = _ensureJsonList(response.data);
      final result = onData(jsonList);
      return ApiResult.ok(result);
    } catch (e, stackTrace) {
      log('Error parsing API response list ${e.toString()}');
      log(stackTrace.toString());

      if (e is ApiErr) {
        return ApiResult.err(e);
      }

      return ApiResult.err(
        ApiErr(
          exception: e,
          message: HttpMessage(
            success: false,
            title: 'Data Processing Error',
            details:
                'Could not process the server response list: ${e.toString()}',
          ),
          statusCode: response.statusCode,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// Utility method to ensure valid JSON map structures
  ///
  /// Handles different input types (Map or String) and converts them to a
  /// standard [Map<String, dynamic>] format for consistent processing.
  static Map<String, dynamic> _ensureJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }

    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (e) {
        throw FormatException('Invalid JSON string: ${e.toString()}');
      }
    }

    throw FormatException(
      'Expected Map or JSON string, got ${data.runtimeType}',
    );
  }

  /// Utility method to ensure valid JSON list structures
  ///
  /// Handles different input types (List or String) and converts them to a
  /// standard [List<Map<String, dynamic>>] format for consistent processing.
  static List<Map<String, dynamic>> _ensureJsonList(dynamic data) {
    if (data is List<Map<String, dynamic>>) {
      return data;
    }

    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is List) {
          return List<Map<String, dynamic>>.from(
            decoded.map((item) {
              if (item is! Map) {
                throw FormatException('List item is not a Map: $item');
              }
              return Map<String, dynamic>.from(item);
            }),
          );
        }
      } catch (e) {
        throw FormatException('Invalid JSON string: ${e.toString()}');
      }
    }

    throw FormatException(
      'Expected List or JSON string, got ${data.runtimeType}',
    );
  }
}

/// HTTP parameters for API requests
///
/// This class encapsulates all the data needed to make an HTTP request to an API endpoint.
/// It provides a structured way to define the endpoint path, request headers, and body.
///
/// Example:
/// ```dart
/// // Simple GET request parameters
/// final getParams = Params(
///   path: 'users/123',
///   header: {'Authorization': 'Bearer $token'}
/// );
///
/// // POST request with JSON body
/// final postParams = Params(
///   path: 'articles',
///   body: {
///     'title': 'New Article',
///     'content': 'Article content...',
///     'published': true
///   },
///   header: {
///     'Content-Type': 'application/json',
///     'Authorization': 'Bearer $token'
///   }
/// );
/// ```
class Params {
  /// The endpoint path (relative URL path after the base URL)
  final String path;

  /// Optional HTTP headers for the request
  ///
  /// Common headers include:
  /// - 'Content-Type': 'application/json'
  /// - 'Authorization': 'Bearer $token'
  final Map<String, String>? header;

  /// Optional body data for the request (used in POST, PUT, PATCH)
  ///
  /// For JSON requests, this will be automatically serialized to JSON.
  /// For form data, you can provide key-value pairs.
  final Map<String, dynamic>? body;

  /// Creates a new set of API request parameters
  ///
  /// The [path] parameter is required and defines the endpoint URL path.
  /// Optional [body] and [header] can be provided for request data and headers.
  Params({required this.path, this.body, this.header});
}

/// User-friendly HTTP error message
///
/// This class provides a standardized structure for API response messages,
/// especially useful for displaying user-friendly error information.
///
/// Example:
/// ```dart
/// // Create a success message
/// final successMsg = HttpMessage(
///   success: true,
///   title: 'Profile Updated',
///   details: 'Your profile has been successfully updated.'
/// );
///
/// // Create an error message
/// final errorMsg = HttpMessage(
///   success: false,
///   title: 'Connection Error',
///   details: 'Unable to connect to the server. Please check your internet connection.'
/// );
///
/// // Display the message to the user
/// showDialog(
///   context: context,
///   builder: (context) => AlertDialog(
///     title: Text(errorMsg.title),
///     content: Text(errorMsg.details),
///     actions: [
///       TextButton(
///         onPressed: () => Navigator.pop(context),
///         child: Text('OK')
///       )
///     ]
///   )
/// );
/// ```
class HttpMessage {
  /// Indicates whether the operation was successful
  final bool success;

  /// Message title
  ///
  /// This should be a short, descriptive title for the message.
  /// For errors, this might be the error type (e.g., "Network Error").
  /// For success, this could be a confirmation (e.g., "Payment Successful").
  final String title;

  /// Message content/details
  ///
  /// This contains the detailed message to display to the user.
  /// It should provide clear information about what happened and
  /// possible actions the user can take.
  final String details;

  /// Creates a new HTTP message
  ///
  /// The [title] and [details] are required.
  /// The [success] flag defaults to true, set it to false for error messages.
  HttpMessage({
    this.success = true,
    required this.title,
    required this.details,
  });

  /// Creates an HttpMessage from a JSON map
  ///
  /// This factory is useful for parsing message objects from API responses.
  /// It handles various field names that might be used in different API structures.
  ///
  /// Example:
  /// ```dart
  /// final responseData = jsonDecode(response.body);
  /// final message = HttpMessage.fromJson(responseData);
  /// ```
  factory HttpMessage.fromJson(Map<String, dynamic> json) {
    return HttpMessage(
      success: json['success'] ?? false,
      title: json['title'] ?? 'Error',
      details: json['content'] ?? json['message'] ?? 'Unknown error',
    );
  }

  /// Converts this message to a JSON map
  ///
  /// This is useful when you need to serialize a message for storage
  /// or to include in an API request.
  ///
  /// Example:
  /// ```dart
  /// final message = HttpMessage(
  ///   success: true,
  ///   title: 'Item Created',
  ///   details: 'The item was successfully created'
  /// );
  ///
  /// final jsonData = message.toJson();
  /// ```
  Map<String, dynamic> toJson() {
    return {'success': success, 'title': title, 'content': details};
  }

  /// Creates an HttpMessage from an exception
  ///
  /// This is a convenient way to convert an exception to a user-friendly message.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   // Some operation that might throw
  ///   await fetchData();
  /// } catch (e) {
  ///   final message = HttpMessage.fromException(e);
  ///   showErrorDialog(message.title, message.details);
  /// }
  /// ```
  factory HttpMessage.fromException(Object exception) {
    return HttpMessage(
      success: false,
      title: 'Error',
      details: exception.toString(),
    );
  }

  /// Creates an HttpMessage from an HttpError
  ///
  /// This factory extracts the message from an HttpError or creates a new one
  /// from the exception if no message is available.
  ///
  /// Example:
  /// ```dart
  /// final error = HttpError(
  ///   exception: Exception('Network timeout'),
  ///   stackTrace: StackTrace.current,
  /// );
  ///
  /// final message = HttpMessage.fromError(error);
  /// ```
  factory HttpMessage.fromError(HttpErr error) {
    return error.data ??
        HttpMessage.fromException(
          error.exception ?? Exception('Unknown error'),
        );
  }
}
