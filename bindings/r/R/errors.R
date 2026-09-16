# Status codes, and how a failed call becomes an R condition.

#' Status codes of the SDK
#'
#' A named integer vector of the status codes the native library reports; `ok`
#' is zero and every failure is negative. A failed call signals a condition of
#' class `licd_error` whose `status` field holds one of these.
#'
#' @format A named integer vector with 21 entries.
#' @seealso [licd_strerror()], [licd_error]
#' @export
licd_status_codes <- c(
  ok = 0L,
  invalid_argument = -1L,
  no_device = -2L,
  access_denied = -3L,
  io = -4L,
  timeout = -5L,
  protocol = -6L,
  not_genuine = -7L,
  certificate_invalid = -8L,
  session_expired = -9L,
  tag_mismatch = -10L,
  range = -11L,
  storage_full = -12L,
  busy = -13L,
  not_found = -14L,
  auth_required = -15L,
  firmware_incompatible = -16L,
  sdk_too_old = -17L,
  cancelled = -18L,
  not_implemented = -19L,
  internal = -20L
)

# Status -> the more specific condition class, where a caller is likely to branch.
.error_classes <- c(
  "-2" = "licd_no_device",
  "-7" = "licd_not_genuine",
  "-8" = "licd_certificate_invalid",
  "-9" = "licd_session_expired",
  "-14" = "licd_not_found",
  "-15" = "licd_auth_required",
  "-18" = "licd_cancelled"
)

#' Text for a status code
#'
#' @param status One or more status codes, see [licd_status_codes].
#' @return A character vector with the native library's short text for each
#'   code.
#' @examples
#' \dontrun{
#' licd_strerror(licd_status_codes[["no_device"]])
#' }
#' @export
licd_strerror <- function(status) {
  .ensure_loaded()
  vapply(as.integer(status), function(s) .Call(C_strerror, s), character(1))
}

#' Errors signalled by this package
#'
#' Every failure the native library reports is signalled as a condition of
#' class `licd_error` (and `error`), with these fields:
#'
#' * `status`: the code, one of [licd_status_codes];
#' * `operation`: the SDK function that failed, such as `"licd_open"`;
#' * `detail`: the library's diagnostic text for this failure, or `""`. Log it;
#'   do not parse it.
#'
#' The failures a program is likely to branch on carry a more specific class in
#' front of `licd_error`: `licd_no_device`, `licd_not_genuine`,
#' `licd_certificate_invalid`, `licd_session_expired`, `licd_not_found`,
#' `licd_auth_required` and `licd_cancelled`.
#'
#' @examples
#' \dontrun{
#' ctx <- licd_context()
#' dongle <- tryCatch(licd_open(ctx),
#'   licd_no_device = function(e) NULL)
#' }
#' @name licd_error
NULL

.licd_stop <- function(status, operation, detail = "") {
  status <- as.integer(status)
  if (is.null(detail) || is.na(detail)) detail <- ""
  text <- paste0(operation, ": ", licd_strerror(status))
  if (nzchar(detail)) text <- paste0(text, " (", detail, ")")
  specific <- .error_classes[as.character(status)]
  classes <- c(if (!is.na(specific)) unname(specific), "licd_error", "error", "condition")
  stop(structure(
    class = classes,
    list(message = text, call = NULL, status = status, operation = operation,
         detail = detail)
  ))
}

# The C layer returns a failed call's status as an integer of class
# "licd_status"; anything else is the result.
.check <- function(result, operation) {
  if (inherits(result, "licd_status")) {
    .licd_stop(as.integer(result), operation, attr(result, "detail"))
  }
  result
}
