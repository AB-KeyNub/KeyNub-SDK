# The library context, enumeration, and opening and closing dongles.

#' Create a library context
#'
#' A context owns the connection to the operating system's USB layer and the
#' dongles opened on it. One per program is usual. Close it with
#' [licd_close()] when done; a context the garbage collector reclaims is closed
#' as well, together with any dongle still open on it.
#'
#' @return A `licd_context` object.
#' @examples
#' \dontrun{
#' ctx <- licd_context()
#' licd_enumerate(ctx)
#' licd_close(ctx)
#' }
#' @export
licd_context <- function() {
  .ensure_loaded()
  ctx <- new.env(parent = emptyenv())
  ctx$ptr <- .check(.Call(C_ctx_new), "licd_init")
  class(ctx) <- "licd_context"
  ctx
}

.new_dongle <- function(ctx, ptr) {
  dongle <- new.env(parent = emptyenv())
  dongle$ptr <- ptr
  dongle$ctx <- ctx
  class(dongle) <- "licd_dongle"
  dongle
}

.ctx_ptr <- function(ctx) {
  if (!inherits(ctx, "licd_context")) stop("not a licd_context", call. = FALSE)
  ctx$ptr
}

.dev_ptr <- function(dongle) {
  if (!inherits(dongle, "licd_dongle")) stop("not a licd_dongle", call. = FALSE)
  dongle$ptr
}

#' Close a context or a dongle
#'
#' Releases the handle. Safe to call more than once. Closing a context closes
#' every dongle still open on it. An object that is not closed is released when
#' the garbage collector reclaims it, so a forgotten handle leaks nothing, but
#' closing explicitly frees the dongle for other programs at once.
#'
#' @param x A `licd_context` from [licd_context()] or a `licd_dongle` from
#'   [licd_open()].
#' @return `NULL`, invisibly.
#' @examples
#' \dontrun{
#' ctx <- licd_context()
#' dongle <- licd_open(ctx)
#' licd_close(dongle)
#' licd_close(ctx)
#' }
#' @export
licd_close <- function(x) {
  UseMethod("licd_close")
}

#' @export
licd_close.licd_context <- function(x) {
  .Call(C_ctx_close, x$ptr)
  invisible(NULL)
}

#' @export
licd_close.licd_dongle <- function(x) {
  .Call(C_dev_close, x$ptr)
  invisible(NULL)
}

#' Is a context or dongle still open?
#'
#' @param x A `licd_context` or a `licd_dongle`.
#' @return `TRUE` while the handle can be used, `FALSE` once it has been closed,
#'   explicitly or through its context.
#' @examples
#' \dontrun{
#' ctx <- licd_context()
#' licd_is_open(ctx)
#' licd_close(ctx)
#' licd_is_open(ctx)
#' }
#' @export
licd_is_open <- function(x) {
  UseMethod("licd_is_open")
}

#' @export
licd_is_open.licd_context <- function(x) {
  .Call(C_ctx_is_open, x$ptr)
}

#' @export
licd_is_open.licd_dongle <- function(x) {
  .Call(C_dev_is_open, x$ptr)
}

#' @export
print.licd_context <- function(x, ...) {
  cat("<KeyNub context", if (licd_is_open(x)) "" else " (closed)", ">\n", sep = "")
  invisible(x)
}

#' @export
print.licd_dongle <- function(x, ...) {
  if (licd_is_open(x)) {
    serial <- tryCatch(licd_serial(x), error = function(e) "?")
    cat("<KeyNub dongle ", serial, ">\n", sep = "")
  } else {
    cat("<KeyNub dongle (closed)>\n")
  }
  invisible(x)
}

#' Diagnostic detail of the most recent failure
#'
#' The native library's diagnostic text for the last call that failed on the
#' current thread. The same text travels in the `detail` field of every
#' [licd_error], so this is for code that inspects a failure after the fact.
#'
#' @param ctx A `licd_context`.
#' @return A string, `""` when the last call succeeded.
#' @export
licd_error_detail <- function(ctx) {
  .Call(C_error_detail, .ctx_ptr(ctx))
}

#' Override the trust root
#'
#' Replaces the CA root certificate that [licd_verify_genuine()] checks the
#' dongle's certificate chain against. Applications do not need this: a release
#' build of the library embeds the KeyNub production root. It exists for dongles
#' provisioned against a different CA, and for vendor tooling.
#'
#' @param ctx A `licd_context`.
#' @param der The root certificate, DER-encoded, as a raw vector.
#' @return `NULL`, invisibly.
#' @export
licd_set_trust_root <- function(ctx, der) {
  .check(.Call(C_set_trust_root, .ctx_ptr(ctx), .as_raw(der, "der")), "licd_set_trust_root")
  invisible(NULL)
}

#' List the attached dongles
#'
#' Enumerates without opening anything.
#'
#' @param ctx A `licd_context`.
#' @return A data frame with one row per dongle and the columns `serial` (hex),
#'   `path` (the operating system's device path, accepted by
#'   [licd_open_path()]), `vendor_id` and `product_id` (USB ids). Zero rows when
#'   none is attached.
#' @examples
#' \dontrun{
#' ctx <- licd_context()
#' dongles <- licd_enumerate(ctx)
#' nrow(dongles)
#' }
#' @export
licd_enumerate <- function(ctx) {
  columns <- .check(.Call(C_enumerate, .ctx_ptr(ctx)), "licd_enumerate")
  as.data.frame(columns, stringsAsFactors = FALSE)
}

#' Open a dongle
#'
#' `licd_open()` opens the dongle with the given serial, or the first one found
#' when `serial` is `NULL`. `licd_open_path()` opens the dongle at a device path
#' from [licd_enumerate()]. Both signal a condition of class `licd_no_device`
#' when there is no such dongle.
#'
#' @param ctx A `licd_context`.
#' @param serial The serial as hex, or `NULL` for the first dongle.
#' @param path A device path from [licd_enumerate()].
#' @return A `licd_dongle` object. Close it with [licd_close()].
#' @examples
#' \dontrun{
#' ctx <- licd_context()
#' dongle <- licd_open(ctx)             # the first dongle
#' licd_verify_genuine(dongle)          # signals an error unless genuine
#' licd_close(dongle)
#' licd_close(ctx)
#' }
#' @export
licd_open <- function(ctx, serial = NULL) {
  if (!is.null(serial) && (!is.character(serial) || length(serial) != 1L || is.na(serial))) {
    stop("serial must be one string or NULL", call. = FALSE)
  }
  ptr <- .check(.Call(C_open, .ctx_ptr(ctx), serial), "licd_open")
  .new_dongle(ctx, ptr)
}

#' @rdname licd_open
#' @export
licd_open_path <- function(ctx, path) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("path must be one string", call. = FALSE)
  }
  ptr <- .check(.Call(C_open_path, .ctx_ptr(ctx), path), "licd_open_path")
  .new_dongle(ctx, ptr)
}
