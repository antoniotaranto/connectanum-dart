
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:connectanum_dart/src/message/abstract_message.dart';
import 'package:connectanum_dart/src/serializer/abstract_serializer.dart';
import 'package:connectanum_dart/src/transport/socket/socket_helper.dart';
import 'package:logging/logging.dart';

import '../abstract_transport.dart';

class SocketTransport extends AbstractTransport {

  Logger _logger = new Logger("SocketTransport");

  bool _ssl;
  int _port;
  String _host;
  Socket _socket;
  int _messageLengthExponent;
  /**
   * this will be negotiated during the handshake process
   */
  int _messageLength;
  AbstractSerializer _serializer;
  int _serializerType;
  /**
   * will be set to true if a handshake was completed
   */
  Uint8List _inboundBuffer = new Uint8List(0);
  Uint8List _outboundBuffer = new Uint8List(0);

  Completer _handshakeCompleter;

  SocketTransport(
    this._host,
    this._port,
    this._serializer,
    this._serializerType,
    {ssl: false, messageLengthExponent: SocketHelper.MAX_MESSAGE_LENGTH_EXPONENT}
  ) : assert(_serializerType == SocketHelper.SERIALIZATION_JSON || _serializerType == SocketHelper.SERIALIZATION_MSGPACK) {
    _ssl = ssl;
    _messageLengthExponent = messageLengthExponent;
  }

  /**
   * Sends a handshake of the morphology
   */
  void _sendInitialHandshake() {
    _socket.add(SocketHelper.getInitialHandshake(_messageLengthExponent,_serializerType));
  }

  void _sendError(int errorCode) {
    _socket.add(SocketHelper.getError(errorCode));
    _socket.close();
  }

  bool get isUpgradedProtocol {
    return _messageLength != null && _messageLength > SocketHelper.MAX_MESSAGE_LENGTH;
  }

  int get headerLength {
    return isUpgradedProtocol?5:4;
  }

  int get maxMessageLength => _messageLength;

  @override
  Future<void> close() {
    return _socket.close();
  }

  @override
  bool get isOpen {
    // Dart does not provide a socket channel state
    // TODO fix when this issue is solved: https://github.com/dart-lang/web_socket_channel/issues/16
    return _socket != null && _handshakeCompleter.isCompleted && !onDisconnect.isCompleted;
  }

  Future get onOpen {
    return _handshakeCompleter.future;
  }

  @override
  Future<void> open() async {
    if (_ssl) {
      _socket = await SecureSocket.connect(_host, _port);
    } else {
      _socket = await Socket.connect(_host, _port);
    }
    onDisconnect = new Completer();
    _handshakeCompleter = new Completer();
    _sendInitialHandshake();
  }

  @override
  Stream<AbstractMessage> receive() {
    return _socket
      .where((List<int> message) {
        message = Uint8List.fromList(_inboundBuffer + message);
        if (_negotiateProtocol(message) || !_assertValidMessage(message)) {
          return false;
        }
        final int finalMessageLength = message.length - headerLength;
        final int payloadLength = SocketHelper.getPayloadLength(message,headerLength);
        if(finalMessageLength < payloadLength) {
          _inboundBuffer = message;
          return false;
        };
        if(finalMessageLength > _messageLength) {
          _sendError(SocketHelper.ERROR_MESSAGE_LENGTH_EXCEEDED);
          _logger.fine("Closed raw socket channel because the message length exceeded the max value of "+ _messageLength.toString());
          return false;
        }
        return true;
      })
      .map((Uint8List message) => _handleMessage(message))
      .where((message) => message != null);
  }

