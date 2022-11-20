import httpserver, std/asyncdispatch, std/os, ws

var serverThread: Thread[void]

proc serverProc() =
  proc handler(request: HttpRequest, response: var HttpResponse) =
    let ws = request.websocketUpgrade(response)

  let server = newHttpServer(handler)
  server.serve(Port(8081))

createThread(serverThread, serverProc)

sleep(1000)

let websocket = waitFor newWebSocket("ws://127.0.0.1:8081")
echo "SENDING"
waitFor websocket.ping()
echo "AFTER PING"
waitFor websocket.send("Test message")
echo "AFTER SEND 2"

waitFor sleepAsync(1000)
