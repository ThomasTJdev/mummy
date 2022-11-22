import mummy/common, mummy/internal, std/base64, std/cpuinfo, std/deques,
    std/hashes, std/locks, std/nativesockets, std/os, std/parseutils,
    std/selectors, std/sets, std/sha1, std/strutils, std/tables, std/times,
    zippy

export Port, common

const
  listenBacklogLen = 128
  maxEventsPerSelectLoop = 64
  initialRecvBufferLen = (32 * 1024) - 9 # 8 byte cap field + null terminator

type
  RequestObj = object
    httpVersion*: HttpVersion
    httpMethod*: string
    uri*: string
    headers*: HttpHeaders
    body*: string
    server: Server
    clientSocket: SocketHandle

  Request* = ptr RequestObj

  RequestHandler* = proc(request: Request) {.gcsafe.}

  WebSocket* = object
    server: Server
    clientSocket: SocketHandle

  WebSocketEventKind* = enum
    OpenEvent, MessageEvent, ErrorEvent, CloseEvent

  MessageKind* = enum
    TextMessage, BinaryMessage, Ping, Pong

  WebSocketHandler* = proc(
    websocket: WebSocket,
    event: WebSocketEventKind,
    message: string,
    messageKind: MessageKind
  ) {.gcsafe.}

  ServerObj = object
    handler: RequestHandler
    websocketHandler: WebSocketHandler
    maxHeadersLen, maxBodyLen: int
    workerThreads: seq[Thread[Server]]
    veryBad: bool
    socket: SocketHandle
    selector: Selector[HandleData]
    responseQueued, sendQueued, shutdown: SelectEvent
    clientSockets: HashSet[SocketHandle]
    workerQueue: Deque[WorkerTask]
    workerQueueLock: Lock
    workerQueueCond: Cond
    responseQueue: Deque[EncodedResponse]
    responseQueueLock: Lock
    sendQueue: Deque[EncodedFrame]
    sendQueueLock: Lock
    websocketQueues: Table[WebSocket, Deque[WebSocketEvent]]
    websocketQueuesLock: Lock

  Server* = ptr ServerObj

  WorkerTask = object
    request: Request
    websocket: WebSocket

  HandleData = ref object
    forEvent: SelectEvent
    recvBuffer: string
    bytesReceived: int
    requestState: IncomingRequestState
    frameState: IncomingFrameState
    outgoingBuffers: Deque[OutgoingBuffer]
    closeFrameQueuedAt: float64
    upgradedToWebSocket, closeFrameSent: bool
    sendsWaitingForUpgrade: seq[EncodedFrame]

  IncomingRequestState = object
    headersParsed, chunked: bool
    contentLength: int
    httpVersion: HttpVersion
    httpMethod, uri: string
    headers: HttpHeaders
    body: string

  IncomingFrameState = object
    opcode: uint8
    buffer: string
    frameLen: int

  EncodedResponse = ref object
    clientSocket: SocketHandle
    isWebSocketUpgrade, closeConnection: bool
    buffer1, buffer2: string

  EncodedFrame = ref object
    clientSocket: SocketHandle
    isCloseFrame: bool
    buffer1, buffer2: string

  OutgoingBuffer = ref object
    closeConnection, isWebSocketUpgrade, isCloseFrame: bool
    buffer1, buffer2: string
    bytesSent: int

  WebSocketEvent = ref object
    event: WebSocketEventKind
    message: string
    messageKind: MessageKind

proc `$`*(request: Request): string =
  result = request.httpMethod & " " & request.uri & " "
  case request.httpVersion:
  of Http10:
    result &= "HTTP/1.0"
  else:
    result &= "HTTP/1.0"
  result &= " (" & $cast[uint](request) & ")"

proc `$`*(websocket: WebSocket): string =
  "WebSocket " & $hash(websocket)

proc hash*(websocket: WebSocket): Hash =
  var h: Hash
  h = h !& hash(websocket.server)
  h = h !& hash(websocket.clientSocket)
  return !$h

proc headerContainsToken(headers: var HttpHeaders, key, token: string): bool =
  for (k, v) in headers:
    if cmpIgnoreCase(k, key) == 0:
      if ',' in v:
        var parts = v.split(",")
        for part in parts.mitems:
          if cmpIgnoreCase(part.strip(), token) == 0:
            return true
      else:
        if cmpIgnoreCase(v, token) == 0:
          return true

proc updateHandle2(
  selector: Selector[HandleData],
  socket: SocketHandle,
  events: set[Event]
) {.raises: [IOSelectorsException].} =
  try:
    selector.updateHandle(socket, events)
  except ValueError: # Why ValueError?
    raise newException(IOSelectorsException, getCurrentExceptionMsg())