  bool _negotiateProtocol(Uint8List message) {
    if (_handshakeCompleter.isCompleted) return false;
    int errorNumber = SocketHelper.getErrorNumber(message);
    if(errorNumber == 0){
      // RECEIVED FIRST HANDSHAKE RESPONSE
      if(SocketHelper.isRawSocket(message)){
        int maxMessageSizeExponent = SocketHelper.getMaxMessageSizeExponent(message);
        // TRY UPGRADE TO 5 BYTE HEADER, IF WANTED
        if(maxMessageSizeExponent == SocketHelper.MAX_MESSAGE_LENGTH_EXPONENT && this._messageLengthExponent > SocketHelper.MAX_MESSAGE_LENGTH_EXPONENT){
          _logger.finer("Try to upgrade to 5 byte raw socket header");
          _socket.add(SocketHelper.getUpgradeHandshake(this._messageLengthExponent));
        } else {
          // AN UPGRADE WAS NOT WANTED SO SET THE MESSAGE LENGTH AND COMPLETE THE HANDSHAKE
          this._messageLength = pow(2, min(SocketHelper.getMaxMessageSizeExponent(message), this._messageLengthExponent));
          _handshakeCompleter.complete();
        }
      }
      // RECEIVED SECOND HANDSHAKE / UPGRADE
      if(SocketHelper.isUpgrade(message)){
        this._messageLength = pow(2, min(SocketHelper.getMaxUpgradeMessageSizeExponent(message), this._messageLengthExponent));
        _handshakeCompleter.complete();
      }
      return true;
    }else{
      bool closeConnection = true;
      String error;
      if(errorNumber == SocketHelper.ERROR_SERIALIZER_UNSUPPORTED){
        error = "Router responded with an error: ERROR_SERIALIZER_UNSUPPORTED";
      }else if(errorNumber == SocketHelper.ERROR_USE_OF_RESERVED_BITS){
        error = "Router responded with an error: ERROR_USE_OF_RESERVED_BITS";
        // if another has been connected with an upgrade header
        closeConnection = false;
      }else if(errorNumber == SocketHelper.ERROR_MAX_CONNECTION_COUNT_EXCEEDED){
        error = "Router responded with an error: ERROR_MAX_CONNECTION_COUNT_EXCEEDED";
      }else if(errorNumber == SocketHelper.ERROR_MESSAGE_LENGTH_EXCEEDED){
        error = "Router responded with an error: ERROR_MESSAGE_LENGTH_EXCEEDED";
        // if connectanum is configured with a lower message length
        closeConnection = false;
      }else{
        error = "Router responded with an error: UNKNOWN "+errorNumber.toString();
      }
      _logger.shout(errorNumber.toString() + ": " + error);
      if(closeConnection){
        _handshakeCompleter.completeError({"error": error, "errorNumber": errorNumber});
        _socket.drain().then((_) {
          _socket.close();
        });
      }
      return true;
    }
  }

  bool _assertValidMessage(Uint8List message) {
    if (!SocketHelper.isValidMessage(message)){
      _socket.add(SocketHelper.getError(SocketHelper.ERROR_USE_OF_RESERVED_BITS));
      _logger.shout("Closed raw socket channel because the received message type " + SocketHelper.getMessageType(message).toString() + " is unknown.");
      return false;
    }
    return true;
  }

  AbstractMessage _handleMessage(Uint8List message) {
    try {
      int messageType = SocketHelper.getMessageType(message);
      int messageLength = SocketHelper.getPayloadLength(message,headerLength);
      // cut off the header
      message = message.sublist(headerLength);
      // send the rest of the message back to the buffer
      _inboundBuffer = message.sublist(messageLength, message.length);
      message = message.sublist(0, messageLength);

      if(messageType == SocketHelper.MESSAGE_WAMP) {
        AbstractMessage deserializedMessage = _serializer.deserialize(message);
        _logger.finest("Received message type " + deserializedMessage.id.toString());
        return deserializedMessage;
      } else if(messageType == SocketHelper.MESSAGE_PING) {
        // send pong
        _logger.finest("Responded to ping with pong and a payload length of " + message.length.toString());
        _socket.add(SocketHelper.getPong(message.length,isUpgradedProtocol));
        _socket.add(message);
      } else {
        // received a pong
        _logger.finest("Received a Pong with a payload length of " + message.length.toString());
      }
    } on Exception catch (error) {
      // TODO handle serialization error
      _logger.fine("Error while handling incoming message " + error.toString());
    }
    return null;
  }

  @override
  void send(AbstractMessage message) {
    if (!_handshakeCompleter.isCompleted) {
      if (_outboundBuffer.length == 0) {
        _handshakeCompleter.future.then((aVoid) {
          _socket.add(_outboundBuffer);
          _outboundBuffer = null;
        });
      }
      Uint8List serialalizedMessage = _serializer.serialize(message);
      _outboundBuffer += SocketHelper.buildMessageHeader(SocketHelper.MESSAGE_WAMP, serialalizedMessage.length, isUpgradedProtocol);
      _outboundBuffer += serialalizedMessage;
    } else {
      Uint8List serialalizedMessage = _serializer.serialize(message);
      _socket.add(SocketHelper.buildMessageHeader(SocketHelper.MESSAGE_WAMP, serialalizedMessage.length, isUpgradedProtocol));
      _socket.add(serialalizedMessage);
    }
  }
}