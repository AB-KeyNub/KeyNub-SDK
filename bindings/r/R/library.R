# Where the native library comes from, and loading it once per process.

.lib <- new.env(parent = emptyenv())
.lib$path <- NULL   # chosen through licd_library(path), before the first call
.lib$loaded <- NULL # the path the process actually loaded

.default_basename <- function() {
  if (.Platform$OS.type == "windows") {
    "keynub_licdongle.dll"
  } else if (identical(Sys.info()[["sysname"]], "Darwin")) {
    "libkeynub_licdongle.dylib"
  } else {
    "libkeynub_licdongle.so"
  }
}

# The natives/<platform> folder name of the SDK repository for this R process.
.repo_rid <- function() {
  os <- if (.Platform$OS.type == "windows") {
    "win"
  } else if (identical(Sys.info()[["sysname"]], "Darwin")) {
    "osx"
  } else {
    "linux"
  }
  arch <- R.version$arch
  cpu <- if (arch %in% c("x86_64", "amd64")) {
    "x64"
  } else if (arch %in% c("aarch64", "arm64")) {
    "arm64"
  } else if (arch %in% c("i386", "i686", "x86")) {
    "x86"
  } else {
    "unknown"
  }
  paste(os, cpu, sep = "-")
}

# In a clone of the SDK repository the library sits in natives/<platform>; the
# working directory, or one of its parents, is that clone when a sample runs.
.find_in_repo <- function() {
  target <- file.path("natives", .repo_rid(), .default_basename())
  dir <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
  for (i in seq_len(8)) {
    candidate <- file.path(dir, target)
    if (file.exists(candidate)) return(candidate)
    parent <- dirname(dir)
    if (identical(parent, dir)) break
    dir <- parent
  }
  NULL
}

.resolve_library <- function() {
  env <- Sys.getenv("KEYNUB_LICDONGLE_LIBRARY")
  if (nzchar(env)) return(env)
  found <- .find_in_repo()
  if (!is.null(found)) return(found)
  .default_basename()
}

.ensure_loaded <- function() {
  if (!is.null(.lib$loaded)) return(invisible(.lib$loaded))
  path <- if (!is.null(.lib$path)) .lib$path else .resolve_library()
  .lib$loaded <- .Call(C_load, path)
  invisible(.lib$loaded)
}

#' The native library in use
#'
#' The package does its work through the KeyNub native library
#' (`keynub_licdongle.dll`, `libkeynub_licdongle.so` or
#' `libkeynub_licdongle.dylib`), which a process loads once, on the first call
#' that needs it. `licd_library(path)` names the file to load, and must come
#' before that first call. Without it the package takes, in this order, the
#' `KEYNUB_LICDONGLE_LIBRARY` environment variable, the `natives/<platform>/`
#' folder of a clone of the SDK repository found from the working directory
#' upwards, and finally the bare file name, which the operating system resolves
#' along its usual search path (`PATH`, `LD_LIBRARY_PATH`,
#' `DYLD_LIBRARY_PATH`).
#'
#' @param path A file path to the library, or `NULL` to ask.
#' @return The path in use, or the one that would be used: the loaded library
#'   once there is one, otherwise the choice the next call would make.
#'   Invisibly when `path` is given.
#' @examples
#' \dontrun{
#' licd_library("C:/keynub/natives/win-x64/keynub_licdongle.dll")
#' licd_version()
#' }
#' @export
licd_library <- function(path = NULL) {
  if (is.null(path)) {
    if (!is.null(.lib$loaded)) return(.lib$loaded)
    if (!is.null(.lib$path)) return(.lib$path)
    return(.resolve_library())
  }
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("path must be one non-empty string", call. = FALSE)
  }
  if (!is.null(.lib$loaded) && !identical(path, .lib$loaded)) {
    stop("the KeyNub library is already loaded from '", .lib$loaded,
         "'; a process loads it once", call. = FALSE)
  }
  .lib$path <- path
  invisible(path)
}

#' Version of the native library
#'
#' @return An integer vector of length three: major, minor and patch version of
#'   the loaded library, which is the SDK version it was built from.
#' @examples
#' \dontrun{
#' licd_version()
#' }
#' @export
licd_version <- function() {
  .ensure_loaded()
  .Call(C_version)
}
