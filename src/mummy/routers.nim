import mummy, std/strutils, urlly

type
  Router* = object
    notFoundHandler*: RequestHandler
      ## Called when no routes match the request URI
    methodNotAllowedHandler*: RequestHandler
      ## Called when the HTTP method is not registered for the route
    errorHandler*: RequestErrorHandler
      ## Called when the route request handler raises an Exception
    routes: seq[Route]

  RequestErrorHandler* = proc(request: Request, e: ref Exception) {.gcsafe.}

  Route = object
    httpMethod: string
    parts: seq[string]
    handler: RequestHandler

proc addRoute*(
  router: var Router,
  httpMethod, route: static string,
  handler: RequestHandler
) =
  when route == "":
    {.error: "Invalid empty route".}
  when route[0] != '/':
    {.error: "Routes must begin with /".}

  var parts = route.split('/')
  parts.delete(0)

  # Simplify all wildcard parts after **
  var i: int
  while i < parts.len:
    if parts[i] == "**":
      var j = i + 1
      while j < parts.len:
        if parts[j] == "*" or parts[j] == "**":
          parts.delete(j)
        else:
          break
    inc i

  router.routes.add(Route(
    httpMethod: httpMethod,
    parts: move parts,
    handler: handler
  ))

proc get*(router: var Router, route: static string, handler: RequestHandler) =
  router.addRoute("GET", route, handler)

proc head*(router: var Router, route: static string, handler: RequestHandler) =
  router.addRoute("HEAD", route, handler)

proc post*(router: var Router, route: static string, handler: RequestHandler) =
  router.addRoute("POST", route, handler)

proc put*(router: var Router, route: static string, handler: RequestHandler) =
  router.addRoute("PUT", route, handler)

proc delete*(router: var Router, route: static string, handler: RequestHandler) =
  router.addRoute("DELETE", route, handler)

proc options*(router: var Router, route: static string, handler: RequestHandler) =
  router.addRoute("OPTIONS", route, handler)

proc patch*(router: var Router, route: static string, handler: RequestHandler) =
  router.addRoute("PATCH", route, handler)

proc defaultNotFoundHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  request.respond(404, headers, "<h1>Not Found</h1>")

proc defaultMethodNotAllowedHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  request.respond(405, headers, "<h1>Method Not Allowed</h1>")

proc defaultErrorHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  request.respond(500, headers, "<h1>Internal Server Error</h1>")

proc partialWildcardMatches(partialWildcard, test: string): bool =
  let literalLen = partialWildcard.len - 1
  if literalLen > test.len:
    return false
  equalMem(
    partialWildcard[1].unsafeAddr,
    test[test.len - literalLen].unsafeAddr,
    literalLen
  )

converter toHandler*(router: Router): RequestHandler =
  return proc(request: Request) =
    try:
      let url = parseUrl(request.uri)

      var matchedSomeRoute: bool
      for route in router.routes:
        if route.parts.len > url.paths.len:
          continue

        var
          i, j: int
          matchedRoute = true
          atLeastOneMultiWildcardMatch = false
        while true:
          if j >= url.paths.len:
            break
          if i >= route.parts.len:
            matchedRoute = false
            break

          if route.parts[i] == "*": # Wildcard
            inc i
            inc j
          elif route.parts[i] == "**": # Multi-part wildcard
            # Do we have a required next literal?
            if i + 1 < route.parts.len and atLeastOneMultiWildcardMatch:
              let matchesNextLiteral =
                if route.parts[i + 1].startsWith('*'):
                  partialWildcardMatches(route.parts[i + 1], url.paths[j])
                else:
                  url.paths[j] == route.parts[i + 1]
              if matchesNextLiteral:
                inc i
                # Do not inc j here, let the next literal get checked
                atLeastOneMultiWildcardMatch = false
              elif j == url.paths.high:
                matchedRoute = false
                break
              else:
                inc j
            else:
              atLeastOneMultiWildcardMatch = true
              inc j
          elif route.parts[i].startsWith('*'): # Partial wildcard
            if not partialWildcardMatches(route.parts[i], url.paths[j]):
              matchedRoute = false
              break
            inc i
            inc j
          else: # Literal
            if url.paths[j] != route.parts[i]:
              matchedRoute = false
              break
            inc i
            inc j

        if matchedRoute:
          matchedSomeRoute = true
          if request.httpMethod == route.httpMethod: # We have a winner
            route.handler(request)
            return

      if matchedSomeRoute: # We matched a route but not the HTTP method
        if router.methodNotAllowedHandler != nil:
          router.methodNotAllowedHandler(request)
        else:
          defaultMethodNotAllowedHandler(request)
      else:
        if router.notFoundHandler != nil:
          router.notFoundHandler(request)
        else:
          defaultNotFoundHandler(request)
    except:
      if router.errorHandler != nil:
        router.errorHandler(request, getCurrentException())
      else:
        defaultErrorHandler(request)