proc trigger2(
  event: SelectEvent
) {.raises: [].} =
  try:
    event.trigger()
  except:
    # TODO: EAGAIN vs other, log
    # Happens if SelectEvent has been closed
    discard

proc workerProc(server: Server) =
  while true:
    acquire(server.workerQueueLock)

    while server.workerQueue.len == 0 and not server.veryBad:
      wait(server.workerQueueCond, server.workerQueueLock)

    if server.veryBad:
      release(server.workerQueueLock)
      return

    var task = server.workerQueue.popFirst()

    release(server.workerQueueLock)

    if task.request != nil:
      try:
        server.handler(task.request)
      except:
        # TODO: log?
        echo getCurrentExceptionMsg()
      deallocShared(task.request)
    else: # WebSocket
      while true: # Process the entire websocket queue
        var event: WebSocketEvent
        acquire(server.websocketQueuesLock)
        if task.websocket in server.websocketQueues:
          try:
            if server.websocketQueues[task.websocket].len > 0:
              event = server.websocketQueues[task.websocket].popFirst()
            else:
              server.websocketQueues.del(task.websocket)
          except KeyError:
            discard
        release(server.websocketQueuesLock)
        if event == nil:
          break

        try:
          server.websocketHandler(
            task.websocket,
            event.event,
            move event.message,
            event.messageKind
          )
        except:
          # TODO: log?
          echo getCurrentExceptionMsg()

proc send*(
  websocket: WebSocket,
  data: sink string,
  kind = TextMessage,
) {.raises: [], gcsafe.} =
  let encodedFrame = EncodedFrame()
  encodedFrame.clientSocket = websocket.clientSocket

  case kind:
  of TextMessage:
    encodedFrame.buffer1 = encodeFrameHeader(0x1, data.len)
  of BinaryMessage:
    encodedFrame.buffer1 = encodeFrameHeader(0x2, data.len)
  of Ping:
    encodedFrame.buffer1 = encodeFrameHeader(0x9, data.len)
  of Pong:
    encodedFrame.buffer1 = encodeFrameHeader(0xA, data.len)

  encodedFrame.buffer2 = move data

  acquire(websocket.server.sendQueueLock)
  websocket.server.sendQueue.addLast(encodedFrame)
  release(websocket.server.sendQueueLock)

  websocket.server.sendQueued.trigger2()

proc close*(websocket: WebSocket) {.raises: [], gcsafe.} =
  let encodedFrame = EncodedFrame()
  encodedFrame.clientSocket = websocket.clientSocket
  encodedFrame.buffer1 = encodeFrameHeader(0x8, 0)
  encodedFrame.isCloseFrame = true

  acquire(websocket.server.sendQueueLock)
  websocket.server.sendQueue.addLast(encodedFrame)
  release(websocket.server.sendQueueLock)

  websocket.server.sendQueued.trigger2()

proc respond*(
  request: Request,
  statusCode: int,
  headers: sink HttpHeaders = newSeq[(string, string)](),
  body: sink string = ""
) {.raises: [], gcsafe.} =
  var encodedResponse = EncodedResponse()
  encodedResponse.clientSocket = request.clientSocket
  encodedResponse.closeConnection =
    request.httpVersion == Http10 # Default behavior

  # Override default behavior based on request Connection header
  if request.headers.headerContainsToken("Connection", "close"):
    encodedResponse.closeConnection = true
  elif request.headers.headerContainsToken("Connection", "keep-alive"):
    encodedResponse.closeConnection = false

  # If we are not already going to close the connection based on the request
  # headers, check if we should based on the response headers
  if not encodedResponse.closeConnection:
    encodedResponse.closeConnection = headers.headerContainsToken(
      "Connection", "close"
    )

  if encodedResponse.closeConnection:
    headers["Connection"] = "close"
  elif request.httpVersion == Http10 or "Connection" notin headers:
    headers["Connection"] = "keep-alive"

  # If the body is big enough to justify compressing and not already compressed
  if body.len > 128 and "Content-Encoding" notin headers:
    if request.headers.headerContainsToken("Accept-Encoding", "gzip"):
      try:
        body = compress(body.cstring, body.len, BestSpeed, dfGzip)
      except:
        # This should never happen since exceptions are only thrown if
        # the data format is invalid or the level is invalid
        # TODO: log?
        return
      headers["Content-Encoding"] = "gzip"
    elif request.headers.headerContainsToken("Accept-Encoding", "deflate"):
      try:
        body = compress(body.cstring, body.len, BestSpeed, dfDeflate)
      except:
        # See gzip
        # TODO: log?
        return
      headers["Content-Encoding"] = "deflate"
    else:
      discard

  headers["Content-Length"] = $body.len

  encodedResponse.buffer1 = encodeHeaders(statusCode, headers)
  encodedResponse.buffer2 = move body
  encodedResponse.isWebSocketUpgrade = headers.headerContainsToken(
    "Upgrade",
    "websocket"
  )

  acquire(request.server.responseQueueLock)
  request.server.responseQueue.addLast(move encodedResponse)
  release(request.server.responseQueueLock)

  request.server.responseQueued.trigger2()

