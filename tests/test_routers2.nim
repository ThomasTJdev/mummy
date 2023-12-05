#
# Substitutions for wildcards with the `@` identifier. These are used for
# matching path parameters and can be accessed/located later through
# `request.parts` (seq[string]).
#
# The index for the wildcard can be found with, for example,
# `request.parts.find("@" & str)`, and matched with the corresponding
# position in `request.uri`.
#
# The default wildcard `*` is a "pure" wildcard and can be combined
# with a string, e.g., `*page` will match `/wowpage/a/do.htm`, etc. The
# `@` wildcard is a "named" full-wildcard, and its position can be found
# in the `request.parts` seq.
# When being a named wildcard, it also allows other users to identify
# the path parameter by name, e.g., `@userID` or `@projectID`, instead
# of guessing.
#
# Use cases could be, for example, like these where the path parameters must be
# accessed later on.
# 1. Including userID in the URL: `/user/@userID`
# 2. Including projectID and fileID in the URL: `/project/@projectID/file/@fileID`
#


import mummy, mummy/routers
import webby


template `@`(str: string): untyped =
  ## Example on how to access path parameters.
  let pathIndex = request.parts.find("@" & str)
  if pathIndex == -1:
    ""
  else:
    parseUrl(request.uri).paths[pathIndex]


var router: Router
router.notFoundHandler = proc(request: Request) =
  doAssert false
router.methodNotAllowedHandler = proc(request: Request) =
  doAssert false
router.errorHandler = proc(request: Request, e: ref Exception) =
  doAssert false


block:
  proc handlerParam(request: Request) =
    doAssert request.parts.len == 4
    doAssert request.parts[0] == "project"
    doAssert request.parts[1] == "@projectID"
    doAssert request.parts[2] == "file"
    doAssert request.parts[3] == "@fileID"

    doAssert webby.parseUrl(request.uri).paths[1] == "b8a1fa21-b664-49ab-9d1f-818c1fa90dd1"
    doAssert webby.parseUrl(request.uri).paths[3] == "plan.pdf"

    doAssert (@"projectID" == "b8a1fa21-b664-49ab-9d1f-818c1fa90dd1")
    doAssert (@"fileID" == "plan.pdf")


  router.get("/project/@projectID/file/@fileID", handlerParam)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.uri = "/"
  doAssertRaises AssertionDefect:
    routerHandler(request)

  request.uri = "/project/b8a1fa21-b664-49ab-9d1f-818c1fa90dd1/file/"
  doAssertRaises AssertionDefect:
    routerHandler(request)

  request.uri = "/project/b8a1fa21-b664-49ab-9d1f-818c1fa90dd1/file/plan.pdf"
  routerHandler(request)

  request.uri = "/wowpage/a/do.htm"
  doAssertRaises AssertionDefect:
    routerHandler(request)