proc upgradeToWebSocket*(
  request: Request
): WebSocket {.raises: [MummyError], gcsafe.} =
  if not request.headers.headerContainsToken("Connection", "upgrade"):
    raise newException(
      MummyError,
      "Invalid request to upgade, missing 'Connection: upgrade' header"
    )

  if not request.headers.headerContainsToken("Upgrade", "websocket"):
    raise newException(
      MummyError,
      "Invalid request to upgade, missing 'Upgrade: websocket' header"
    )

  let websocketKey = request.headers["Sec-WebSocket-Key"]
  if websocketKey == "":
    raise newException(
      MummyError,
      "Invalid request to upgade, missing Sec-WebSocket-Key header"
    )

  let websocketVersion = request.headers["Sec-WebSocket-Version"]
  if websocketVersion != "13":
    raise newException(
      MummyError,
      "Invalid request to upgade, missing Sec-WebSocket-Version header"
    )

  # Looks good to upgrade

  result.server = request.server
  result.clientSocket = request.clientSocket

  let hash =
    secureHash(websocketKey & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").Sha1Digest

  var headers: HttpHeaders
  headers["Connection"] = "upgrade"
  headers["Upgrade"] = "websocket"
  headers["Sec-WebSocket-Accept"] = base64.encode(hash)

  request.respond(101, headers, "")

proc enqueueWebSocketEvent(
  websocket: WebSocket,
  event: WebSocketEvent
) {.raises: [].} =
  if websocket.server.websocketHandler == nil:
    # TODO: log?
    return

  var needsWorkQueueEntry: bool

  acquire(websocket.server.websocketQueuesLock)
  if websocket in websocket.server.websocketQueues:
    try:
      websocket.server.websocketQueues[websocket].addLast(event)
    except KeyError:
      assert false # Notice this when not a release build
  else:
    var queue: Deque[WebSocketEvent]
    queue.addLast(event)
    websocket.server.websocketQueues[websocket] = move queue
    needsWorkQueueEntry = true
  release(websocket.server.websocketQueuesLock)

  if needsWorkQueueEntry:
    acquire(websocket.server.workerQueueLock)
    websocket.server.workerQueue.addLast(WorkerTask(websocket: websocket))
    release(websocket.server.workerQueueLock)
    signal(websocket.server.workerQueueCond)

proc sendCloseFrame(
  server: Server,
  clientSocket: SocketHandle,
  handleData: HandleData,
  closeConnection: bool
) {.raises: [IOSelectorsException].} =
  let outgoingBuffer = OutgoingBuffer()
  outgoingBuffer.buffer1 = encodeFrameHeader(0x8, 0)
  outgoingBuffer.isCloseFrame = true
  outgoingBuffer.closeConnection = closeConnection
  handleData.outgoingBuffers.addLast(outgoingBuffer)
  handleData.closeFrameQueuedAt = epochTime()
  server.selector.updateHandle2(clientSocket, {Read, Write})

proc afterRecvWebSocket(
  server: Server,
  clientSocket: SocketHandle,
  handleData: HandleData
): bool {.raises: [IOSelectorsException].} =
  if handleData.closeFrameQueuedAt > 0 and
    epochTime() - handleData.closeFrameQueuedAt > 10:
    # The Close frame dance didn't work out, just close the connection
    # TODO: log?
    return true

  # Try to parse entire frames out of the receive buffer
  while true:
    if handleData.bytesReceived < 2:
      return false # Need to receive more bytes

    let
      b0 = handleData.recvBuffer[0].uint8
      b1 = handleData.recvBuffer[1].uint8
      fin = (b0 and 0b10000000) != 0
      rsv1 = b0 and 0b01000000
      rsv2 = b0 and 0b00100000
      rsv3 = b0 and 0b00010000
      opcode = b0 and 0b00001111

    if rsv1 != 0 or rsv2 != 0 or rsv3 != 0:
      return true # Per spec this must fail, close the connection

    # Masking bit should be set
    if (b1 and 0b10000000) == 0:
      return true # Per spec, close the connection

    if opcode == 0 and handleData.frameState.opcode == 0:
      # Per spec, the first frame must have an opcode > 0
      return true # Close the connection

    if handleData.frameState.opcode != 0 and opcode != 0:
      # Per spec, if we have buffered fragments the opcode must be 0
      return true # Close the connection

    var pos = 2

    var payloadLen = (b1 and 0b01111111).int
    if payloadLen <= 125:
      discard
    elif payloadLen == 126:
      if handleData.bytesReceived < 4:
        return false # Need to receive more bytes
      var l: uint16
      copyMem(l.addr, handleData.recvBuffer[pos].addr, 2)
      payloadLen = l.htons.int
      pos += 2
    else:
      if handleData.bytesReceived < 10:
        return false # Need to receive more bytes
      var l: uint32
      copyMem(l.addr, handleData.recvBuffer[pos + 4].addr, 4)
      payloadLen = l.htonl.int
      pos += 8

    if handleData.frameState.frameLen + payloadLen > server.maxBodyLen:
      return true # Message is too large, close the connection

    if handleData.bytesReceived < pos + 4:
      return false # Need to receive more bytes

    var mask: array[4, uint8]
    copyMem(mask.addr, handleData.recvBuffer[pos].addr, 4)

    pos += 4

    if handleData.bytesReceived < pos + payloadLen:
      return false # Need to receive more bytes

    # Unmask the payload
    for i in 0 ..< payloadLen:
      let j = i mod 4
      handleData.recvBuffer[pos + i] =
        (handleData.recvBuffer[pos + i].uint8 xor mask[j]).char

    if handleData.frameState.opcode == 0:
      # This is the first fragment
      handleData.frameState.opcode = opcode

    # Make room in the message buffer for this fragment
    let newFrameLen = handleData.frameState.frameLen + payloadLen
    if handleData.frameState.buffer.len < newFrameLen:
      let newBufferLen = max(handleData.frameState.buffer.len * 2, newFrameLen)
      handleData.frameState.buffer.setLen(newBufferLen)

    if payloadLen > 0:
      # Copy the fragment into the message buffer
      copyMem(
        handleData.frameState.buffer[handleData.frameState.frameLen].addr,
        handleData.recvBuffer[pos].addr,
        payloadLen
      )
      handleData.frameState.frameLen += payloadLen

    # Remove this frame from the receive buffer
    let frameLen = pos + payloadLen
    if handleData.bytesReceived == frameLen:
      handleData.bytesReceived = 0
    else:
      copyMem(
        handleData.recvBuffer[0].addr,
        handleData.recvBuffer[frameLen].addr,
        handleData.bytesReceived - frameLen
      )
      handleData.bytesReceived -= frameLen

    if fin:
      if handleData.frameState.opcode == 0:
        return true # Invalid frame, close the connection

    #   # We have a full message

      let
        websocket = WebSocket(
          server: server,
          clientSocket: clientSocket
        )
        event = WebSocketEvent(
          event: MessageEvent,
          message: move handleData.frameState.buffer
        )

      event.message.setLen(handleData.frameState.frameLen)
      handleData.frameState = IncomingFrameState()

      case opcode:
      of 0x1: # Text
        event.messageKind = TextMessage
      of 0x2: # Binary
        event.messageKind = BinaryMessage
      of 0x8: # Close
        # If we already queued a close, just close the connection
        # This is not quite perfect
        if handleData.closeFrameQueuedAt > 0:
          return true # Close the connection
        # Otherwise send a Close in response then close the connection
        server.sendCloseFrame(clientSocket, handleData, true)
        continue
      of 0x9: # Ping
        event.messageKind = Ping
      of 0xA: # Pong
        event.messageKind = Pong
      else:
        # TODO: log?
        return true # Invalid opcode, close the connection

      websocket.enqueueWebSocketEvent(event)

proc popRequest(
  server: Server,
  clientSocket: SocketHandle,
  handleData: HandleData
): Request {.raises: [].} =
  ## Pops the completed HttpRequest from the socket and resets the parse state.
  result = cast[Request](allocShared0(sizeof(RequestObj)))
  result.server = server
  result.clientSocket = clientSocket
  result.httpVersion = handleData.requestState.httpVersion
  result.httpMethod = move handleData.requestState.httpMethod
  result.uri = move handleData.requestState.uri
  result.headers = move handleData.requestState.headers
  result.body = move handleData.requestState.body
  result.body.setLen(handleData.requestState.contentLength)
  handleData.requestState = IncomingRequestState()

proc afterRecvHttp(
  server: Server,
  clientSocket: SocketHandle,
  handleData: HandleData
): bool {.raises: [].} =
  # Have we completed parsing the headers?
  if not handleData.requestState.headersParsed:
    # Not done with headers yet, look for the end of the headers
    let headersEnd = handleData.recvBuffer.find(
      "\r\n\r\n",
      0,
      min(handleData.bytesReceived, server.maxHeadersLen) - 1 # Inclusive
    )
    if headersEnd < 0: # Headers end not found
      if handleData.bytesReceived > server.maxHeadersLen:
        return true # Headers too long or malformed, close the connection
      return false # Try again after receiving more bytes

    # We have the headers, now to parse them
    var
      headerLines: seq[string]
      nextLineStart: int
    while true:
      let lineEnd = handleData.recvBuffer.find(
        "\r\n",
        nextLineStart,
        headersEnd
      )
      if lineEnd == -1:
        var line = handleData.recvBuffer[nextLineStart ..< headersEnd].strip()
        headerLines.add(move line)
        break
      else:
        headerLines.add(handleData.recvBuffer[nextLineStart ..< lineEnd].strip())
        nextLineStart = lineEnd + 2

    let
      requestLine = headerLines[0]
      requestLineParts = requestLine.split(" ")
    if requestLineParts.len != 3:
      return true # Malformed request line, close the connection

    handleData.requestState.httpMethod = requestLineParts[0]
    handleData.requestState.uri = requestLineParts[1]

    if requestLineParts[2] == "HTTP/1.0":
      handleData.requestState.httpVersion = Http10
    elif requestLineParts[2] == "HTTP/1.1":
      handleData.requestState.httpVersion = Http11
    else:
      return true # Unsupported HTTP version, close the connection

    for i in 1 ..< headerLines.len:
      let parts = headerLines[i].split(": ")
      if parts.len == 2:
        handleData.requestState.headers.add((parts[0], parts[1]))
      else:
        handleData.requestState.headers.add((headerLines[i], ""))

    handleData.requestState.chunked =
      handleData.requestState.headers.headerContainsToken(
        "Transfer-Encoding", "chunked"
      )

    # If this is a chunked request ignore any Content-Length headers
    if not handleData.requestState.chunked:
      var foundContentLength: bool
      for (k, v) in handleData.requestState.headers:
        if cmpIgnoreCase(k, "Content-Length") == 0:
          if foundContentLength:
            # This is a second Content-Length header, not valid
            return true # Close the connection
          foundContentLength = true
          try:
            handleData.requestState.contentLength = parseInt(v)
          except:
            return true # Parsing Content-Length failed, close the connection

      if handleData.requestState.contentLength < 0:
        return true # Invalid Content-Length, close the connection

    # Remove the headers from the receive buffer
    let bodyStart = headersEnd + 4
    if handleData.bytesReceived == bodyStart:
      handleData.bytesReceived = 0
    else:
      copyMem(
        handleData.recvBuffer[0].addr,
        handleData.recvBuffer[bodyStart].addr,
        handleData.bytesReceived - bodyStart
      )
      handleData.bytesReceived -= bodyStart

    # One of three possible states for request body:
    # 1) We received a Content-Length header, so we know the content length
    # 2) We received a Transfer-Encoding: chunked header
    # 3) Neither, so we assume a content length of 0

    # Mark that headers have been parsed, must end this block
    handleData.requestState.headersParsed = true

  # Headers have been parsed, now for the body

  if handleData.requestState.chunked: # Chunked request
    # Process as many chunks as we have
    while true:
      if handleData.bytesReceived < 3:
        return false # Need to receive more bytes

      # Look for the end of the chunk length
      let chunkLenEnd = handleData.recvBuffer.find(
        "\r\n",
        0,
        min(handleData.bytesReceived - 1, 19) # Inclusive with a reasonable max
      )
      if chunkLenEnd < 0: # Chunk length end not found
        if handleData.bytesReceived > 19:
          return true # We should have found it, close the connection
        return false # Try again after receiving more bytes

      var chunkLen: int
      try:
        discard parseHex(
          handleData.recvBuffer,
          chunkLen,
          0,
          chunkLenEnd
        )
      except:
        return true # Parsing chunk length failed, close the connection

      if handleData.requestState.contentLength + chunkLen > server.maxBodyLen:
        return true # Body is too large, close the connection

      let chunkStart = chunkLenEnd + 2
      if handleData.bytesReceived < chunkStart + chunkLen + 2:
        return false # Need to receive more bytes

      # Make room in the body buffer for this chunk
      let newContentLength = handleData.requestState.contentLength + chunkLen
      if handleData.requestState.body.len < newContentLength:
        let newLen = max(handleData.requestState.body.len * 2, newContentLength)
        handleData.requestState.body.setLen(newLen)

      copyMem(
        handleData.requestState.body[handleData.requestState.contentLength].addr,
        handleData.recvBuffer[chunkStart].addr,
        chunkLen
      )

      handleData.requestState.contentLength += chunkLen

      # Remove this chunk from the receive buffer
      let
        nextChunkStart = chunkLenEnd + 2 + chunkLen + 2
        bytesRemaining = handleData.bytesReceived - nextChunkStart
      copyMem(
        handleData.recvBuffer[0].addr,
        handleData.recvBuffer[nextChunkStart].addr,
        bytesRemaining
      )
      handleData.bytesReceived = bytesRemaining

      if chunkLen == 0:
        let request = server.popRequest(clientSocket, handleData)
        acquire(server.workerQueueLock)
        server.workerQueue.addLast(WorkerTask(request: request))
        release(server.workerQueueLock)
        signal(server.workerQueueCond)
        return false
  else:
    if handleData.requestState.contentLength > server.maxBodyLen:
      return true # Body is too large, close the connection

    if handleData.bytesReceived < handleData.requestState.contentLength:
      return false # Need to receive more bytes

    # We have the entire request body

    # If this request has a body, fill it
    if handleData.requestState.contentLength > 0:
      handleData.requestState.body.setLen(handleData.requestState.contentLength)
      copyMem(
        handleData.requestState.body[0].addr,
        handleData.recvBuffer[0].addr,
        handleData.requestState.contentLength
      )

    # Remove this request from the receive buffer
    let bytesRemaining =
      handleData.bytesReceived - handleData.requestState.contentLength
    copyMem(
      handleData.recvBuffer[0].addr,
      handleData.recvBuffer[handleData.requestState.contentLength].addr,
      bytesRemaining
    )
    handleData.bytesReceived = bytesRemaining

    let request = server.popRequest(clientSocket, handleData)
    acquire(server.workerQueueLock)
    server.workerQueue.addLast(WorkerTask(request: request))
    release(server.workerQueueLock)
    signal(server.workerQueueCond)

proc afterRecv(
  server: Server,
  clientSocket: SocketHandle,
  handleData: HandleData
): bool {.raises: [IOSelectorsException].} =
  # Have we upgraded this connection to a websocket?
  # If not, treat incoming bytes as part of HTTP requests.
  if handleData.upgradedToWebSocket:
    server.afterRecvWebSocket(clientSocket, handleData)
  else:
    server.afterRecvHttp(clientSocket, handleData)

proc afterSend(
  server: Server,
  clientSocket: SocketHandle,
  handleData: HandleData
): bool {.raises: [IOSelectorsException].} =
  let
    outgoingBuffer = handleData.outgoingBuffers.peekFirst()
    totalBytes = outgoingBuffer.buffer1.len + outgoingBuffer.buffer2.len
  if outgoingBuffer.bytesSent == totalBytes:
    handleData.outgoingBuffers.shrink(1)
    if outgoingBuffer.isWebSocketUpgrade:
      let
        websocket = WebSocket(
          server: server,
          clientSocket: clientSocket
        )
        event = WebSocketEvent(event: OpenEvent)
      websocket.enqueueWebSocketEvent(event)

    if outgoingBuffer.isCloseFrame:
      handleData.closeFrameSent = true
    if outgoingBuffer.closeConnection:
      return true
  if handleData.outgoingBuffers.len == 0:
    server.selector.updateHandle2(clientSocket, {Read})

proc convertToOutgoingBuffer(encodedFrame: EncodedFrame): OutgoingBuffer =
  result = OutgoingBuffer()
  result.buffer1 = move encodedFrame.buffer1
  result.buffer2 = move encodedFrame.buffer2
  result.isCloseFrame = encodedFrame.isCloseFrame

proc convertToOutgoingBuffer(encodedResponse: EncodedResponse): OutgoingBuffer =
  result = OutgoingBuffer()
  result.closeConnection = encodedResponse.closeConnection
  result.isWebSocketUpgrade =
    encodedResponse.isWebSocketUpgrade
  result.buffer1 = move encodedResponse.buffer1
  result.buffer2 = move encodedResponse.buffer2

proc destroy(server: Server, joinThreads: bool) {.raises: [].} =
  if server.selector != nil:
    try:
      server.selector.close()
    except:
      discard # Ignore
  server.selector = nil # Since this lives on a pointer
  if server.socket.int != 0:
    server.socket.close()
  for clientSocket in server.clientSockets:
    clientSocket.close()
  acquire(server.workerQueueLock)
  server.veryBad = true
  release(server.workerQueueLock)
  broadcast(server.workerQueueCond)
  if joinThreads:
    joinThreads(server.workerThreads)
  deinitLock(server.workerQueueLock)
  deinitCond(server.workerQueueCond)
  deinitLock(server.responseQueueLock)
  deinitLock(server.sendQueueLock)
  deinitLock(server.websocketQueuesLock)
  try:
    server.responseQueued.close()
  except:
    discard # Ignore
  try:
    server.sendQueued.close()
  except:
    discard # Ignore
  deallocShared(server)

proc loopForever(
  server: Server,
  port: Port
) {.raises: [OSError, IOSelectorsException].} =
  var
    readyKeys: array[maxEventsPerSelectLoop, ReadyKey]
    receivedFrom, sentTo, needClosing: seq[SocketHandle]
  while true:
    receivedFrom.setLen(0)
    sentTo.setLen(0)
    needClosing.setLen(0)
    let readyCount = server.selector.selectInto(-1, readyKeys)
    for i in 0 ..< readyCount:
      let readyKey = readyKeys[i]

      # echo "Socket ready: ", readyKey.fd, " ", readyKey.events

      if User in readyKey.events:
        let eventHandleData = server.selector.getData(readyKey.fd)
        if eventHandleData.forEvent == server.responseQueued:
          acquire(server.responseQueueLock)
          let encodedResponse = server.responseQueue.popFirst()
          release(server.responseQueueLock)

          if encodedResponse.clientSocket in server.selector:
            let clientHandleData =
              server.selector.getData(encodedResponse.clientSocket)

            let outgoingBuffer = encodedResponse.convertToOutgoingBuffer()
            clientHandleData.outgoingBuffers.addLast(outgoingBuffer)
            server.selector.updateHandle2(
              encodedResponse.clientSocket,
              {Read, Write}
            )

            if encodedResponse.isWebSocketUpgrade:
              clientHandleData.upgradedToWebSocket = true
              if clientHandleData.bytesReceived > 0:
                # Why have we received bytes when we are upgrading the connection?
                needClosing.add(readyKey.fd.SocketHandle)
                clientHandleData.sendsWaitingForUpgrade.setLen(0)
                # TODO: log?
                continue
              # Are there any sends that were waiting for this response?
              if clientHandleData.sendsWaitingForUpgrade.len > 0:
                for encodedFrame in clientHandleData.sendsWaitingForUpgrade:
                  if clientHandleData.closeFrameQueuedAt > 0:
                    discard # Drop this message
                    # TODO: log?
                  else:
                    let outgoingBuffer = encodedFrame.convertToOutgoingBuffer()
                    clientHandleData.outgoingBuffers.addLast(outgoingBuffer)
                    if encodedFrame.isCloseFrame:
                      clientHandleData.closeFrameQueuedAt = epochTime()
                clientHandleData.sendsWaitingForUpgrade.setLen(0)
          else:
            discard # TODO: log?
        elif eventHandleData.forEvent == server.sendQueued:
          acquire(server.responseQueueLock)
          let encodedFrame = server.sendQueue.popFirst()
          release(server.responseQueueLock)

          if encodedFrame.clientSocket in server.selector:
            let clientHandleData =
              server.selector.getData(encodedFrame.clientSocket)

            # Have we sent the upgrade response yet?
            if clientHandleData.upgradedToWebSocket:
              if clientHandleData.closeFrameQueuedAt > 0:
                discard # Drop this message
                # TODO: log?
              else:
                let outgoingBuffer = encodedFrame.convertToOutgoingBuffer()
                clientHandleData.outgoingBuffers.addLast(outgoingBuffer)
                if encodedFrame.isCloseFrame:
                  clientHandleData.closeFrameQueuedAt = epochTime()
                server.selector.updateHandle2(
                  encodedFrame.clientSocket,
                  {Read, Write}
                )
            else:
              # If we haven't, queue this to wait for the upgrade response
              clientHandleData.sendsWaitingForUpgrade.add(encodedFrame)
          else:
            discard # TODO: log?
        elif eventHandleData.forEvent == server.shutdown:
          server.destroy(true)
          return
        else:
          assert false # Notice this when not a release build
      elif readyKey.fd == server.socket.int:
        if Read in readyKey.events:
          let (clientSocket, _) = server.socket.accept()
          if clientSocket == osInvalidSocket:
            continue

          clientSocket.setBlocking(false)
          server.clientSockets.incl(clientSocket)

          let handleData = HandleData()
          handleData.recvBuffer.setLen(initialRecvBufferLen)
          server.selector.registerHandle(clientSocket, {Read}, handleData)
        else:
          assert false # Notice this when not a release build
      else: # Client socket
        if Error in readyKey.events:
          needClosing.add(readyKey.fd.SocketHandle)
          continue

        let handleData = server.selector.getData(readyKey.fd)

        if Read in readyKey.events:
          # Expand the buffer if it is full
          if handleData.bytesReceived == handleData.recvBuffer.len:
            handleData.recvBuffer.setLen(handleData.recvBuffer.len * 2)

          let bytesReceived = readyKey.fd.SocketHandle.recv(
            handleData.recvBuffer[handleData.bytesReceived].addr,
            handleData.recvBuffer.len - handleData.bytesReceived,
            0
          )
          if bytesReceived > 0:
            handleData.bytesReceived += bytesReceived
            receivedFrom.add(readyKey.fd.SocketHandle)
          else:
            needClosing.add(readyKey.fd.SocketHandle)
            continue

        if Write in readyKey.events:
          let
            outgoingBuffer = handleData.outgoingBuffers.peekFirst()
            bytesSent =
              if outgoingBuffer.bytesSent < outgoingBuffer.buffer1.len:
                readyKey.fd.SocketHandle.send(
                  outgoingBuffer.buffer1[outgoingBuffer.bytesSent].addr,
                  outgoingBuffer.buffer1.len - outgoingBuffer.bytesSent,
                  0
                )
              else:
                let buffer2Pos =
                  outgoingBuffer.bytesSent - outgoingBuffer.buffer1.len
                readyKey.fd.SocketHandle.send(
                  outgoingBuffer.buffer2[buffer2Pos].addr,
                  outgoingBuffer.buffer2.len - buffer2Pos,
                  0
                )
          if bytesSent > 0:
            outgoingBuffer.bytesSent += bytesSent
            sentTo.add(readyKey.fd.SocketHandle)
          else:
            needClosing.add(readyKey.fd.SocketHandle)
            continue

    for clientSocket in receivedFrom:
      if clientSocket in needClosing:
        continue
      let
        handleData = server.selector.getData(clientSocket)
        needsClosing = server.afterRecv(clientSocket, handleData)
      if needsClosing:
        needClosing.add(clientSocket)

    for clientSocket in sentTo:
      if clientSocket in needClosing:
        continue
      let
        handleData = server.selector.getData(clientSocket)
        needsClosing = server.afterSend(clientSocket, handleData)
      if needsClosing:
        needClosing.add(clientSocket)

    for clientSocket in needClosing:
      let handleData = server.selector.getData(clientSocket)
      try:
        server.selector.unregister(clientSocket)
      except:
        # Leaks HandleData for this socket
        # Raise as a serve() exception?
        raise cast[ref IOSelectorsException](getCurrentException())
      finally:
        clientSocket.close()
        server.clientSockets.excl(clientSocket)
      if handleData.upgradedToWebSocket:
        let websocket = WebSocket(server: server, clientSocket: clientSocket)
        if not handleData.closeFrameSent:
          let error = WebSocketEvent(event: ErrorEvent)
          websocket.enqueueWebSocketEvent(error)
        let close = WebSocketEvent(event: CloseEvent)
        websocket.enqueueWebSocketEvent(close)

proc close*(server: Server) {.raises: [], gcsafe.} =
  server.shutdown.trigger2()

proc serve*(server: Server, port: Port) {.raises: [MummyError].} =
  if server.socket.int != 0:
    raise newException(MummyError, "Server already has a socket")

  try:
    server.socket = createNativeSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, false)
    if server.socket == osInvalidSocket:
      raiseOSError(osLastError())

    server.socket.setBlocking(false)
    server.socket.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)

    let ai = getAddrInfo(
      "0.0.0.0",
      port,
      AF_INET,
      SOCK_STREAM,
      IPPROTO_TCP
    )
    try:
      if bindAddr(server.socket, ai.ai_addr, ai.ai_addrlen.SockLen) < 0:
        raiseOSError(osLastError())
    finally:
      freeAddrInfo(ai)

    if server.socket.listen(listenBacklogLen) < 0:
      raiseOSError(osLastError())

    server.selector = newSelector[HandleData]()

    server.selector.registerHandle(server.socket, {Read}, nil)

    let responseQueuedData = HandleData()
    responseQueuedData.forEvent = server.responseQueued
    server.selector.registerEvent(server.responseQueued, responseQueuedData)

    let sendQueuedData = HandleData()
    sendQueuedData.forEvent = server.sendQueued
    server.selector.registerEvent(server.sendQueued, sendQueuedData)

    let shutdownData = HandleData()
    shutdownData.forEvent = server.shutdown
    server.selector.registerEvent(server.shutdown, shutdownData)
  except:
    server.destroy(true)
    raise currentExceptionAsMummyError()

  try:
    server.loopForever(port)
  except:
    server.destroy(false)
    raise currentExceptionAsMummyError()

proc newServer*(
  handler: RequestHandler,
  websocketHandler: WebSocketHandler = nil,
  workerThreads = max(countProcessors() - 1, 1),
  maxHeadersLen = 8 * 1024, # 8 KB
  maxBodyLen = 1024 * 1024 # 1 MB
): Server {.raises: [MummyError].} =
  if handler == nil:
    raise newException(MummyError, "The request handler must not be nil")

  result = cast[Server](allocShared0(sizeof(ServerObj)))
  result.handler = handler
  result.websocketHandler = websocketHandler
  result.maxHeadersLen = maxHeadersLen
  result.maxBodyLen = maxBodyLen

  initLock(result.workerQueueLock)
  initCond(result.workerQueueCond)
  initLock(result.responseQueueLock)
  initLock(result.sendQueueLock)
  initLock(result.websocketQueuesLock)

  result.workerThreads.setLen(workerThreads)

  # Stuff that can fail
  try:
    result.responseQueued = newSelectEvent()
    result.sendQueued = newSelectEvent()
    result.shutdown = newSelectEvent()

    for workerThead in result.workerThreads.mitems:
      createThread(workerThead, workerProc, result)
  except:
    result.destroy(true)
    raise currentExceptionAsMummyError()
